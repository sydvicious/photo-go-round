import Foundation
import Testing

@testable import PhotoGoRoundKit

/// The serving algorithm, square by square.
///
/// > 1. See if the pic in the queue is in the cache, and if it is, serve it.
/// > 2. Otherwise, fire off a separate process to cache the picture if possible,
/// >    but the queue moves on and tries until it finds one.
/// > 3. If it cycles the entire queue, return no picture.
/// > 4. When the caching for a pic is finished, add it back to the queue.
///
/// It is a simpler algorithm than the one it replaces and has more cases,
/// because everything that used to be decided in advance — is this source
/// mounted, are these bytes held — is now decided by trying, one card at a time,
/// with the queue moving underneath.
@Suite("Serving walks the queue")
struct ServeWalkTests {

    /// Collects what the two queues said, in order, so a test can assert on the
    /// decisions rather than on the outcome alone.
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [QueueEvent] = []

        var log: @Sendable (QueueEvent) -> Void {
            { [self] event in
                lock.lock()
                events.append(event)
                lock.unlock()
            }
        }

        var all: [QueueEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        /// The console lines, which is what a person actually reads.
        var lines: [String] { all.map(\.line) }

        func count(where matches: (QueueEvent) -> Bool) -> Int { all.filter(matches).count }
    }

    /// Records what was asked to be cached, without fetching any of it — so a
    /// test can watch serving hand work off and never wait for it.
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [Int64] = []

        var want: @Sendable (Int64) -> Void {
            { [self] id in
                lock.lock()
                ids.append(id)
                lock.unlock()
            }
        }

