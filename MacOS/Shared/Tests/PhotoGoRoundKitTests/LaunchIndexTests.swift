import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// The cache index at launch is what the database says, and the walk corrects it
/// afterwards.
///
/// `Agent Performance Overhaul.md`, Phase 6, *The cache index comes from the
/// database at launch*. Syd, 2026-09-17: "the agent can ask the database what
/// the cache was the last time it was alive, and can just try to get things out
/// of the cache and return it", "while the cache walk is going on", and "you
/// still need to do the cache walk periodically, especially at startup, to make
/// sure that the agent's idea of the filesystem matches what is actually on
/// disk". The walk was 8.9 s after a restart and 137 ms warm, and the port used
/// to wait for it.
@Suite("The launch index")
struct LaunchIndexTests {

    private final class Fixture {
        let directory: URL
        let folder = TemporaryFolder(name: "pgr-launch-src")
        let library: TestLibrary
        let bytes: PhotoStore
        let store: SourceStore
        let cache: PhotoCache

        init(photographs: Int) async throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-launch-\(UUID().uuidString)")
            for index in 0..<photographs { folder.write("photo-\(index).png", bytes: 2048) }
            library = try TestLibrary.onDisk(at: directory)
            bytes = PhotoStore(root: directory.appending(path: "cache"))
            store = SourceStore(database: library.database, bytes: bytes)
            var cache = PhotoCache(
                database: library.database, root: directory.appending(path: "cache"),
                sources: store, store: bytes)
            cache.log = { _ in }
            try await cache.prepare()
            self.cache = cache
            let source = try store.add(kind: .folder, locator: folder.path)
            _ = await store.refresh(source)
            try library.database.run("UPDATE photo SET storage = 'materialized';")
            _ = try await cache.fillCompletely(limit: photographs)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        /// A second agent's view of the same library, as a relaunch would build
        /// it: a fresh index that has never walked the disk.
        func relaunched() throws -> (PhotoStore, PhotoCache) {
            let bytes = PhotoStore(root: directory.appending(path: "cache"))
            var cache = PhotoCache(
                database: library.database, root: directory.appending(path: "cache"),
                sources: SourceStore(database: library.database, bytes: bytes), store: bytes)
            cache.log = { _ in }
            return (bytes, cache)
        }

        func held() throws -> Int {
            try library.database.scalarInt("SELECT COUNT(*) FROM photo WHERE cached_at IS NOT NULL;") ?? 0
        }
    }

    @Test("A relaunch knows what it had without walking the cache")
    func indexComesFromTheDatabase() async throws {
        let fixture = try await Fixture(photographs: 3)
        let (bytes, cache) = try fixture.relaunched()

        let held = try await cache.prepareFromDatabase()

        #expect(held.photos == 3)
        #expect(held.bytes == 3 * 2048)
        #expect(await bytes.totals.entries == 3)
        #expect(try fixture.held() == 3)
    }

    @Test("A photograph the database claims and the disk has is served straight from the file")
    func servesWithoutWalking() async throws {
        let fixture = try await Fixture(photographs: 2)
        let (bytes, cache) = try fixture.relaunched()
        try await cache.prepareFromDatabase()

        let uuid = try #require(try fixture.library.database.first(
            "SELECT uuid FROM photo WHERE cached_at IS NOT NULL LIMIT 1;", [:],
            { try $0.string("uuid") }))

        #expect(await bytes.url(forPhoto: uuid) != nil)
    }

    /// The file that went while the agent was not running: an ordinary miss,
    /// which is what lets the port open before the walk.
    @Test("A photograph the database claims and the disk has lost is a miss, not an error")
    func aMissingFileIsAMiss() async throws {
        let fixture = try await Fixture(photographs: 2)
        let (bytes, cache) = try fixture.relaunched()
        try await cache.prepareFromDatabase()
        let uuid = try #require(try fixture.library.database.first(
            "SELECT uuid FROM photo WHERE cached_at IS NOT NULL LIMIT 1;", [:],
            { try $0.string("uuid") }))
        let url = try #require(await bytes.url(forPhoto: uuid))
        try FileManager.default.removeItem(at: url)

        #expect(await bytes.url(forPhoto: uuid) == nil)
        #expect(await bytes.totals.entries == 1, "the store kept believing in a file that is gone")
    }

    @Test("The walk corrects what the database claimed, and says so in the database")
    func theWalkCorrectsIt() async throws {
        let fixture = try await Fixture(photographs: 3)
        let (bytes, cache) = try fixture.relaunched()
        try await cache.prepareFromDatabase()
        // One file goes behind the agent's back, as a hand-deleted file would.
        let uuid = try #require(try fixture.library.database.first(
            "SELECT uuid FROM photo WHERE cached_at IS NOT NULL ORDER BY id LIMIT 1;", [:],
            { try $0.string("uuid") }))
        let url = try #require(await bytes.url(forPhoto: uuid))
        try FileManager.default.removeItem(at: url)

        let walked = try await cache.walkCache()

        #expect(walked.kept == 2)
        #expect(await bytes.totals.entries == 2)
        #expect(try fixture.held() == 2, "the row still claims bytes the disk does not have")
    }

    /// Syd: "eviction waits for the walk" — a total the walk has not finished
    /// is not a total worth evicting against.
    @Test("Eviction takes nothing until the cache has been walked")
    func evictionWaitsForTheWalk() async throws {
        let fixture = try await Fixture(photographs: 3)
        let (bytes, _) = try fixture.relaunched()
        var tight = PhotoCache(
            database: fixture.library.database, root: fixture.directory.appending(path: "cache"),
            settings: CacheSettings(byteCeiling: 2500),
            sources: SourceStore(database: fixture.library.database, bytes: bytes), store: bytes)
        tight.log = { _ in }
        try await tight.prepareFromDatabase()

        await #expect(try tight.evictIfNeeded().evicted == 0, "evicted against a total nothing had checked")

        try await tight.walkCache()

        await #expect(try tight.evictIfNeeded().evicted > 0)
    }
}
