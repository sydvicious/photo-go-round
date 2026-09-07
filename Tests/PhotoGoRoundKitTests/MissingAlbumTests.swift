import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// A Photos album that stops resolving while the library stays readable.
///
/// **This is the 2026-09-07 rebuild, replayed.** Photos rebuilt its library and
/// renumbered two albums, and with them every asset identifier inside. Nothing
/// was deleted; the identifiers we hold simply name nothing any more. The rule
/// is that an album which is not there says nothing about its photographs: what
/// the cache holds keeps being served, and no row goes until the person acts.
/// See `Missing Albums Plan.md`.
///
/// The rebuild is played against the database rather than the fake library,
/// because that is exactly what a rebuild looks like from the agent's side —
/// the library moved on and the rows describe a world that is gone.
@Suite("A missing album")
struct MissingAlbumTests {

    private static let album = "DAD90FB7-1F24-463E-8688-A8504D7283C7/L0/040"
    private static let assets = ["ASSET-A/L0/001", "ASSET-B/L0/001"]

    private struct Fixture {
        let cacheRoot: TemporaryFolder
        let library: TestLibrary
        let bytes: PhotoStore
        let store: SourceStore
        var cache: PhotoCache
        let source: Source
        let heard = ServeWalkTests.Heard()

        init() async throws {
            cacheRoot = TemporaryFolder(name: "pgr-missing-album")
            library = try TestLibrary()
            bytes = PhotoStore(root: cacheRoot.url.appending(path: "cache"))

            let photos = FakePhotoLibrary(
                titles: [album: "Kids 2019"],
                assets: [album: assets.map { LibraryAsset(identifier: $0) }],
                resources: Dictionary(
                    uniqueKeysWithValues: assets.map {
                        (
                            $0,
                            [
                                LibraryResource(
                                    kind: .photo, uniformTypeIdentifier: "public.jpeg",
                                    originalFilename: "IMG.JPG")
                            ]
                        )
                    }))
            store = SourceStore(
                database: library.database,
                providers: [PhotosCollectionSourceProvider(library: photos)],
                bytes: bytes)
            cache = PhotoCache(
                database: library.database, root: cacheRoot.url.appending(path: "cache"),
                sources: store, store: bytes)
            try cache.prepare()

            source = try store.add(kind: .photosCollection, locator: album)
            _ = await store.refresh(source)
            cache.log = heard.log
            cache.serveWait = .milliseconds(200)
        }

        /// Deals both cards and fetches exactly one, so the queue holds one
        /// warm card and one cold — the state a running agent is always in.
        func dealAndHoldOne() async throws -> Int64 {
            while try cache.deal() {}
            guard case .fetched = await cache.fetchQueuedOnce() else {
                throw Failure("the head card was not fetched")
            }
            return try #require(
                try library.database.first(
                    "SELECT id FROM photo WHERE cached_at IS NOT NULL;") { try $0.int64("id") })
        }

        /// Photos rebuilds its library: the album and every asset in it get
        /// new identifiers, and the ones we stored resolve to nothing.
        func rebuild() throws {
            try library.database.run(
                "UPDATE source SET locator = :l WHERE id = :id;",
                ["l": .text("REBUILT-0000-0000-0000-000000000000/L0/041"), "id": .int(source.id)])
            try library.database.run("UPDATE photo SET external_id = 'OLD-' || external_id;")
        }

        var pooled: Int {
            (try? library.database.scalarInt("SELECT COUNT(*) FROM photo;")) ?? 0
        }
        var queued: Int { (try? cache.queue.size()) ?? 0 }

        struct Failure: Error, CustomStringConvertible {
            let description: String
            init(_ description: String) { self.description = description }
        }
    }

    @Test("What the cache holds is served, unconfirmed, and its row stays")
    func heldPhotographsKeepServing() async throws {
        let fixture = try await Fixture()
        let held = try await fixture.dealAndHoldOne()

        try fixture.rebuild()

        // The held one goes out. The cold one is waited on, dropped from the
        // queue for want of bytes, and *kept* — a card was spent and nothing
        // was learned about the photograph.
        let served = try #require(try await fixture.cache.serve())
        #expect(served.card.id == held)
        #expect(try await fixture.cache.serve() == nil)

        #expect(fixture.pooled == 2, "a missing album deletes nothing")
        #expect(fixture.queued == 0)
        let unconfirmed = fixture.heard.all.contains {
            if case .serving(_, _, let unconfirmed, _) = $0 { return unconfirmed != nil }
            return false
        }
        #expect(unconfirmed, "the picture went out marked unconfirmed")
        #expect(
            !fixture.heard.lines.contains { $0.contains("gone from a source that is right there") },
            "nothing was called gone")
    }

    @Test("A fetch that fails against a missing album keeps the row")
    func failedFetchesDeleteNothing() async throws {
        let fixture = try await Fixture()
        _ = try await fixture.dealAndHoldOne()

        try fixture.rebuild()

        // The cold card's fetch fails — its identifier names nothing now. Only
        // a confirmed absence deletes, and an album that is not there cannot
        // confirm anything.
        guard case .failed = await fixture.cache.fetchQueuedOnce() else {
            Issue.record("the cold card's fetch did not fail"); return
        }
        #expect(fixture.pooled == 2)
        #expect(fixture.queued == 1, "the card left the queue; the photograph did not leave the pool")
    }
}
