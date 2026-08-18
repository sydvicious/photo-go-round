import Foundation
import Testing

@testable import PhotoGoRoundKit

@Suite("Cache")
struct CacheTests {

    /// A library whose photos are treated as materialized, so the cache cap
    /// governs them. Everything in a temporary directory is really on the boot
    /// volume, so the storage column is set directly — classification itself is
    /// covered in the source tests.
    private struct Fixture {
        let folder: TemporaryFolder
        let cacheRoot: TemporaryFolder
        let library: TestLibrary
        let store: SourceStore
        let cache: PhotoCache
        let source: Source

        init(
            photos: [String],
            settings: CacheSettings = .default,
            queueSize: Int = 1000,
            materialized: Bool = true
        ) async throws {
            folder = TemporaryFolder(name: "pgr-cache-src")
            cacheRoot = TemporaryFolder(name: "pgr-cache-dst")
            for name in photos { folder.write(name, bytes: 100) }

            library = try TestLibrary()
            store = SourceStore(database: library.database)
            cache = PhotoCache(
                database: library.database,
                root: cacheRoot.url.appending(path: "cache"),
                settings: settings,
                sources: store,
                queueSize: queueSize
            )
            try cache.prepare()

            source = try store.add(kind: .folder, locator: folder.path, recursive: true)
            await store.refresh(source)
            if materialized {
                try library.database.run("UPDATE photo SET storage = 'materialized';")
            }
        }

        var deck: Deck { library.deck }

        /// Asks the source for pictures until it stops offering them.
        @discardableResult
        func produceAll(limit: Int = 200) async throws -> Int {
            var made = 0
            for _ in 0..<limit {
                guard try await cache.produce(forSource: source.id) else { break }
                made += 1
            }
            return made
        }
    }

    // MARK: - Layout

    @Test("Cache paths are source id over photo id, so a source is one directory")
    func cacheLayoutIsSourceThenPhoto() {
        let path = PhotoCache.relativePath(sourceID: 3, photoID: 124, externalID: "holiday/beach.HEIC")
        #expect(path == "3/000000124.heic")
        #expect(PhotoCache.relativePath(sourceID: 7, photoID: 1, externalID: "noext") == "7/000000001")
    }

    @Test("The cache directory is kept out of backups")
    func cacheIsExcludedFromBackup() throws {
        let root = TemporaryFolder(name: "pgr-cache-backup")
        let library = try TestLibrary()
        let cache = PhotoCache(
            database: library.database,
            root: root.url.appending(path: "cache"),
            sources: SourceStore(database: library.database)
        )
        try cache.prepare()
        let values = try cache.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    // MARK: - Producing

    @Test("Producing fetches the bytes and queues the picture, in one step")
    func producingFetchesAndQueues() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png"])
        #expect(try await fixture.cache.produce(forSource: fixture.source.id))

        // A picture is never queued unless it is ready to show: producing it and
        // fetching its bytes are the same operation.
        #expect(try fixture.cache.queue.size() == 1)
        let queued = try #require(try fixture.cache.queue.peek().first)
        #expect(try fixture.cache.residentURL(forPhoto: queued.id) != nil)
        #expect(try fixture.cache.status().residentCount == 1)
    }

    @Test("Each request yields a different picture")
    func producingDoesNotRepeat() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png"])
        #expect(try await fixture.produceAll() == 3)
        #expect(try fixture.cache.queue.size() == 3)
        #expect(Set(try fixture.cache.queue.peek(10).map(\.id)).count == 3)

