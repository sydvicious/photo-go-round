import Foundation
import Synchronization
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// **Serving waits for the head card's bytes, once, and then empties the queue
/// ahead of itself.**
///
/// Decided 2026-09-05. A card is dealt whether or not its bytes are here, the
/// queue's fetcher goes and gets them, and a request that reaches a card before
/// they land waits — up to `serveWait` — for one of three things: the bytes
/// land, the card leaves the queue because its fetch failed, or the wait runs
/// out.
///
/// **What happens after the wait changed on 2026-09-07.** The request used to
/// drop the head and then walk past the cold cards behind it, leaving them
/// queued because they were still being fetched. That is what let a run of
/// photographs the network could not deliver settle at the head of the queue,
/// where every subsequent request met them again in the same order — measured
/// with the network off: twenty cards queued, seventeen warm, both windows
/// stalled behind the three that were not. Now the request takes the new head
/// and drops it too if it is cold, until it meets a card it can serve or the
/// queue is empty.
///
/// File-backed, because the fetch that lands mid-wait runs on a second
/// connection the way the agent's fetcher does.
@Suite("Serving waits for the head card")
struct ServeWaitTests {

    /// Every cache lookup serving reported, in order. See `CacheLookup`.
    final class Looked: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [CacheLookup] = []

        func record(_ lookup: CacheLookup) {
            lock.lock()
            entries.append(lookup)
            lock.unlock()
        }

        var all: [CacheLookup] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    /// A fetch started at most once, from inside a request, and awaited after.
    final class BackgroundFetch: Sendable {
        let path: String
        let root: URL
        let bytes: PhotoStore
        private let task = Mutex<Task<Void, Never>?>(nil)

        init(path: String, root: URL, bytes: PhotoStore) {
            self.path = path
            self.root = root
            self.bytes = bytes
        }

        func start() {
            let path = path
            let root = root
            let bytes = bytes
            task.withLock { task in
                guard task == nil else { return }
                task = Task.detached {
                    guard let database = try? Database(path: path) else { return }
                    let cache = PhotoCache(
                        database: database, root: root,
                        sources: SourceStore(database: database, bytes: bytes), store: bytes)
                    try? await cache.fetchAllQueued()
                }
            }
        }

        /// Returns once the fetch has, or at once if serving never started one.
        func finished() async {
            await task.withLock { $0 }?.value
        }
    }

    private struct Fixture {
        let directory: URL
        let folder: TemporaryFolder
        let library: TestLibrary
        let bytes: PhotoStore
        let store: SourceStore
        var cache: PhotoCache
        let source: Source
        let heard = ServeWalkTests.Heard()
        let looked = Looked()

        init(photos: [String], wait: Duration, materialized: Bool = true) async throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-wait-\(UUID().uuidString)")
            folder = TemporaryFolder(name: "pgr-wait-src")
            for name in photos { folder.write(name, bytes: 2048) }

            library = try TestLibrary.onDisk(at: directory)
            bytes = PhotoStore(root: directory.appending(path: "cache"))
            store = SourceStore(database: library.database, bytes: bytes)
            cache = PhotoCache(
                database: library.database, root: directory.appending(path: "cache"),
                sources: store, store: bytes)
            try await cache.prepare()

            source = try store.add(kind: .folder, locator: folder.path)
            _ = await store.refresh(source)
            if materialized {
                try library.database.run("UPDATE photo SET storage = 'materialized';")
            }
            cache.log = heard.log
            let looked = looked
            cache.lookedUp = { looked.record($0) }
            cache.serveWait = wait
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }

        @discardableResult
        func dealAll() async throws -> Int {
            var dealt = 0
            while try await cache.deal() { dealt += 1 }
            return dealt
        }

        var head: DeckCard? { try? cache.queue.peek().first }
        var queued: Int { (try? cache.queue.size()) ?? 0 }
        var pooled: Int {
            (try? library.database.scalarInt("SELECT COUNT(*) FROM photo;")) ?? 0
        }
        /// Whether a lane's claim is still on this photograph.
        func claimed(_ photoID: Int64) throws -> Bool {
            try library.database.scalarInt(
                "SELECT COUNT(*) FROM photo WHERE id = \(photoID) AND claimed_at IS NOT NULL;") == 1
        }

