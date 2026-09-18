import Foundation
import Synchronization
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// The resize cache, below the endpoint: what a copy is keyed by, how full the
/// cache is with copies in it, what eviction takes, and what deletion takes.
///
/// Designed with Syd one question at a time on 2026-09-16; `Agent Performance
/// Overhaul.md`, *The resize cache, proposed*.
@Suite("Resized copies")
struct ResizedCopiesTests {

    /// Photographs from a folder, materialized so their originals are held in
    /// the store, each 2,048 bytes.
    private final class Fixture {
        let directory: URL
        let folder = TemporaryFolder(name: "pgr-copies-src")
        let library: TestLibrary
        let bytes: PhotoStore
        let store: SourceStore
        let cache: PhotoCache
        let source: Source
        /// Photo ids, in the order their files were named.
        private(set) var photos: [(id: Int64, uuid: String)] = []
        /// Every eviction a write set off, in order.
        let evictions = Evictions()

        final class Evictions: Sendable {
            private let list = Mutex<[PhotoCache.EvictionResult]>([])
            func record(_ result: PhotoCache.EvictionResult) { list.withLock { $0.append(result) } }
            var all: [PhotoCache.EvictionResult] { list.withLock { $0 } }
        }

        init(photographs: Int, ceiling: Int64 = 1_000_000) async throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-copies-\(UUID().uuidString)")
            for index in 0..<photographs { folder.write("photo-\(index).png", bytes: 2048) }
            library = try TestLibrary.onDisk(at: directory)
            bytes = PhotoStore(root: directory.appending(path: "cache"))
            store = SourceStore(database: library.database, bytes: bytes)
            var cache = PhotoCache(
                database: library.database, root: directory.appending(path: "cache"),
                settings: CacheSettings(byteCeiling: ceiling), sources: store, store: bytes)
            cache.log = { _ in }
            cache.copySweep = ResizedCopies.Sweep()
            let evictions = evictions
            cache.evicted = { evictions.record($0) }
            try await cache.prepare()
            self.cache = cache
            source = try store.add(kind: .folder, locator: folder.path)
            _ = await store.refresh(source)
            try library.database.run("UPDATE photo SET storage = 'materialized';")
            _ = try await cache.fillCompletely(limit: photographs)
            photos = try library.database.all(
                "SELECT id, uuid FROM photo ORDER BY external_id;"
            ) { (id: try $0.int64("id"), uuid: try $0.string("uuid")) }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        var root: URL { bytes.root }
        var database: Database { library.database }

        func rendered(bytes count: Int = 1000, width: Int = 200, height: Int = 150)
            -> PhotoRenderer.Rendered
        {
            PhotoRenderer.Rendered(
                bytes: Data(repeating: 7, count: count), format: .heic, width: width, height: height)
        }

        @discardableResult
        func save(
            _ photo: (id: Int64, uuid: String), box: (Int, Int) = (200, 200), bytes count: Int = 1000
        ) throws -> ResizedCopies.Copy {
            try #require(
                try ResizedCopies.save(
                    rendered(bytes: count), photoID: photo.id, photoUUID: photo.uuid,
                    boxWidth: box.0, boxHeight: box.1, root: root, database: database))
        }

        func rows() throws -> Int { try database.scalarInt("SELECT COUNT(*) FROM resized;") ?? 0 }

        /// A cache over the same store with a different ceiling.
        func cache(ceiling: Int64) -> PhotoCache {
            var tight = PhotoCache(
                database: database, root: root, settings: CacheSettings(byteCeiling: ceiling),
                sources: store, store: bytes)
            tight.log = { _ in }
            tight.copySweep = cache.copySweep
            tight.evicted = cache.evicted
            return tight
        }
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    // MARK: - The key

    /// Keyed by the box asked for. Syd, 2026-09-16: "asked for". And a
    /// photograph can have several at once: "you can store mulitple sizes per
    /// photograph".
    @Test("A copy is found by photograph, box asked for and format, and nothing else")
    func keyedByBoxAndFormat() async throws {
        let fixture = try await Fixture(photographs: 1)
        let photo = try #require(fixture.photos.first)
        try fixture.save(photo, box: (200, 200))
        try fixture.save(photo, box: (2560, 1440))

        let hit = try #require(
            try ResizedCopies.find(
                photoID: photo.id, boxWidth: 200, boxHeight: 200, format: .heic,
                root: fixture.root, database: fixture.database))
        #expect(hit.pixelWidth == 200 && hit.pixelHeight == 150)
        #expect(Self.exists(hit.url))