        // Nothing left to offer is an ordinary answer.
        #expect(!(try await fixture.cache.produce(forSource: fixture.source.id)))
    }

    @Test("Producing stops rather than filling the volume")
    func lowDiskStopsProduction() async throws {
        let fixture = try await Fixture(
            photos: ["a.png", "b.png"],
            settings: CacheSettings(minimumFreeBytes: .max, criticalFreeBytes: .max)
        )
        #expect(!(try await fixture.cache.produce(forSource: fixture.source.id)))
        #expect(try fixture.cache.queue.size() == 0)
    }

    @Test("A source that is unavailable is not asked to produce")
    func unavailableSourcesProduceNothing() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try fixture.store.setEnabled(false, for: fixture.source.id)
        #expect(!(try await fixture.cache.produce(forSource: fixture.source.id)))
    }

    @Test("A file that vanished before its download leaves the pool")
    func failedDownloadFromAnOnlineSourceRemovesTheEntry() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        fixture.folder.remove("a.png")

        // Two attempts: one hits the missing file and removes it, the other
        // succeeds. The source is right there, so a missing file is a file that
        // no longer exists.
        _ = try await fixture.cache.produce(forSource: fixture.source.id)
        _ = try await fixture.cache.produce(forSource: fixture.source.id)

        #expect(try fixture.deck.poolSize() == 1)
        #expect(try fixture.cache.queue.size() == 1)
    }

    // MARK: - Serving

    @Test("An empty queue serves nothing, which is how a fresh install starts")
    func servingAnEmptyQueue() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        #expect(try await fixture.cache.serve() == nil)
    }

    @Test("Serving returns a picture and advances the deck")
    func servingAdvancesTheDeck() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try await fixture.produceAll()

        let served = try #require(try await fixture.cache.serve())
        #expect(served.card.dealSeq == 1)
        #expect(FileManager.default.fileExists(atPath: served.url.path(percentEncoded: false)))
        #expect(try fixture.deck.currentDealSeq() == 1)
        // Serving is what shortens the queue.
        #expect(try fixture.cache.queue.size() == 1)
        #expect(
            try fixture.library.database.scalarInt(
                "SELECT times_shown FROM photo WHERE id = :id;", ["id": .int(served.card.id)]) == 1
        )
    }

    /// The requirement the whole serving path exists for.
    @Test("A photo deleted from the source is never served, even though we hold a copy")
    func deletedPhotosAreNeverServed() async throws {
        let fixture = try await Fixture(photos: ["keep.png", "delete-me.png"])
        try await fixture.produceAll()
        #expect(try fixture.cache.queue.size() == 2)

        // We hold our own copy, so deleting the original does not touch our
        // bytes — exactly the case a residency check would sail past.
        fixture.folder.remove("delete-me.png")

        var served: [String] = []
        while let next = try await fixture.cache.serve() {
            served.append(next.card.externalID)
        }
        #expect(served == ["keep.png"])
        #expect(try fixture.deck.poolSize() == 1)
        #expect(try fixture.cache.sweepOrphans().files == 0)
    }

    @Test("Existence is three-valued, and offline is not deletion")
    func existenceDistinguishesDeletedFromUnreachable() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        let source = try #require(try fixture.store.source(id: fixture.source.id))
        let provider = FolderSourceProvider()

        #expect(await provider.existence(of: "a.png", in: source) == .present)
        #expect(await provider.existence(of: "ghost.png", in: source) == .absent)

        let unreachable = try fixture.store.add(kind: .folder, locator: "/Volumes/NotMounted/photos")
        let verdict = await provider.existence(of: "a.png", in: unreachable)
        #expect(verdict != .absent)
        if case .unknown = verdict {} else {
            Issue.record("expected .unknown for an unreachable source, got \(verdict)")
        }
    }

    @Test("Offline keeps its cached bytes, and keeps serving them")
    func offlineSourcesKeepServingFromCache() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png"])
        try await fixture.produceAll()

        // The drive is unplugged. Note what this is *not*: deleting the files
        // while leaving the folder is the deletion case.
        try fixture.library.database.run(
            "UPDATE source SET locator = :locator WHERE id = :id;",
            ["locator": "/Volumes/NotMounted/photos", "id": .int(fixture.source.id)]
        )
        try fixture.store.markUnavailable(sourceID: fixture.source.id, reason: "volume not mounted")

        // The cached copies are the most valuable thing we have now.
        #expect(try await fixture.cache.serve() != nil)
        #expect(try fixture.deck.poolSize() == 3)
        #expect(try fixture.cache.status().residentCount == 3)
    }

    // MARK: - Eviction

    @Test("Eviction is FIFO by materialization time")
    func evictionIsFIFO() async throws {
        let fixture = try await Fixture(
            photos: (0..<10).map { "photo-\($0).png" },
            settings: CacheSettings(photoCap: 10)
        )
        try await fixture.produceAll()

        let ids = try fixture.library.database.all("SELECT id FROM photo ORDER BY id;") {
            try $0.int64("id")
        }
        for (index, id) in ids.enumerated() {
            try fixture.library.database.run(
                "UPDATE photo SET materialized_at = :at WHERE id = :id;",
                ["at": .int(Int64(1000 + index)), "id": .int(id)]
            )
        }
        // Nothing queued, so nothing is protected.
        try fixture.library.database.run("DELETE FROM queue;")

        let tighter = PhotoCache(
            database: fixture.library.database, root: fixture.cache.root,
            settings: CacheSettings(photoCap: 4), sources: fixture.store
        )
        let result = try tighter.evictIfNeeded()
        #expect(result.evicted == 6)
        let remaining = try fixture.library.database.all(
            "SELECT id FROM photo WHERE cache_path IS NOT NULL ORDER BY id;") { try $0.int64("id") }
        #expect(remaining == Array(ids.suffix(4)))
    }

    @Test("A queued picture is never evicted, however old")
    func queuedPicturesAreProtected() async throws {
        let fixture = try await Fixture(
            photos: (0..<10).map { "photo-\($0).png" },
            settings: CacheSettings(photoCap: 10)
        )
        try await fixture.produceAll()

        let ids = try fixture.library.database.all("SELECT id FROM photo ORDER BY id;") {
            try $0.int64("id")
        }
        for (index, id) in ids.enumerated() {
            try fixture.library.database.run(
                "UPDATE photo SET materialized_at = :at WHERE id = :id;",
                ["at": .int(Int64(1000 + index)), "id": .int(id)]
            )
        }

        // Everything is queued, so nothing may be evicted — these are about to
        // be shown.
        let tighter = PhotoCache(
            database: fixture.library.database, root: fixture.cache.root,
            settings: CacheSettings(photoCap: 3), sources: fixture.store
        )
        let result = try tighter.evictIfNeeded()
        #expect(result.evicted == 0)
        #expect(result.protectedFromEviction > 0)
    }

    @Test("The byte ceiling evicts early even when the count is fine")
    func byteCeilingIsASafetyValve() async throws {
        let fixture = try await Fixture(
            photos: (0..<10).map { "photo-\($0).png" },
            settings: CacheSettings(photoCap: 100)
        )
        try await fixture.produceAll()
        try fixture.library.database.run("DELETE FROM queue;")
        #expect(try fixture.cache.status().bytesOnDisk == 1000)

        let capped = PhotoCache(
            database: fixture.library.database, root: fixture.cache.root,
            settings: CacheSettings(photoCap: 100, byteCeiling: 450), sources: fixture.store
        )
        #expect(try capped.evictIfNeeded().evicted > 0)
        #expect(try capped.status().bytesOnDisk <= 450)
    }

    // MARK: - Orphaned bytes

    @Test("Gone from an online source takes the cache entry with it")
    func onlineRemovalDiscardsTheCachedBytes() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try await fixture.produceAll()

        let doomed = try #require(
            try fixture.library.database.first(
                "SELECT id FROM photo WHERE external_id = 'a.png';") { try $0.int64("id") }
        )
        let path = try #require(
            try fixture.library.database.first(
                "SELECT cache_path FROM photo WHERE id = :id;", ["id": .int(doomed)]
            ) { try $0.string("cache_path") }
        )

        #expect(try fixture.cache.remove(doomed).count == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.cache.root.appending(path: path).path(percentEncoded: false))
        )
        // And it left the queue by cascade.
        #expect(try fixture.cache.queue.size() == 1)
        #expect(try fixture.cache.sweepOrphans().files == 0)
    }

    @Test("Bytes left behind by a crash are swept up")
    func orphanedBytesAreSwept() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try await fixture.produceAll()

        // A file the database does not claim: what a crash between the copy and
        // the row update leaves behind.
        let stray = fixture.cache.root.appending(path: "\(fixture.source.id)/999999999.png")
        try Data(count: 250).write(to: stray)

        let swept = try fixture.cache.sweepOrphans()
        #expect(swept.files == 1)
        #expect(swept.bytes == 250)
        #expect(try fixture.cache.status().residentCount == 2)
    }

    @Test("A cache entry that lost its bytes is queued for re-fetch")
    func residencyIsVerified() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try await fixture.produceAll()

        let path = try #require(
            try fixture.library.database.first("SELECT cache_path FROM photo ORDER BY id LIMIT 1;") {
                try $0.string("cache_path")
            }
        )
        try FileManager.default.removeItem(at: fixture.cache.root.appending(path: path))

        #expect(try fixture.cache.verifyResidency() == 1)
        #expect(try fixture.cache.status().residentCount == 1)
        // It left the queue too, so nothing serves a picture with no bytes.
        #expect(try fixture.cache.queue.size() == 1)
    }

    // MARK: - Referenced photos

    @Test("Referenced photos cost no cache budget and need no download")
    func referencedPhotosAreFree() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"], materialized: false)
        try await fixture.produceAll()

        let status = try fixture.cache.status()
        #expect(status.referencedCount == 2)
        #expect(status.residentCount == 0)
        #expect(status.bytesOnDisk == 0)
        // Queued and servable without a byte being copied: for a file we know
        // the path to, the cache entry is the pointer.
        #expect(try fixture.cache.queue.size() == 2)
        #expect(try await fixture.cache.serve() != nil)
        #expect(try fixture.cache.evictIfNeeded().evicted == 0)
    }

    // MARK: - Clearing

    @Test("Clearing discards bytes and keeps shuffle history")
    func clearingKeepsDeckHistory() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png"])
        try await fixture.produceAll()
        _ = try await fixture.cache.serve()

        let seqBefore = try fixture.deck.currentDealSeq()
        let result = try fixture.cache.clear(.everything)
        #expect(result.cleared == 3)
        #expect(try fixture.cache.status().residentCount == 0)
        #expect(try fixture.deck.currentDealSeq() == seqBefore)
        #expect(try fixture.deck.poolSize() == 3)
    }
}
