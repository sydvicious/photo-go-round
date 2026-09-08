import Foundation
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

    private struct Fixture {
        let directory: URL
        let folder: TemporaryFolder
        let library: TestLibrary
        let bytes: PhotoStore
        let store: SourceStore
        var cache: PhotoCache
        let source: Source
        let heard = ServeWalkTests.Heard()

        init(photos: [String], wait: Duration) async throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-wait-\(UUID().uuidString)")
            folder = TemporaryFolder(name: "pgr-wait-src")
            for name in photos { folder.write(name, bytes: 2048) }

            library = try TestLibrary.onDisk(at: directory)
            bytes = PhotoStore(root: directory.appending(path: "cache"))
            store = SourceStore(database: library.database, bytes: bytes)
            cache = PhotoCache(
                database: library.database, root: directory.appending(path: "cache"),
                sources: store, store: bytes)
            try cache.prepare()

            source = try await store.add(kind: .folder, locator: folder.path)
            _ = await store.refresh(source)
            try library.database.run("UPDATE photo SET storage = 'materialized';")
            cache.log = heard.log
            cache.serveWait = wait
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }

        @discardableResult
        func dealAll() throws -> Int {
            var dealt = 0
            while try cache.deal() { dealt += 1 }
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

        /// Fetches every queued card on its own connection, after a pause —
        /// the agent's fetcher, standing in.
        func fetchInBackground(after delay: Duration) -> Task<Void, Never> {
            let path = TestLibrary.path(in: directory)
            let root = directory.appending(path: "cache")
            let bytes = bytes
            return Task.detached {
                try? await Task.sleep(for: delay)
                guard let database = try? Database(path: path) else { return }
                let cache = PhotoCache(
                    database: database, root: root,
                    sources: SourceStore(database: database, bytes: bytes), store: bytes)
                try? await cache.fetchAllQueued()
            }
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
        // assertion still says something: the bytes land at 300 ms, and a
        // request that took longer than fifteen seconds to notice did not
        // notice, it waited the bound out. Fifteen rather than five since
        // 2026-09-07, when a full parallel run starved this to six seconds
        // and failed it for nothing.
        let fixture = try await Fixture(photos: ["a.png"], wait: .seconds(30))
        defer { fixture.cleanUp() }
        try fixture.dealAll()

        let clock = ContinuousClock()
        let started = clock.now
        let fetching = fixture.fetchInBackground(after: .milliseconds(300))
        let served = try #require(try await fixture.cache.serve())
        await fetching.value

        #expect(served.card.externalID == "a.png")
        #expect(fixture.waited() == 1, "the request did not say it was waiting")
        #expect(fixture.dropped().isEmpty)
        #expect(clock.now - started < .seconds(15), "the request waited out its whole bound")
        #expect(fixture.queued == 0)
    }

    @Test("When the wait runs out the head is dropped and the first warm card is served")
    func timeoutDropsTheHeadAndTakesAWarmCard() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"], wait: .milliseconds(300))
        defer { fixture.cleanUp() }
        try fixture.dealAll()
        try await fixture.cache.fetchAllQueued()

        // Make the head cold again: its bytes go, and the record with them.
        let head = try #require(fixture.head)
        fixture.bytes.remove(photoUUID: head.uuid)
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
    }

    @Test("With no warm card after the wait, every cold card is dropped and nothing is served")
    func timeoutWithNothingWarm() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"], wait: .milliseconds(200))
        defer { fixture.cleanUp() }
        try fixture.dealAll()

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
    }

    @Test("Cold cards ahead of a warm one are dropped, and the warm one is served")
    func coldCardsAheadOfAWarmOneAreDropped() async throws {
        // The night this was written for: a queue whose head is a run of
        // photographs iCloud will not deliver, with a folder photograph behind
        // them whose bytes have been on the disk all along.
        let cold = (1...6).map { "cold\($0).png" }
        let fixture = try await Fixture(photos: cold + ["warm.png"], wait: .milliseconds(200))
        defer { fixture.cleanUp() }
        try fixture.dealAll()

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
        #expect(
            clock.now - started < .seconds(2),
            "a request spent more than its one wait walking cold cards")
    }

    @Test("A card dropped for want of bytes keeps its claim, because its fetch may still be running")
    func droppingAColdCardLeavesTheClaimAlone() async throws {
        let fixture = try await Fixture(photos: ["a.png"], wait: .milliseconds(200))
        defer { fixture.cleanUp() }
        try fixture.dealAll()

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
        try fixture.dealAll()
        bench.failed(fixture.source.id)

        let clock = ContinuousClock()
        let started = clock.now
        #expect(try await fixture.cache.serve() == nil)

        #expect(clock.now - started < .seconds(2), "waited on a source the bench had written off")
        #expect(fixture.waited() == 0)
        #expect(fixture.dropped() == ["its source is not answering"])
        #expect(fixture.queued == 0)
    }

    @Test("A request meeting a cold card asks for the fetcher")
    func coldCardAsksForTheFetcher() async throws {
        var fixture = try await Fixture(photos: ["a.png"], wait: .milliseconds(100))
        defer { fixture.cleanUp() }
        let kicks = Mutex(0)
        fixture.cache.ensureFetching = { kicks.withLock { $0 += 1 } }
        try fixture.dealAll()

        _ = try await fixture.cache.serve()

        #expect(kicks.withLock { $0 } == 1)
    }

    @Test("A card whose fetch fails during the wait is passed over for the new head")
    func fetchFailingMidWaitMovesOn() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"], wait: .seconds(10))
        defer { fixture.cleanUp() }
        try fixture.dealAll()
        // The head's file is gone before anything fetches it: the fetch fails,
        // the source confirms it absent, and the row and card go together.
        let head = try #require(fixture.head)
        fixture.folder.remove(head.externalID)

        let fetching = fixture.fetchInBackground(after: .milliseconds(200))
        let served = try #require(try await fixture.cache.serve())
        await fetching.value

        #expect(served.card.id != head.id)
        #expect(fixture.pooled == 1, "the deleted photograph should have left the library")
        #expect(fixture.waited() == 1)
        #expect(fixture.dropped().isEmpty, "the fetcher removed it; serving should not have dropped anything")
    }

    @Test("A wait of zero never waits, and drops every cold card it meets")
    func zeroWaitNeverWaits() async throws {
        let fixture = try await Fixture(photos: ["a.png"], wait: .zero)
        defer { fixture.cleanUp() }
        try fixture.dealAll()

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
    }

    @Test("A warm head is served at once, with no wait said")
    func warmHeadDoesNotWait() async throws {
        let fixture = try await Fixture(photos: ["a.png"], wait: .seconds(10))
        defer { fixture.cleanUp() }
        try fixture.dealAll()
        try await fixture.cache.fetchAllQueued()

        let clock = ContinuousClock()
        let started = clock.now
        let served = try #require(try await fixture.cache.serve())

        #expect(served.card.externalID == "a.png")
        #expect(fixture.waited() == 0)
        #expect(clock.now - started < .seconds(1))
    }
}
