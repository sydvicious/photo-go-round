import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// **Serving waits for the head card's bytes, once, and then moves on.**
///
/// Decided 2026-09-05. A card is dealt whether or not its bytes are here, the
/// queue's fetcher goes and gets them, and a request that reaches a card before
/// they land waits — up to `serveWait` — for one of three things: the bytes
/// land, the card leaves the queue because its fetch failed, or the wait runs
/// out. When it runs out the card is dropped and the request takes the first
/// card whose bytes are here, without waiting again.
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
        let fixture = try await Fixture(photos: ["a.png"], wait: .seconds(10))
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
        #expect(clock.now - started < .seconds(5), "the request waited out its whole bound")
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
        fixture.bytes.remove(PhotoStore.Key(photoUUID: head.uuid))
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

    @Test("With no warm card after the wait, the request answers nothing and drops only the head")
    func timeoutWithNothingWarm() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"], wait: .milliseconds(200))
        defer { fixture.cleanUp() }
        try fixture.dealAll()

        #expect(try await fixture.cache.serve() == nil)

        // One wait, one drop. The second card was never waited on and keeps its
        // place for the fetcher to reach.
        #expect(fixture.waited() == 1)
        #expect(fixture.dropped().count == 1)
        #expect(fixture.queued == 1)
        #expect(fixture.heard.lines.contains("SERVE: nothing to show — out of cards, walked 1"))
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

    @Test("A wait of zero never waits and never drops")
    func zeroWaitNeverWaits() async throws {
        let fixture = try await Fixture(photos: ["a.png"], wait: .zero)
        defer { fixture.cleanUp() }
        try fixture.dealAll()

        #expect(try await fixture.cache.serve() == nil)

        // Nothing has bytes, so nothing is served; and with no wait there was
        // nothing to run out, so nothing is dropped either. Only the fetcher's
        // own failure drops a card now.
        #expect(fixture.waited() == 0)
        #expect(fixture.dropped().isEmpty)
        #expect(fixture.queued == 1)
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