        var all: [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }
    }

    private struct Fixture {
        let folder: TemporaryFolder
        let cacheRoot: TemporaryFolder
        let library: TestLibrary
        let bytes: PhotoStore
        let store: SourceStore
        var cache: PhotoCache
        let source: Source
        let heard = Heard()
        let asked = Asked()

        /// Counts what the walk asked of the source, when a test cares.
        let counting: CountingProvider

        /// `materialized` decides whether these photographs need fetching at
        /// all: a referenced one *is* the file on its source and is never
        /// copied, so it is never asked for.
        init(photos: [String], materialized: Bool = true) async throws {
            folder = TemporaryFolder(name: "pgr-walk-src")
            cacheRoot = TemporaryFolder(name: "pgr-walk-dst")
            for name in photos { folder.write(name, bytes: 2048) }

            library = try TestLibrary()
            bytes = PhotoStore(root: cacheRoot.url.appending(path: "cache"))
            let access = UnsandboxedFileAccess()
            counting = CountingProvider(wrapping: FolderSourceProvider(fileAccess: access))
            store = SourceStore(
                database: library.database, fileAccess: access,
                providers: [counting, FileSourceProvider(fileAccess: access)], bytes: bytes)
            cache = PhotoCache(
                database: library.database, root: cacheRoot.url.appending(path: "cache"),
                sources: store, store: bytes)
            try cache.prepare()

            source = try store.add(kind: .folder, locator: folder.path)
            _ = await store.refresh(source)
            if materialized {
                try library.database.run("UPDATE photo SET storage = 'materialized';")
            }
            cache.log = heard.log
            cache.wantsCaching = asked.want
        }

        /// Cards on the queue, bytes nowhere.
        @discardableResult
        func dealAll() throws -> Int {
            var dealt = 0
            while try cache.deal() { dealt += 1 }
            return dealt
        }

        /// Fetches the bytes for everything queued, the way the cache queue's
        /// worker would.
        func cacheAll() async throws {
            for card in try cache.queue.peek(Int.max) {
                _ = try await cache.cache(photoID: card.id)
            }
        }

        func goOffline() throws {
            try library.database.run(
                "UPDATE source SET locator = :l WHERE id = :id;",
                ["l": "/Volumes/NotMounted/photos", "id": .int(source.id)])
        }

        var queued: Int { (try? cache.queue.size()) ?? 0 }
        var pooled: Int { (try? library.deck.poolSize()) ?? 0 }
        var resident: Int { (try? cache.status())?.residentCount ?? 0 }
    }

    // MARK: - 1. In the cache, so serve it

    @Test("A card whose bytes are here is the picture")
    func cachedCardIsServed() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try fixture.dealAll()
        try await fixture.cacheAll()

        let served = try #require(try await fixture.cache.serve())
        #expect(served.card.externalID == "a.png")
        #expect(fixture.asked.all.isEmpty, "nothing needed fetching, so nothing was asked for")
        // No box was asked for, so what goes out is the original rather than a
        // kept resize — and the line says which, because that is the only place
        // a console can see whether the renderings are earning their disk.
        #expect(
            fixture.heard.lines.contains {
                $0.hasPrefix("SERVE: a.png (source ")
                    && $0.contains(" is here as its original, showing it — ")
            })
    }

    @Test("Serving takes it off the queue, so the next request is a different picture")
    func servingConsumesTheCard() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try fixture.dealAll()
        try await fixture.cacheAll()
        #expect(fixture.queued == 2)

        let first = try #require(try await fixture.cache.serve())
        let second = try #require(try await fixture.cache.serve())
        #expect(first.card.id != second.card.id)
        #expect(fixture.queued == 0)
    }

    // MARK: - 2. Not in the cache: ask, drop, move on

    @Test("An uncached card is asked for, dropped, and the next one is served instead")
    func uncachedCardIsSkippedAndRequested() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try fixture.dealAll()

        // Bytes for exactly one of them. Whichever comes up first, the walk must
        // end on the one that is here.
        let queue = try fixture.cache.queue.peek(Int.max)
        let cached = try #require(queue.last)
        _ = try await fixture.cache.cache(photoID: cached.id)

        let served = try #require(try await fixture.cache.serve())

        #expect(served.card.id == cached.id)
        // The one it passed over was handed to the other queue, exactly once.
        #expect(fixture.asked.all == [try #require(queue.first).id])
        #expect(fixture.heard.lines.contains { $0.hasPrefix("SERVE:") && $0.contains("not cached yet") })
        // Both left the queue: one served, one dropped pending its bytes.
        #expect(fixture.queued == 0)
    }

    @Test("The request does not wait for the fetch it asked for")
    func servingNeverWaitsForBytes() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try fixture.dealAll()

        // Nothing cached, so this must come back at once rather than fetching.
        #expect(try await fixture.cache.serve() == nil)
        #expect(fixture.asked.all.count == 1)
        // And the photograph is untouched: it is waiting for bytes, not gone.
        #expect(fixture.pooled == 1)
    }

    @Test("A referenced photograph is never asked for, because there is nothing to fetch")
    func referencedPhotographsAreNotQueuedForCaching() async throws {
        // Referenced means the file on the source *is* the picture; we never
        // hold a copy. If it cannot be read, fetching would not help.
        let fixture = try await Fixture(photos: ["a.png"], materialized: false)
        try fixture.dealAll()
        fixture.folder.remove("a.png")

        #expect(try await fixture.cache.serve() == nil)
        #expect(fixture.asked.all.isEmpty, "asked for bytes that could never be fetched")
    }

    // MARK: - Looking ahead

    @Test("Serving asks for the bytes of the cards behind the one it served")
    func servingLooksAheadAndPrefetches() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png", "d.png"])
        try fixture.dealAll()
        let queued = try fixture.cache.queue.peek(Int.max)
        let head = try #require(queued.first)
        _ = try await fixture.cache.cache(photoID: head.id)

        let served = try #require(try await fixture.cache.serve())
        #expect(served.card.id == head.id)

        // **The walk stopped at the first card, and that is the problem this
        // solves.** Warming used to happen only as a side effect of walking
        // *past* uncached cards, so a source whose photographs are always
        // servable — anything referenced — meant the walk stopped immediately
        // and the uncached cards behind it were never asked for. A healthy
        // source starved the sick ones.
        #expect(Set(fixture.asked.all) == Set(queued.dropFirst().map(\.id)))

        // And looking ahead reads the queue rather than consuming it: those
        // three are still there to be served when their bytes land.
        #expect(fixture.queued == 3)
    }

    @Test("Looking ahead does not ask for what is already here")
    func lookAheadSkipsWhatIsCached() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try fixture.dealAll()
        try await fixture.cacheAll()

        _ = try #require(try await fixture.cache.serve())

        // Both were cached, so the one behind needs nothing. Asking anyway would
        // cost a fetch that the cache queue only discards when it comes off.
        #expect(fixture.asked.all.isEmpty)
    }

    @Test("Looking ahead is bounded, so one request cannot ask for the whole queue")
    func lookAheadIsBounded() async throws {
        let names = (0..<40).map { "p\($0).png" }
        let fixture = try await Fixture(photos: names)
        try fixture.dealAll()
        let head = try #require(try fixture.cache.queue.peek(1).first)
        _ = try await fixture.cache.cache(photoID: head.id)

        _ = try #require(try await fixture.cache.serve())

        // A cap matters for its own sake: when the Photos and Google providers
        // arrive, an unbounded look-ahead is a request that asks somebody else's
        // service for a queue's worth of originals at once.
        #expect(fixture.asked.all.count == PhotoCache.lookAheadDepth)
    }

    // MARK: - 3. Round the whole queue, then no picture

    @Test("A queue with nothing cached answers no picture, having asked for all of it")
    func aColdQueueAnswersNothing() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png", "d.png"])
        try fixture.dealAll()
        #expect(fixture.queued == 4)

        #expect(try await fixture.cache.serve() == nil)

        // Every one of them is now somebody else's problem, and the queue is
        // empty because each left as it was passed over.
        #expect(Set(fixture.asked.all).count == 4)
        #expect(fixture.queued == 0)
        #expect(fixture.heard.lines.contains("SERVE: nothing to show — out of cards, walked 4"))
    }

    @Test("The walk gives up on time as well as on cards, and says which")
    func theWalkIsBoundedByTime() async throws {
        // A cold queue of four. One cycle would walk all of them; a budget that
        // is already spent stops after the first.
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png", "d.png"])
        try fixture.dealAll()
        #expect(fixture.queued == 4)

        // **Zero, not a short sleep.** The bound is what is being tested, and a
        // test that waits for a real deadline is a test that is slow when it
        // passes and hangs when it breaks.
        #expect(try await fixture.cache.serve(within: .zero) == nil)

        // One card was still tried. Answering "no photo" without looking at a
        // single card would turn a slow moment into a blank screen.
        #expect(fixture.heard.lines.contains("SERVE: nothing to show — out of time, walked 1"))
        #expect(fixture.queued == 3)
        // And the walking it *did* do was not wasted: the card it passed over
        // has been asked for, so the next request is likelier to find it.
        #expect(fixture.asked.all.count == 1)
    }

    @Test("Running out of cards says so, and is not reported as running out of time")
    func runningOutOfCardsSaysSo() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try fixture.dealAll()

        #expect(try await fixture.cache.serve(within: .seconds(60)) == nil)
        #expect(fixture.heard.lines.contains("SERVE: nothing to show — out of cards, walked 2"))
    }

    @Test("A servable card inside the budget is still served")
    func theBudgetDoesNotCostAServableCard() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try fixture.dealAll()
        try await fixture.cacheAll()

        let served = try #require(try await fixture.cache.serve(within: .seconds(2)))
        #expect(served.card.externalID == "a.png")
    }

    @Test("Skipping an uncached card never asks its source anything")
    func skippingCostsNoSourceCheck() async throws {
        // Four cards, no bytes for any of them. Every one is going to be skipped
        // and handed to the cache queue.
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png", "d.png"])
        try fixture.dealAll()
        fixture.counting.reset()

        #expect(try await fixture.cache.serve(within: .seconds(60)) == nil)

        // **Zero, not four.** Asking a source whether a photograph is still
        // there is the single most expensive thing the walk can do — against a
        // network volume it is most of a second each — and it buys nothing for a
        // card whose bytes are not here, because the card is being skipped
        // whatever the answer. The check is a guarantee about what is *shown*,
        // so it belongs to the card being handed over and to no other.
        #expect(fixture.counting.checks == 0)
        #expect(fixture.asked.all.count == 4, "all four were still handed to the cache queue")
    }

    @Test("The card actually served is still checked against its source")
    func theServedCardIsStillVerified() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try fixture.dealAll()
        try await fixture.cacheAll()
        fixture.counting.reset()

        _ = try #require(try await fixture.cache.serve())

        // The guarantee is unchanged: a photograph the user deleted is never
        // shown, not even one we hold our own copy of.
        #expect(fixture.counting.checks == 1)
    }

    @Test("The walk is bounded by one cycle, so it cannot chase its own tail")
    func theWalkIsBounded() async throws {
        // On disk rather than in memory, because the point is a *second*
        // connection putting cards back while the walk is going — which is what
        // a fetch finishing instantly looks like, and what would make an
        // unbounded walk run for ever.
        let directory = URL.temporaryDirectory.appending(path: "pgr-bound-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try TestLibrary.onDisk(at: directory)
        let path = TestLibrary.path(in: directory)

        let folder = TemporaryFolder(name: "pgr-bound-src")
        folder.write("a.png")
        folder.write("b.png")

        let bytes = PhotoStore(root: directory.appending(path: "cache"))
        let store = SourceStore(database: library.database, bytes: bytes)
        var cache = PhotoCache(
            database: library.database, root: directory.appending(path: "cache"),
            sources: store, store: bytes)
        try cache.prepare()
        let source = try store.add(kind: .folder, locator: folder.path)
        _ = await store.refresh(source)
        try library.database.run("UPDATE photo SET storage = 'materialized';")
        while try cache.deal() {}

        let sourceID = source.id
        cache.wantsCaching = { photoID in
            guard let database = try? Database(path: path) else { return }
            _ = try? PhotoQueue(database: database).append(photoID: photoID, sourceID: sourceID)
        }

        #expect(try await cache.serve() == nil)
        #expect(
            try cache.queue.size() == 2,
            "the cards came straight back, which is exactly the case the bound is for")
    }

    @Test("An empty queue answers no picture without walking anything")
    func anEmptyQueueAnswersNothing() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        #expect(try await fixture.cache.serve() == nil)
        #expect(fixture.heard.lines.contains("SERVE: nothing to show — out of cards, walked 0"))
    }

    // MARK: - 4. Fetched, and back on the queue

    @Test("A finished fetch leaves the queue alone, and the photograph serves when next dealt")
    func cachingDoesNotRequeue() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try fixture.dealAll()

        // Serving passes it over and asks for it.
        #expect(try await fixture.cache.serve() == nil)
        #expect(fixture.queued == 0)
        let wanted = try #require(fixture.asked.all.first)

        #expect(try await fixture.cache.cache(photoID: wanted))

        // **What is queued is the deck's business alone.** Putting fetched
        // photographs back would top the queue up in the order fetches finish,
        // so the fastest source would drift to owning it whatever its size.
        #expect(fixture.queued == 0, "the fetch put the photograph back in the queue")
        #expect(fixture.resident == 1, "but its bytes are here")

        // It comes back the ordinary way, and serves at once when it does.
        #expect(try fixture.cache.deal())
        let served = try #require(try await fixture.cache.serve())
        #expect(served.card.id == wanted)
    }

    @Test("Asking for a photograph already cached costs a skip, not a second fetch")
    func cachingSomethingAlreadyHeldDoesNothing() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try fixture.dealAll()
        let card = try #require(try fixture.cache.queue.peek().first)
        #expect(try await fixture.cache.cache(photoID: card.id))

        // The second request comes off the queue, finds the bytes already here,
        // and stops. **This is the whole of the dedup** — the check is at the
        // fetch, not at the asking.
        #expect(try await fixture.cache.cache(photoID: card.id) == false)
        #expect(fixture.resident == 1)
    }

    @Test("A fetch that fails from an online source removes the photograph")
    func aFailedFetchFromAnOnlineSourceRemovesIt() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try fixture.dealAll()
        let card = try #require(try fixture.cache.queue.peek().first)

        // The source is right there and the file is not, so it is gone.
        fixture.folder.remove("a.png")
        #expect(try await fixture.cache.cache(photoID: card.id) == false)
        #expect(fixture.pooled == 0)
    }

    @Test("A fetch that fails from an offline source keeps everything")
    func aFailedFetchFromAnOfflineSourceKeepsIt() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try fixture.dealAll()
        let card = try #require(try fixture.cache.queue.peek().first)
        try fixture.goOffline()

        #expect(try await fixture.cache.cache(photoID: card.id) == false)
        // Unreachable says nothing about the photograph: it keeps its row and
        // its deal history, and comes round again when the drive is back.
        #expect(fixture.pooled == 1)
    }

    // MARK: - The states a source can be in, seen through the walk

    @Test("An offline source serves what we hold and skips what we do not")
    func offlineServesWhatIsHeld() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try fixture.dealAll()
        let queue = try fixture.cache.queue.peek(Int.max)
        let held = try #require(queue.first)
        _ = try await fixture.cache.cache(photoID: held.id)

        // The drive goes away *after* one of them was fetched. This is the case
        // that used to fail: the copy we hold could not be reached, because
        // producing had already written the source off.
        try fixture.goOffline()

        let served = try #require(try await fixture.cache.serve())
        #expect(served.card.id == held.id)
        #expect(fixture.pooled == 2, "an undock deletes nothing")
    }

    @Test("A photograph deleted from a source that is right there is dropped, not skipped")
    func deletedPhotographsAreDropped() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try fixture.dealAll()
        try await fixture.cacheAll()
        #expect(fixture.resident == 2)

        fixture.folder.remove("a.png")

        // Whatever order they come up in, the deleted one never goes out and
        // does not survive the walk.
        var served: [String] = []
        while let next = try await fixture.cache.serve() { served.append(next.card.externalID) }
        #expect(served == ["b.png"])
        #expect(fixture.pooled == 1)
        #expect(fixture.resident == 1, "its cached copy went with it")
        #expect(fixture.heard.lines.contains { $0.hasPrefix("SERVE: a.png (source ") && $0.contains(" dropped") })
    }

    @Test("A source that is gone takes its photographs with it as they come up")
    func goneSourcesAreDropped() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try fixture.dealAll()
        try await fixture.cacheAll()

        // The folder is deleted while its volume stays — which is *gone*, not
        // offline, and the opposite answer.
        try FileManager.default.removeItem(at: fixture.folder.url)

        #expect(try await fixture.cache.serve() == nil)
        #expect(fixture.pooled == 0)
        #expect(fixture.resident == 0)
    }

    // MARK: - What it says while doing it

    @Test("Both queues say what they did, and each line names which queue it was")
    func everyDecisionIsSaid() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try fixture.dealAll()
        _ = try await fixture.cache.serve()
        let card = try #require(fixture.asked.all.first)
        _ = try await fixture.cache.cache(photoID: card)
        // Dealt again the ordinary way — a fetch does not put it back.
        try fixture.dealAll()
        _ = try await fixture.cache.serve()

        let lines = fixture.heard.lines
        #expect(lines.contains { $0.hasPrefix("DEAL: a.png (source ") })
        #expect(lines.contains { $0.hasPrefix("SERVE: a.png (source ") && $0.contains(" skipped") })
        #expect(lines.contains { $0.hasPrefix("SERVE: nothing to show") })
        #expect(lines.contains { $0.hasPrefix("CACHE: a.png (source ") && $0.contains(" fetched") })
        #expect(lines.contains { $0.hasPrefix("SERVE: a.png (source ") && $0.contains(" is here") })
        // Every line names what it belongs to, so several interleaved on one
        // console stay readable and each can be filtered out on its own.
        #expect(
            lines.allSatisfy {
                $0.hasPrefix("DEAL: ") || $0.hasPrefix("SERVE: ") || $0.hasPrefix("CACHE: ")
            })
    }

    @Test("Keeping a resize of a photograph on disk says so under CACHE:")
    func keepingAResizeOfAReferencedPhotographIsSaid() async throws {
        // Referenced: its original *is* the file on the disk it lives on, so it
        // is never fetched and a resize is the only thing the cache will ever
        // hold for it. That is the case that used to fill the cache without
        // printing a line — the fetch queue was the only thing saying `CACHE:`,
        // and this path never touches it.
        let fixture = try await Fixture(photos: ["a.png"], materialized: false)
        try fixture.dealAll()
        let served = try #require(try await fixture.cache.serve())

        _ = try fixture.cache.keep(
            Data(count: 1234), of: served.card,
            at: PhotoStore.Size(width: 800, height: 600), pathExtension: "jpeg")

        #expect(
            fixture.heard.lines.contains {
                $0 == "CACHE: resized a.png (source \(fixture.source.id)) to 800x600 "
                    + "from its file on disk, kept 1234 bytes"
            })
    }

    @Test("Keeping a resize of a fetched photograph says it came from the cached original")
    func keepingAResizeOfAMaterialisedPhotographIsSaid() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try fixture.dealAll()
        try await fixture.cacheAll()
        let served = try #require(try await fixture.cache.serve())

        _ = try fixture.cache.keep(
            Data(count: 99), of: served.card,
            at: PhotoStore.Size(width: 100, height: 100), pathExtension: "jpeg")

        #expect(
            fixture.heard.lines.contains {
                $0 == "CACHE: resized a.png (source \(fixture.source.id)) to 100x100 "
                    + "from the cached original, kept 99 bytes"
            })
    }

    @Test("Serving says whether the bytes are the original or a kept resize")
    func servingNamesWhichBytesWentOut() async throws {
        let fixture = try await Fixture(photos: ["a.png"], materialized: false)
        try fixture.dealAll()
        let served = try #require(try await fixture.cache.serve())
        let box = PhotoStore.Size(width: 800, height: 600)
        _ = try fixture.cache.keep(
            Data(count: 1234), of: served.card, at: box, pathExtension: "jpeg")

        // Dealt again and asked for at exactly the size just kept, which is the
        // only way the held resize is what goes out.
        try fixture.dealAll()
        _ = try #require(try await fixture.cache.serve(fitting: box))

        let lines = fixture.heard.lines
        #expect(lines.contains { $0.contains("is here as its original, showing it") })
        #expect(lines.contains { $0.contains("is here as a kept resize, showing it") })
    }
}