        /// Fetches every queued card on its own connection — the agent's
        /// fetcher, standing in — once serving says it is waiting.
        ///
        /// **Started by the request's own `waiting` line, not after a pause.**
        /// Until 2026-09-16 this slept 200 or 300 ms and then fetched, racing
        /// the request. In a full parallel run the request could reach the head
        /// after the fetch had finished, find nothing to wait for, and fail
        /// `waited() == 1` — twice that day, and reproduced by fetching before
        /// serving. Syd: "we fixed flaky timing tests at Indeed by using await
        /// Task {}.run." So the fetch follows the event it is for, and the test
        /// awaits the fetch rather than a clock.
        mutating func fetchWhenServingWaits() -> BackgroundFetch {
            let fetch = BackgroundFetch(
                path: TestLibrary.path(in: directory), root: directory.appending(path: "cache"),
                bytes: bytes)
            let heard = heard
            cache.log = { event in
                heard.log(event)
                if case .waiting = event { fetch.start() }
            }
            return fetch
        }

        func waited() -> Int { heard.count { if case .waiting = $0 { true } else { false } } }
        func dropped() -> [String] {
            heard.all.compactMap {
                if case .cacheDropped(_, _, let because, _) = $0 { because } else { nil }
            }
        }
    }

    @Test("A cold head card is waited for, and served when its bytes land")
    func waitsAndServes() async throws {
        // The bound is thirty seconds and the assertion is fifteen, so the
        // assertion still says something: the bytes land as soon as the
        // request says it is waiting, and a request that took longer than
        // fifteen seconds to notice did not notice, it waited the bound out.
        // Fifteen rather than five since 2026-09-07, when a full parallel run
        // starved this to six seconds and failed it for nothing.
        var fixture = try await Fixture(photos: ["a.png"], wait: .seconds(30))
        defer { fixture.cleanUp() }
        try await fixture.dealAll()

        let clock = ContinuousClock()
        let started = clock.now
        let fetching = fixture.fetchWhenServingWaits()
        let served = try #require(try await fixture.cache.serve())
        await fetching.finished()

        #expect(served.card.externalID == "a.png")
        #expect(fixture.waited() == 1, "the request did not say it was waiting")
        #expect(fixture.dropped().isEmpty)
        #expect(clock.now - started < .seconds(15), "the request waited out its whole bound")
        #expect(fixture.queued == 0)
        #expect(fixture.looked.all == [.miss(.landed)])
    }

    @Test("When the wait runs out the head is dropped and the first warm card is served")
    func timeoutDropsTheHeadAndTakesAWarmCard() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"], wait: .milliseconds(300))
        defer { fixture.cleanUp() }
        try await fixture.dealAll()
        try await fixture.cache.fetchAllQueued()

        // Make the head cold again: its bytes go, and the record with them.
        let head = try #require(fixture.head)
        await fixture.bytes.remove(photoUUID: head.uuid)
        try fixture.cache.releaseResidency(ofPhotos: [head.uuid])

        let clock = ContinuousClock()
        let started = clock.now
        let served = try #require(try await fixture.cache.serve())

        // Nothing fetched, so the wait ran out: the head is gone from the
        // queue, the other card went out, and the photograph is still in the
        // library for next time.
        #expect(served.card.id != head.id)
        #expect(clock.now - started >= .milliseconds(300))
        #expect(fixture.dropped().contains { $0.hasPrefix("its bytes did not arrive") })
        #expect(fixture.queued == 0)
        #expect(fixture.pooled == 2, "a dropped card must keep its row")
        #expect(try fixture.cache.queue.contains(photoID: head.id) == false)
        #expect(fixture.looked.all == [.miss(.timedOut), .hit])
    }

    @Test("With no warm card after the wait, every cold card is dropped and nothing is served")
    func timeoutWithNothingWarm() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"], wait: .milliseconds(200))
        defer { fixture.cleanUp() }
        try await fixture.dealAll()

        #expect(try await fixture.cache.serve() == nil)

        // **One wait, two drops.** The wait is spent on the head; the card
        // behind it is dropped on sight rather than left where it is. Leaving
        // it is what let a queue fill with cards that could never be served —
        // every request would meet them again, in order, ahead of the cards
        // that could.
        #expect(fixture.waited() == 1)
        #expect(fixture.dropped().count == 2)
        #expect(fixture.queued == 0)
        #expect(fixture.pooled == 2, "a dropped card must keep its row")
        #expect(fixture.heard.lines.contains("SERVE: nothing to show — out of cards, walked 2"))
        #expect(fixture.looked.all == [.miss(.timedOut), .miss(.droppedWithoutWaiting)])
    }

    @Test("Cold cards ahead of a warm one are dropped, and the warm one is served")
    func coldCardsAheadOfAWarmOneAreDropped() async throws {
        // The night this was written for: a queue whose head is a run of
        // photographs iCloud will not deliver, with a folder photograph behind
        // them whose bytes have been on the disk all along.
        let cold = (1...6).map { "cold\($0).png" }
        let fixture = try await Fixture(photos: cold + ["warm.png"], wait: .milliseconds(200))
        defer { fixture.cleanUp() }
        try await fixture.dealAll()

        // Bytes go to whichever card the deck put *last*, so that every other
        // card stands between the request and it. Which photograph that is is
        // the deck's business and not this test's — asking the queue is what
        // makes the arrangement hold however it dealt.
        let queued = try fixture.cache.queue.peek(16)
        #expect(queued.count == 7)
        let warm = try #require(queued.last)
        _ = try await fixture.cache.cache(photoID: warm.id)

        let clock = ContinuousClock()
        let started = clock.now
        let served = try #require(try await fixture.cache.serve())

        #expect(served.card.id == warm.id)
        // One wait, not six: the rest are dropped on sight.
        #expect(fixture.waited() == 1)
        #expect(fixture.dropped().count == 6)
        #expect(fixture.queued == 0, "the cold cards must not still be queued")
        #expect(fixture.pooled == 7, "dropping a card keeps its photograph")
        // **A pathology guard, not the claim.** What "one wait, not six" means
        // is asserted directly above: `waited() == 1` and six dropped. This
        // clock cannot tell those apart anyway — the wait here is 200 ms, so
        // six of them would be 1.2 s and still inside two seconds. All it can
        // catch is a request that hangs, and at two seconds it also caught a
        // busy machine: it failed once on 2026-09-17 in a full parallel run
        // while the assertions that matter passed.
        #expect(
            clock.now - started < .seconds(5),
            "a request spent more than its one wait walking cold cards")
        #expect(
            fixture.looked.all
                == [.miss(.timedOut)]
                + Array(repeating: .miss(.droppedWithoutWaiting), count: 5) + [.hit])
    }

    @Test("A card dropped for want of bytes keeps its claim, because its fetch may still be running")
    func droppingAColdCardLeavesTheClaimAlone() async throws {
        let fixture = try await Fixture(photos: ["a.png"], wait: .milliseconds(200))
        defer { fixture.cleanUp() }
        try await fixture.dealAll()

        // The claim a lane takes before it fetches. Serving is about to drop
        // the card out from under that fetch.
        let head = try #require(fixture.head)
        #expect(try Deck(database: fixture.library.database).claim(photoID: head.id) == true)

        #expect(try await fixture.cache.serve() == nil)

        // **The claim outlives the queue place.** It belongs to the fetch, not
        // to the card's position: released here, a re-deal of this photograph
        // would let a second lane stream into the same staging file as the
        // first, and the two would write one corrupt image between them.
        #expect(fixture.queued == 0)
        #expect(
            try fixture.claimed(head.id) == true,
            "serving released a claim held by a fetch that is still running")
    }

    @Test("A card from a benched source is dropped without waiting")
    func benchedIsNotWaitedFor() async throws {
        var fixture = try await Fixture(photos: ["a.png"], wait: .seconds(10))
        defer { fixture.cleanUp() }
        let bench = SourceBench(pauseAfter: 1)
        fixture.cache.bench = bench
        try await fixture.dealAll()
        await bench.failed(fixture.source.id)

        let clock = ContinuousClock()
        let started = clock.now
        #expect(try await fixture.cache.serve() == nil)

        #expect(clock.now - started < .seconds(2), "waited on a source the bench had written off")
        #expect(fixture.waited() == 0)
        #expect(fixture.dropped() == ["its source is not answering"])
        #expect(fixture.queued == 0)
        #expect(fixture.looked.all == [.miss(.droppedWithoutWaiting)])
    }

    @Test("A request meeting a cold card asks for the fetcher")
    func coldCardAsksForTheFetcher() async throws {
        var fixture = try await Fixture(photos: ["a.png"], wait: .milliseconds(100))
        defer { fixture.cleanUp() }
        let kicks = Mutex(0)
        fixture.cache.ensureFetching = { kicks.withLock { $0 += 1 } }
        try await fixture.dealAll()

        _ = try await fixture.cache.serve()

        #expect(kicks.withLock { $0 } == 1)
    }

    @Test("A card whose fetch fails during the wait is passed over for the new head")
    func fetchFailingMidWaitMovesOn() async throws {
        var fixture = try await Fixture(photos: ["a.png", "b.png"], wait: .seconds(10))
        defer { fixture.cleanUp() }
        try await fixture.dealAll()
        // The head's file is gone before anything fetches it: the fetch fails,
        // the source confirms it absent, and the row and card go together.
        let head = try #require(fixture.head)
        fixture.folder.remove(head.externalID)
        // The other is held already, so the request's one wait is the head's.
        // Left to the background fetch, whether it had landed by the time the
        // request reached it was that fetch's timing, not this test's.
        let other = try #require(try fixture.library.database.scalarInt(
            "SELECT id FROM photo WHERE id != \(head.id);"))
        #expect(try await fixture.cache.cache(photoID: Int64(other)))

        let fetching = fixture.fetchWhenServingWaits()
        let served = try #require(try await fixture.cache.serve())
        await fetching.finished()

        #expect(served.card.id == Int64(other))
        #expect(fixture.pooled == 1, "the deleted photograph should have left the library")
        #expect(fixture.waited() == 1)
        #expect(fixture.dropped().isEmpty, "the fetcher removed it; serving should not have dropped anything")
        #expect(fixture.looked.all == [.miss(.leftDuringWait), .hit])
    }

    @Test("A wait of zero never waits, and drops every cold card it meets")
    func zeroWaitNeverWaits() async throws {
        let fixture = try await Fixture(photos: ["a.png"], wait: .zero)
        defer { fixture.cleanUp() }
        try await fixture.dealAll()

        #expect(try await fixture.cache.serve() == nil)

        // Nothing has bytes, so nothing is served, and nothing is waited for.
        // **The card still goes**, which is the change: a wait of zero means
        // *never wait for bytes*, not *leave cold cards where they are*. The
        // second reading is the one that fills a queue with cards no request
        // can ever get past.
        #expect(fixture.waited() == 0)
        #expect(fixture.dropped().count == 1)
        #expect(fixture.queued == 0)
        #expect(fixture.pooled == 1)
        #expect(fixture.looked.all == [.miss(.droppedWithoutWaiting)])
    }

    @Test("A warm head is served at once, with no wait said")
    func warmHeadDoesNotWait() async throws {
        let fixture = try await Fixture(photos: ["a.png"], wait: .seconds(10))
        defer { fixture.cleanUp() }
        try await fixture.dealAll()
        try await fixture.cache.fetchAllQueued()

        let clock = ContinuousClock()
        let started = clock.now
        let served = try #require(try await fixture.cache.serve())

        #expect(served.card.externalID == "a.png")
        #expect(fixture.waited() == 0)
        #expect(clock.now - started < .seconds(1))
        #expect(fixture.looked.all == [.hit])
    }

    /// Every fetch-side lookup dealing reported, in order. See `DealLookup`.
    final class Dealt: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [DealLookup] = []

        func record(_ lookup: DealLookup) {
            lock.lock()
            entries.append(lookup)
            lock.unlock()
        }

        var all: [DealLookup] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    /// The fetch side of the hit rate is counted at the deal, because the
    /// fetcher only ever asks for cards whose originals are not held.
    @Test("Dealing a materialized card says whether its original is already held")
    func dealingReportsWhetherTheOriginalIsHeld() async throws {
        var fixture = try await Fixture(photos: ["a.png", "b.png"], wait: .zero)
        defer { fixture.cleanUp() }
        let dealt = Dealt()
        fixture.cache.dealLookedUp = { dealt.record($0) }

        await #expect(try fixture.dealAll() == 2)
        #expect(dealt.all == [.miss, .miss])

        // Fetched, then dealt again: both originals are here now.
        try await fixture.cache.fetchAllQueued()
        try fixture.library.database.run("DELETE FROM queue;")
        await #expect(try fixture.dealAll() == 2)
        #expect(dealt.all == [.miss, .miss, .hit, .hit])
    }

    @Test("Dealing a referenced photograph is not a fetch-side lookup")
    func dealingReferencedIsNotALookup() async throws {
        var fixture = try await Fixture(photos: ["a.png"], wait: .zero, materialized: false)
        defer { fixture.cleanUp() }
        let dealt = Dealt()
        fixture.cache.dealLookedUp = { dealt.record($0) }

        await #expect(try fixture.dealAll() == 1)
        #expect(dealt.all.isEmpty)
    }

    /// A referenced photograph is its own file, so serving one never consulted
    /// the cache — and a hit rate that counted it would be flattered by every
    /// folder on the boot volume.
    @Test("Serving a referenced photograph is not a cache lookup")
    func referencedIsNotALookup() async throws {
        let fixture = try await Fixture(photos: ["a.png"], wait: .seconds(10), materialized: false)
        defer { fixture.cleanUp() }
        try await fixture.dealAll()

        let served = try #require(try await fixture.cache.serve())

        #expect(served.card.storage == .referenced)
        #expect(fixture.looked.all.isEmpty)
    }
}