        #expect(
            try ResizedCopies.find(
                photoID: photo.id, boxWidth: 2560, boxHeight: 1440, format: .heic,
                root: fixture.root, database: fixture.database) != nil,
            "two sizes of one photograph are two copies")
        #expect(
            try ResizedCopies.find(
                photoID: photo.id, boxWidth: 300, boxHeight: 200, format: .heic,
                root: fixture.root, database: fixture.database) == nil)
        #expect(
            try ResizedCopies.find(
                photoID: photo.id, boxWidth: 200, boxHeight: 200, format: .jpeg,
                root: fixture.root, database: fixture.database) == nil)
        #expect(try fixture.rows() == 2)
    }

    @Test("A row whose file has gone is dropped by the lookup that finds it, and is a miss")
    func vanishedFileDropsItsRow() async throws {
        let fixture = try await Fixture(photographs: 1)
        let photo = try #require(fixture.photos.first)
        let copy = try fixture.save(photo)
        try FileManager.default.removeItem(at: copy.url)

        #expect(
            try ResizedCopies.find(
                photoID: photo.id, boxWidth: 200, boxHeight: 200, format: .heic,
                root: fixture.root, database: fixture.database) == nil)
        #expect(try fixture.rows() == 0)
    }

    /// The launch walk indexes originals by source and deletes what it does not
    /// recognise; the resize folder is not a source and must survive it.
    @Test("Rebuilding the cache index at launch leaves resized copies alone")
    func launchIndexLeavesCopies() async throws {
        let fixture = try await Fixture(photographs: 1)
        let copy = try fixture.save(try #require(fixture.photos.first))

        try await fixture.cache.prepare()

        #expect(Self.exists(copy.url))
    }

    // MARK: - Eviction

    /// **Oldest file first, original or copy, by when the file was made.** Syd,
    /// 2026-09-16: "oldest file first, whether or not is an original", and
    /// "when the file was made". So an original shown a moment ago still goes
    /// first when it was fetched first, and a copy goes before a newer original.
    @Test("Eviction takes the oldest file first by when it was made, original or copy")
    func oldestFileFirst() async throws {
        let fixture = try await Fixture(photographs: 3)
        let old = fixture.photos[0]
        let middle = fixture.photos[1]
        let newest = fixture.photos[2]
        let copy = try fixture.save(newest, bytes: 1000)

        // `old` was fetched first and shown a moment ago; the copy was made
        // next; then `middle` was fetched, then `newest`.
        func made(_ photo: (id: Int64, uuid: String), at offset: Int, shown: Int? = nil) throws {
            try fixture.database.run(
                "UPDATE photo SET cached_at = added_at + :at, last_shown_at = :shown WHERE id = :id;",
                [
                    "at": .int(Int64(offset)), "id": .int(photo.id),
                    "shown": shown.map { .int(Int64($0) + 1_800_000_000) } ?? .null,
                ])
        }
        try made(old, at: 1000, shown: 9000)
        try made(middle, at: 3000)
        try made(newest, at: 4000)
        try fixture.database.run(
            "UPDATE resized SET created_at = (SELECT added_at FROM photo WHERE id = :id) + 2000;",
            ["id": .int(newest.id)])

        // 3 × 2,048 + 1,000 held; under 5,000 needs two to go: the old original
        // and then the copy, not the middle original, which was made after it.
        let result = try await fixture.cache(ceiling: 5000).evictIfNeeded()

        #expect(result.evicted == 2)
        #expect(await fixture.bytes.url(forPhoto: old.uuid) == nil, "the oldest file, though just shown")
        #expect(!Self.exists(copy.url), "the copy, made before the middle original")
        #expect(try fixture.rows() == 0, "the evicted copy's row went with its file")
        #expect(await fixture.bytes.url(forPhoto: middle.uuid) != nil)
        #expect(await fixture.bytes.url(forPhoto: newest.uuid) != nil)
    }

    /// One limit for both. Syd, 2026-09-16: "no, combined limit."
    @Test("Copies count against the same ceiling as originals")
    func copiesShareTheCeiling() async throws {
        let fixture = try await Fixture(photographs: 1)
        let photo = try #require(fixture.photos.first)
        try fixture.save(photo, bytes: 1000)

        // The original alone fits under 2,500; with the copy it does not.
        await #expect(try fixture.cache.bytesOnDisk() == 3048)
        let result = try await fixture.cache(ceiling: 2500).evictIfNeeded()
        #expect(result.evicted == 1)
        #expect(try fixture.rows() == 0, "the copy was the only thing that could go")
        #expect(await fixture.bytes.url(forPhoto: photo.uuid) != nil, "the last original is kept")
    }

    /// Syd, 2026-09-16: "clear out unaccounted for files when eviction happens",
    /// and "first eviction after launch".
    @Test("A file with no row is cleared at the first eviction after launch, and not before or after")
    func unclaimedFilesAtFirstEviction() async throws {
        let fixture = try await Fixture(photographs: 2)
        let folder = ResizedCopies.directory(in: fixture.root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stray = folder.appending(path: "stray_1x1_1x1.heic")
        try Data([1]).write(to: stray)

        // Under the ceiling: no eviction, no sweep.
        await #expect(try fixture.cache.evictIfNeeded().evicted == 0)
        #expect(Self.exists(stray))

        // The first eviction clears it.
        _ = try await fixture.cache(ceiling: 3000).evictIfNeeded()
        #expect(!Self.exists(stray))

        // A second stray, and a second eviction in the same launch, leaves it.
        let second = folder.appending(path: "second_1x1_1x1.heic")
        try Data([1]).write(to: second)
        try fixture.save(fixture.photos[1], bytes: 5000)
        _ = try await fixture.cache(ceiling: 3000).evictIfNeeded()
        #expect(Self.exists(second))
    }

    // MARK: - Evicting after every write

    /// Syd, 2026-09-16: "So, after you write any file to the cache, run
    /// evict()." And of the gap between the write and the eviction: "you might
    /// temporarily exceed the space, but that's fine".
    @Test("A fetch that takes the cache over its ceiling evicts, with nothing else asking")
    func aFetchOverTheCeilingEvicts() async throws {
        // Three originals of 2,048 bytes against 5,000: the third fetch goes over.
        let fixture = try await Fixture(photographs: 3, ceiling: 5000)

        #expect(!fixture.evictions.all.isEmpty, "nothing evicted after the fetch that went over")
        #expect(fixture.evictions.all.allSatisfy { $0.evicted > 0 }, "reported an eviction that took nothing")
        await #expect(try fixture.cache.bytesOnDisk() <= 5000)
    }

    @Test("Keeping a copy that takes the cache over its ceiling evicts")
    func keepingACopyOverTheCeilingEvicts() async throws {
        let fixture = try await Fixture(photographs: 2)
        let photo = fixture.photos[1]

        // 2 × 2,048 held, and a 1,000-byte copy takes it to 5,096.
        let copy = try await fixture.cache(ceiling: 5000).keep(
            fixture.rendered(bytes: 1000), photoID: photo.id, photoUUID: photo.uuid,
            boxWidth: 200, boxHeight: 200)

        #expect(copy != nil)
        #expect(fixture.evictions.all.map(\.evicted) == [1])
        await #expect(try fixture.cache.bytesOnDisk() <= 5000)
    }

    @Test("Keeping a copy that fits evicts nothing")
    func keepingACopyThatFits() async throws {
        let fixture = try await Fixture(photographs: 2)
        let photo = fixture.photos[1]

        let copy = try await #require(
            try fixture.cache.keep(
                fixture.rendered(bytes: 1000), photoID: photo.id, photoUUID: photo.uuid,
                boxWidth: 200, boxHeight: 200))

        #expect(fixture.evictions.all.isEmpty)
        #expect(Self.exists(copy.url))
        await #expect(try fixture.cache.bytesOnDisk() == 2 * 2048 + 1000)
    }

    /// Fetches run several at a time and copies are kept on the resizer's
    /// thread, so two writes can finish together. Two evictions side by side
    /// would each count what the other is already taking, and take it twice.
    @Test("An eviction is not started while another is running")
    func oneEvictionAtATime() async throws {
        let fixture = try await Fixture(photographs: 2)
        let tight = fixture.cache(ceiling: 3000)

        #expect(await fixture.bytes.claimEviction())
        await #expect(try tight.evictIfNeeded().evicted == 0, "evicted beside the one running")
        await fixture.bytes.endEviction()
        await #expect(try tight.evictIfNeeded().evicted == 1)
    }

    // MARK: - Serving

    /// **A copy is a picture, whatever became of its original.** Syd,
    /// 2026-09-16: "You can serve the copy if the original has been evicted."
    /// Serving used to decide a card was ready by its original alone, so a
    /// card whose original had gone waited for a fetch and was dropped, however
    /// many copies of it the cache held.
    @Test("A card whose original was evicted is served from its copy, without waiting or being dropped")
    func copyServesAnEvictedOriginal() async throws {
        let fixture = try await Fixture(photographs: 1)
        let photo = try #require(fixture.photos.first)
        let copy = try fixture.save(photo, box: (200, 200))
        await #expect(try fixture.cache.deal() || (try fixture.cache.queue.size()) > 0)

        // The original is evicted: its bytes go, and so does its residency.
        await fixture.bytes.remove(photoUUID: photo.uuid)
        try fixture.cache.releaseResidency(ofPhotos: [photo.uuid])

        var cache = fixture.cache
        cache.serveWait = .seconds(5)
        let heard = ServeWalkTests.Heard()
        cache.log = heard.log
        let clock = ContinuousClock()
        let started = clock.now
        let served = try #require(
            try await cache.serve(fitting: .init(width: 200, height: 200, format: .heic)))
        let took = clock.now - started

        #expect(served.card.id == photo.id)
        #expect(served.copy?.url == copy.url)
        #expect(took < .seconds(1), "took \(took): it waited for an original it did not need")
        #expect(!heard.all.contains { if case .waiting = $0 { true } else { false } })

        // Asked for with no box, the same card has nothing to serve.
        await #expect(try fixture.cache.deal())
        cache.serveWait = .zero
        #expect(try await cache.serve() == nil)
    }

    // MARK: - Deletion

    /// Syd, 2026-09-16: "delete them straight away".
    @Test("A photograph found absent takes its copies' files and rows with it")
    func absentPhotographTakesItsCopies() async throws {
        let fixture = try await Fixture(photographs: 1)
        let photo = try #require(fixture.photos.first)
        let small = try fixture.save(photo, box: (200, 200))
        let large = try fixture.save(photo, box: (2560, 1440))

        try await fixture.cache.remove(photo.id)

        #expect(!Self.exists(small.url))
        #expect(!Self.exists(large.url))
        #expect(try fixture.rows() == 0)
    }

    @Test("A photograph a refresh no longer finds takes its copies with it")
    func refreshRemovalTakesCopies() async throws {
        let fixture = try await Fixture(photographs: 2)
        let copy = try fixture.save(fixture.photos[0])

        fixture.folder.remove("photo-0.png")
        _ = await fixture.store.refresh(fixture.source)

        #expect(!Self.exists(copy.url))
        #expect(try fixture.rows() == 0)
    }

    @Test("A removed source takes its photographs' copies with it")
    func removedSourceTakesCopies() async throws {
        let fixture = try await Fixture(photographs: 2)
        let copy = try fixture.save(fixture.photos[1])

        try await fixture.store.remove(id: fixture.source.id)

        #expect(!Self.exists(copy.url))
        #expect(try fixture.rows() == 0)
    }

    /// Syd, 2026-09-16: "but only if they are actually deleted. if the source
    /// is offline, don't".
    @Test("A source gone offline keeps its copies")
    func offlineSourceKeepsCopies() async throws {
        let fixture = try await Fixture(photographs: 1)
        let copy = try fixture.save(try #require(fixture.photos.first))

        try fixture.store.markUnavailable(sourceID: fixture.source.id, reason: "unplugged")

        #expect(Self.exists(copy.url))
        #expect(try fixture.rows() == 1)
    }

    /// Clearing asks for the cache's bytes back, and copies are the cache's bytes.
    @Test("Clearing the cache clears its copies too")
    func clearingTakesCopies() async throws {
        let fixture = try await Fixture(photographs: 1)
        let copy = try fixture.save(try #require(fixture.photos.first), bytes: 1000)

        let result = try await fixture.cache.clear(.source(fixture.source.id))

        #expect(!Self.exists(copy.url))
        #expect(try fixture.rows() == 0)
        #expect(result.bytesFreed >= 3048)
    }
}