/// Wraps a real provider and counts what the walk asks of the source.
///
/// **The point of the count is cost, not behaviour.** Asking a source whether a
/// photograph is still there means a stat against wherever that source lives,
/// which on a network volume measures in whole seconds — so a walk that asks it
/// about cards it is going to skip anyway pays that price for nothing.
final class CountingProvider: SourceProvider, @unchecked Sendable {
    private let inner: any SourceProvider
    private let lock = NSLock()
    private var existenceChecks = 0

    init(wrapping inner: any SourceProvider) { self.inner = inner }

    var kind: SourceKind { inner.kind }

    var checks: Int {
        lock.lock()
        defer { lock.unlock() }
        return existenceChecks
    }

    /// Zeroes the count, so a test measures one walk rather than everything the
    /// fixture did to get there — a scan asks about every photograph it finds.
    func reset() {
        lock.lock()
        existenceChecks = 0
        lock.unlock()
    }

    func enumerate(
        _ source: Source, into sink: (DiscoveredPhoto) throws -> Void
    ) async throws -> SourceReachability {
        try await inner.enumerate(source, into: sink)
    }

    func existence(of externalID: String, in source: Source) async -> PhotoExistence {
        // Counted in its own non-async call, so the lock is never held across
        // the suspension below.
        note()
        return await inner.existence(of: externalID, in: source)
    }

    private func note() {
        lock.lock()
        existenceChecks += 1
        lock.unlock()
    }

    func availability(of source: Source) async -> SourceAvailability {
        await inner.availability(of: source)
    }

    func materialize(
        externalID: String, from source: Source, to destination: URL
    ) async throws -> MaterializedFile {
        try await inner.materialize(externalID: externalID, from: source, to: destination)
    }
}
