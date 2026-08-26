import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// `photo.cached_at` is a projection of the byte store, and these are the
/// assertions that keep it one.
///
/// The whole value of the column is that the deck's pool can be a `WHERE`
/// clause. That is only worth anything if the clause answers the same question
/// `PhotoStore.residentPhotoUUIDs` does, so every test here compares the two
/// rather than checking the column against itself.
@Suite("Residency")
struct ResidencyTests {

    private struct Fixture {
        let folder: TemporaryFolder
        let cacheRoot: TemporaryFolder
        let library: TestLibrary
        let sources: SourceStore
        let cache: PhotoCache
        let source: Source

        init(photos: [String], settings: CacheSettings = .default) async throws {
            folder = TemporaryFolder(name: "pgr-residency-src")
            cacheRoot = TemporaryFolder(name: "pgr-residency-dst")
            for name in photos { folder.write(name, bytes: 100) }

            library = try TestLibrary()
            sources = SourceStore(database: library.database)
            cache = PhotoCache(
                database: library.database,
                root: cacheRoot.url.appending(path: "cache"),
                settings: settings,
                sources: sources
            )
            try cache.prepare()

            source = try await sources.add(kind: .folder, locator: folder.path, recursive: true)
            await sources.refresh(source)
            try library.database.run("UPDATE photo SET storage = 'materialized';")
        }

        /// What the database believes is held.
        func recorded() throws -> Set<String> {
            Set(
                try library.database.all("SELECT uuid FROM photo WHERE cached_at IS NOT NULL;") {
                    try $0.string("uuid")
                })
        }

        /// What the disk actually holds.
        var held: Set<String> { cache.store.residentPhotoUUIDs }

        func photoIDs() throws -> [Int64] {
            try library.database.all("SELECT id FROM photo ORDER BY id;") { try $0.int64("id") }
        }
    }

    @Test("nothing is recorded as held before anything is fetched")
    func startsEmpty() async throws {
        let fixture = try await Fixture(photos: ["a.jpg", "b.jpg", "c.jpg"])
        #expect(try fixture.recorded().isEmpty)
        #expect(fixture.held.isEmpty)
    }

    @Test("fetching a photograph records it, and only it")
    func fetchRecords() async throws {
        let fixture = try await Fixture(photos: ["a.jpg", "b.jpg", "c.jpg"])
        let first = try #require(try fixture.photoIDs().first)

        #expect(try await fixture.cache.cache(photoID: first))

        #expect(try fixture.recorded() == fixture.held)
        #expect(try fixture.recorded().count == 1)
    }

    @Test("the column tracks the store across every operation")
    func tracksThroughout() async throws {
        let fixture = try await Fixture(photos: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        for id in try fixture.photoIDs() {
            _ = try await fixture.cache.cache(photoID: id)
            #expect(try fixture.recorded() == fixture.held)
        }
        #expect(try fixture.recorded().count == 4)
    }

    @Test("a hand-deleted cache file is corrected by the launch walk")
    func launchWalkCorrectsDrift() async throws {
        let fixture = try await Fixture(photos: ["a.jpg", "b.jpg"])
        for id in try fixture.photoIDs() { _ = try await fixture.cache.cache(photoID: id) }
        #expect(try fixture.recorded().count == 2)

        // Somebody tidied the cache directory out from under the agent. The
        // database still claims both; the disk has neither.
        try FileManager.default.removeItem(at: fixture.cache.root)
        #expect(try fixture.recorded().count == 2)

        try fixture.cache.prepare()

        #expect(fixture.held.isEmpty)
        #expect(try fixture.recorded().isEmpty)
        #expect(try fixture.recorded() == fixture.held)
    }

    @Test("an upgraded database with the column empty is filled by the walk")
    func upgradeIsReconciled() async throws {
        let fixture = try await Fixture(photos: ["a.jpg", "b.jpg"])
        for id in try fixture.photoIDs() { _ = try await fixture.cache.cache(photoID: id) }

        // Exactly the state migration 7 leaves behind: bytes on disk, column
        // NULL for every row.
        try fixture.library.database.run("UPDATE photo SET cached_at = NULL;")
        #expect(try fixture.recorded().isEmpty)
        #expect(fixture.held.count == 2)

        try fixture.cache.prepare()

        #expect(try fixture.recorded() == fixture.held)
    }

    @Test("eviction releases the originals it took")
    func evictionReleases() async throws {
        // A ceiling that only one original fits under, so the rest go.
        let fixture = try await Fixture(
            photos: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"],
            settings: CacheSettings(byteCeiling: 150))
        for id in try fixture.photoIDs() { _ = try await fixture.cache.cache(photoID: id) }

        // Fetching re-queues, and a queued photograph is protected from
        // eviction whatever its age — so with everything cached *and* queued,
        // eviction can free nothing at all. That is the unreachable-ceiling
        // hole phase 6 removes; here it is only in the way, so the queue is
        // emptied to leave eviction something it is allowed to take.
        try fixture.library.database.run("DELETE FROM queue;")

        let eviction = try fixture.cache.evictIfNeeded()
        #expect(eviction.evicted > 0)
        #expect(try fixture.recorded() == fixture.held)
    }

    @Test("clearing everything releases everything")
    func clearReleases() async throws {
        let fixture = try await Fixture(photos: ["a.jpg", "b.jpg", "c.jpg"])
        for id in try fixture.photoIDs() { _ = try await fixture.cache.cache(photoID: id) }
        #expect(try fixture.recorded().count == 3)

        _ = try fixture.cache.clear(.everything)

        #expect(fixture.held.isEmpty)
        #expect(try fixture.recorded().isEmpty)
    }

    @Test("removing a photograph takes its residency with the row")
    func removalTakesResidency() async throws {
        let fixture = try await Fixture(photos: ["a.jpg", "b.jpg"])
        let ids = try fixture.photoIDs()
        for id in ids { _ = try await fixture.cache.cache(photoID: id) }

        _ = try fixture.cache.remove(ids[0])

        #expect(try fixture.recorded() == fixture.held)
        #expect(try fixture.recorded().count == 1)
    }
}
