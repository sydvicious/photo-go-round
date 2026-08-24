import Foundation
import Testing

@testable import PhotoGoRoundKit

/// The index has to be read before it can be reported on.
///
/// One of three faults found on 2026-08-23 by watching a real library. The other
/// two — a repeat window measured against the whole library while candidates
/// were chosen per source, and production choosing a photograph before knowing
/// it could fetch it — were artifacts of per-source dealing, and their tests went
/// with the machinery when the deck began dealing over everything. This one was
/// independent of all that and stays.
@Suite("Reading the cache index")
struct CacheIndexTests {

    /// A library with two sources of very different sizes, and real bytes in the
    /// cache for some of them.
    private struct Fixture {
        let folder: TemporaryFolder
        let cacheRoot: TemporaryFolder
        let library: TestLibrary
        let bytes: PhotoStore
        let store: SourceStore
        let cache: PhotoCache

        init() throws {
            folder = TemporaryFolder(name: "pgr-cycle-src")
            cacheRoot = TemporaryFolder(name: "pgr-cycle-dst")
            library = try TestLibrary()
            bytes = PhotoStore(root: cacheRoot.url.appending(path: "cache"))
            store = SourceStore(database: library.database, bytes: bytes)
            cache = PhotoCache(
                database: library.database, root: cacheRoot.url.appending(path: "cache"),
                sources: store, store: bytes)
            try cache.prepare()
        }

        /// Rows only — no provider, no files.
        @discardableResult
        func source(photos: Int, available: Bool = true, name: String) throws -> Int64 {
            let id = try library.addSource(locator: "/photos/\(name)")
            try library.addPhotos(photos, to: id, namePrefix: name)
            try library.database.run("UPDATE photo SET storage = 'materialized' WHERE source_id = :s;", ["s": .int(id)])
            if !available {
                try store.markUnavailable(sourceID: id, reason: "volume not mounted")
            }
            return id
        }

        /// Puts real bytes in the cache for `count` of a source's photographs,
        /// oldest first, and answers which ones.
        @discardableResult
        func hold(_ count: Int, ofSource sourceID: Int64) throws -> Set<String> {
            let sourceUUID = try #require(
                try library.database.scalarString(
                    "SELECT uuid FROM source WHERE id = :id;", ["id": .int(sourceID)]))
            let uuids = try library.database.all(
                "SELECT uuid FROM photo WHERE source_id = :s ORDER BY id LIMIT :n;",
                ["s": .int(sourceID), "n": .int(Int64(count))]
            ) { try $0.string("uuid") }

            for uuid in uuids {
                _ = try bytes.store(
                    Data(repeating: 0xAB, count: 64), for: PhotoStore.Key(photoUUID: uuid),
                    sourceUUID: sourceUUID, pathExtension: "heic")
            }
            return Set(uuids)
        }
    }

    // MARK: - The index has to be read before it can be reported

    /// **The bug**: both the agent's status line and `pgr_ctl status` built a
    /// `PhotoCache` without handing it the process's byte index, so they made a
    /// fresh empty one and reported nought held — while the cache directory had
    /// a hundred and forty-eight megabytes in it.
    @Test("A fresh index reports nothing until it has read the disk, and everything after")
    func aFreshIndexMustBeRead() throws {
        let fixture = try Fixture()
        let source = try fixture.source(photos: 3, name: "local")
        try fixture.hold(3, ofSource: source)

        #expect(try fixture.cache.status().residentCount == 3)

        // A second process over the same directory: same files, empty index.
        let cold = PhotoStore(root: fixture.cache.root)
        let coldCache = PhotoCache(
            database: fixture.library.database, root: fixture.cache.root,
            sources: fixture.store, store: cold)
        #expect(
            try coldCache.status().residentCount == 0,
            "an index nobody read should know nothing — otherwise this test proves nothing")

        cold.index(photos: try Self.owners(fixture.library.database))
        #expect(try coldCache.status().residentCount == 3)
        #expect(try coldCache.status().bytesOnDisk > 0)
    }

    @Test("Reading the index read-only leaves files that nothing claims alone")
    func indexingDoesNotDelete() throws {
        let fixture = try Fixture()
        let source = try fixture.source(photos: 1, name: "local")
        try fixture.hold(1, ofSource: source)

        // A file belonging to a photograph this database has never heard of —
        // which is exactly what a status command run against another library's
        // cache would see, and must not delete.
        let stray = fixture.cache.root.appending(path: "someone-else/.original/stray.heic")
        try FileManager.default.createDirectory(
            at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 32).write(to: stray)

        let owners = try Self.owners(fixture.library.database)
        let cold = PhotoStore(root: fixture.cache.root)
        let read = cold.index(photos: owners)

        #expect(read.discarded == 0)
        #expect(FileManager.default.fileExists(atPath: stray.path(percentEncoded: false)))

        // Rebuilding is the owning form, and it *does* take it — that is the
        // launch-time sweep, and the difference between the two is the point.
        let owning = PhotoStore(root: fixture.cache.root)
        #expect(owning.rebuild(photos: owners).discarded == 1)
        #expect(!FileManager.default.fileExists(atPath: stray.path(percentEncoded: false)))
    }

    private static func owners(_ database: Database) throws -> [String: String] {
        var owners: [String: String] = [:]
        try database.query(
            "SELECT p.uuid AS photo_uuid, s.uuid AS source_uuid"
                + " FROM photo p JOIN source s ON s.id = p.source_id;"
        ) { row in
            owners[try row.string("photo_uuid")] = try row.string("source_uuid")
        }
        return owners
    }
}
