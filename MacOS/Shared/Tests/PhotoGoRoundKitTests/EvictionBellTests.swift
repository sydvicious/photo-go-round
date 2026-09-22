import Foundation
import Synchronization
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// Who evicts after a write, and whether the writer waits for it.
///
/// Syd, 2026-09-17: "you only need to use `await …` when you need the result,
/// or you need the side effect", and "async code is all about getting stuff out
/// of the way." A cache with a bell rings it and carries on; a cache without one
/// — `pgr_ctl`, and most of these tests — evicts where it wrote.
/// `Plans/Agent Performance Overhaul.md`, Phase 5.
@Suite("The eviction bell")
struct EvictionBellTests {

    private final class Rings: Sendable {
        private let count = Mutex(0)
        func ring() { count.withLock { $0 += 1 } }
        var rung: Int { count.withLock { $0 } }
    }

    private final class Evictions: Sendable {
        private let list = Mutex<[PhotoCache.EvictionResult]>([])
        func record(_ result: PhotoCache.EvictionResult) { list.withLock { $0.append(result) } }
        var all: [PhotoCache.EvictionResult] { list.withLock { $0 } }
    }

    /// Two photographs of 2,048 bytes each, held, under a ceiling they exactly
    /// fill — so any copy kept goes over it and eviction has something to do.
    private final class Fixture {
        let directory: URL
        let folder = TemporaryFolder(name: "pgr-bell-src")
        let library: TestLibrary
        let bytes: PhotoStore
        let cache: PhotoCache
        let evictions = Evictions()
        private(set) var photos: [(id: Int64, uuid: String)] = []

        init(bell: Rings?) async throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-bell-\(UUID().uuidString)")
            for index in 0..<2 { folder.write("photo-\(index).png", bytes: 2048) }
            library = try TestLibrary.onDisk(at: directory)
            var ring: (@Sendable () -> Void)?
            if let bell { ring = { bell.ring() } }
            bytes = PhotoStore(root: directory.appending(path: "cache"), evictionBell: ring)
            let sources = SourceStore(database: library.database, bytes: bytes)
            var cache = PhotoCache(
                database: library.database, root: directory.appending(path: "cache"),
                settings: CacheSettings(byteCeiling: 4096), sources: sources, store: bytes)
            cache.log = { _ in }
            cache.copySweep = ResizedCopies.Sweep()
            let evictions = evictions
            cache.evicted = { evictions.record($0) }
            try await cache.prepare()
            self.cache = cache
            let source = try sources.add(kind: .folder, locator: folder.path)
            _ = await sources.refresh(source)
            try library.database.run("UPDATE photo SET storage = 'materialized';")
            _ = try await cache.fillCompletely(limit: 2)
            photos = try library.database.all(
                "SELECT id, uuid FROM photo ORDER BY external_id;"
            ) { (id: try $0.int64("id"), uuid: try $0.string("uuid")) }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        var rendered: PhotoRenderer.Rendered {
            PhotoRenderer.Rendered(
                bytes: Data(repeating: 7, count: 1000), format: .heic, width: 200, height: 150)
        }

        @discardableResult
        func keepACopy() async throws -> ResizedCopies.Copy? {
            try await cache.keep(
                rendered, photoID: photos[0].id, photoUUID: photos[0].uuid,
                boxWidth: 200, boxHeight: 150)
        }
    }

    /// **The point of the bell.** The copy is written and the caller has it
    /// back; bringing the cache under its ceiling is somebody else's turn.
    @Test("A write rings the bell and evicts nothing where it wrote")
    func aWriteRingsRatherThanEvicting() async throws {
        let rings = Rings()
        let fixture = try await Fixture(bell: rings)
        // Filling the cache adopted two originals, and each of those is a write
        // that rang too. What this test is about is the copy.
        let before = rings.rung

        let copy = try await fixture.keepACopy()

        #expect(copy != nil)
        #expect(rings.rung == before + 1)
        #expect(fixture.evictions.all.isEmpty, "it evicted although somebody was rung")
        #expect(
            try await fixture.cache.bytesOnDisk() > 4096,
            "nothing should have come back under the ceiling yet")
    }

    /// The other half, and the reason the bell is optional: a cache with nobody
    /// to ring must still come back under its ceiling.
    @Test("A write with no bell evicts where it wrote")
    func aWriteWithNoBellEvictsHere() async throws {
        let fixture = try await Fixture(bell: nil)

        try await fixture.keepACopy()

        #expect(fixture.evictions.all.count == 1)
        #expect(fixture.evictions.all.first?.evicted ?? 0 > 0)
        #expect(try await fixture.cache.bytesOnDisk() <= 4096)
    }
}
