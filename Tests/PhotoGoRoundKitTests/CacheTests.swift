import Foundation
import Testing

@testable import PhotoGoRoundKit

@Suite("Cache")
struct CacheTests {

    /// A library whose photos live on a *removable* volume as far as the
    /// database is concerned, so they are materialized rather than referenced.
    ///
    /// Everything in a temporary directory is really on the boot volume, so the
    /// storage column is set directly — the classification itself is covered in
    /// the source tests.
    private struct Fixture {
        let folder: TemporaryFolder
        let cacheRoot: TemporaryFolder
        let library: TestLibrary
        let store: SourceStore
        let cache: PhotoCache
        let source: Source

        init(photos: [String], settings: CacheSettings = .default) async throws {
            folder = TemporaryFolder(name: "pgr-cache-src")
            cacheRoot = TemporaryFolder(name: "pgr-cache-dst")
            for name in photos { folder.write(name, bytes: 100) }

            library = try TestLibrary()
            store = SourceStore(database: library.database)
            cache = PhotoCache(
                database: library.database,
                root: cacheRoot.url.appending(path: "cache"),
                settings: settings,
                sources: store
            )
            try cache.prepare()

            source = try store.add(kind: .folder, locator: folder.path, recursive: true)
            try await store.scan(source)
            // Force the materialized path, which is what the cap governs.
            try library.database.run("UPDATE photo SET storage = 'materialized';")
        }

        var deck: Deck { library.deck }
    }

    // MARK: - Layout

    @Test("Cache paths are source id over photo id, so a source is one directory")
    func cacheLayoutIsSourceThenPhoto() {
        let path = PhotoCache.relativePath(sourceID: 3, photoID: 124, externalID: "holiday/beach.HEIC")
        #expect(path == "3/000000124.heic")
        // No extension is not an error; nobody reads the cache by name.
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

    // MARK: - Filling

    @Test("A chunk materializes bytes and records where they went")
    func fillingCopiesBytes() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png"])
        let outcome = try await fixture.cache.fillNextChunk()

        #expect(outcome == .materialized(count: 3, bytes: 300))
        let status = try fixture.cache.status()
        #expect(status.residentCount == 3)
        #expect(status.pendingCount == 0)
        #expect(status.bytesOnDisk == 300)

        // And the bytes are really there, under the layout.
        let paths = try fixture.library.database.all(
            "SELECT cache_path FROM photo ORDER BY id;") { try $0.string("cache_path") }
        for path in paths {
            let url = fixture.cache.root.appending(path: path)
            #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        }
    }

    @Test("Filling stops at the cap")
    func fillingRespectsTheCap() async throws {
        let fixture = try await Fixture(
            photos: (0..<20).map { "photo-\($0).png" },
            settings: CacheSettings(photoCap: 6, chunkSize: 4, burstSize: 4)
        )
        _ = try await fixture.cache.fill()

        let status = try fixture.cache.status()
        #expect(status.residentCount == 6)
        #expect(status.pendingCount == 14)
        #expect(try await fixture.cache.fillNextChunk() == .capReached)
    }

    @Test("The first chunk is the burst, the rest are chunk-sized")
    func burstComesFirst() async throws {
        let fixture = try await Fixture(
            photos: (0..<20).map { "photo-\($0).png" },
            settings: CacheSettings(photoCap: 100, chunkSize: 3, burstSize: 8)
        )
        // Ten photos would be usable within seconds of adding a source; the
        // rest fill in behind them.
        let first = try await fixture.cache.fillNextChunk(size: fixture.cache.settings.burstSize)
        #expect(first == .materialized(count: 8, bytes: 800))
        let second = try await fixture.cache.fillNextChunk()
        #expect(second == .materialized(count: 3, bytes: 300))
    }

    @Test("Nothing left to do is a normal outcome")
    func fillingAnEmptyQueueIsFine() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        _ = try await fixture.cache.fill()
        #expect(try await fixture.cache.fillNextChunk() == .nothingToDo)
    }

    @Test("Cards in outstanding hands are materialized first")
    func outstandingHandsLeadTheQueue() async throws {
        let fixture = try await Fixture(
            photos: (0..<30).map { "photo-\($0).png" },
            settings: CacheSettings(photoCap: 100, chunkSize: 5, burstSize: 5)
        )
        let consumer = try fixture.deck.register(kind: .screensaver, handSize: 5)
        let hand = try fixture.deck.reserveHand(for: consumer.id).cards.map(\.card.id)

        // The prefetcher does not have to guess what is needed soon — reserved
        // hands are the answer, explicitly.
        let queue = try fixture.cache.materializationQueue(limit: 5)
        #expect(queue.map(\.photoID) == hand)

        _ = try await fixture.cache.fillNextChunk()
        for card in hand {
            #expect(try fixture.cache.residentURL(forPhoto: card) != nil)
        }
    }

    @Test("Photos from an unavailable source are never re-fetched")
    func orphansAreSkipped() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try fixture.store.markUnavailable(sourceID: fixture.source.id, reason: "drive unplugged")

        #expect(try fixture.cache.materializationQueue(limit: 10).isEmpty)
        #expect(try await fixture.cache.fillNextChunk() == .nothingToDo)
    }

    @Test("A photo that has gone missing is marked, not retried for ever")
    func missingFilesAreMarkedUnavailable() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        fixture.folder.remove("a.png")

        let outcome = try await fixture.cache.fillNextChunk()
        #expect(outcome == .materialized(count: 1, bytes: 100))
        #expect(try fixture.deck.poolSize() == 1)
        #expect(try fixture.cache.materializationQueue(limit: 10).isEmpty)
    }

    @Test("Filling pauses rather than filling the volume")
    func lowDiskPausesMaterialization() async throws {
        // A floor larger than any real volume, so the guard always trips.
        let fixture = try await Fixture(
            photos: ["a.png", "b.png"],
            settings: CacheSettings(minimumFreeBytes: .max, criticalFreeBytes: .max)
        )
        let outcome = try await fixture.cache.fillNextChunk()
        guard case .pausedForDiskSpace = outcome else {
            Issue.record("expected a disk-space pause, got \(outcome)")
            return
        }
        #expect(try fixture.cache.status().residentCount == 0)
    }

    // MARK: - Eviction

    @Test("Eviction is FIFO by materialization time")
    func evictionIsFIFO() async throws {
        let fixture = try await Fixture(
            photos: (0..<10).map { "photo-\($0).png" },
            settings: CacheSettings(photoCap: 10, chunkSize: 10, burstSize: 10)
        )
        _ = try await fixture.cache.fill()

        // Stamp distinct materialization times so "oldest" is unambiguous.
        let ids = try fixture.library.database.all("SELECT id FROM photo ORDER BY id;") {
            try $0.int64("id")
        }
        for (index, id) in ids.enumerated() {
            try fixture.library.database.run(
                "UPDATE photo SET materialized_at = :at WHERE id = :id;",
                ["at": .int(Int64(1000 + index)), "id": .int(id)]
            )
        }

        let tighter = PhotoCache(
            database: fixture.library.database,
            root: fixture.cache.root,
            settings: CacheSettings(photoCap: 4),
            sources: fixture.store
        )
        let result = try tighter.evictIfNeeded()
        #expect(result.evicted == 6)
        #expect(result.bytesFreed == 600)

        // The six oldest went; the four newest stayed.
        let remaining = try fixture.library.database.all(
            "SELECT id FROM photo WHERE cache_path IS NOT NULL ORDER BY id;") { try $0.int64("id") }
        #expect(remaining == Array(ids.suffix(4)))
    }

    @Test("A card in an outstanding hand is never evicted, however old")
    func outstandingCardsAreProtected() async throws {
        let fixture = try await Fixture(
            photos: (0..<10).map { "photo-\($0).png" },
            settings: CacheSettings(photoCap: 10, chunkSize: 10, burstSize: 10)
        )
        _ = try await fixture.cache.fill()

        let ids = try fixture.library.database.all("SELECT id FROM photo ORDER BY id;") {
            try $0.int64("id")
        }
        // Make the very oldest entries the ones somebody is about to show.
        for (index, id) in ids.enumerated() {
            try fixture.library.database.run(
                "UPDATE photo SET materialized_at = :at WHERE id = :id;",
                ["at": .int(Int64(1000 + index)), "id": .int(id)]
            )
        }
        let consumer = try fixture.deck.register(kind: .screensaver, handSize: 2)
        try fixture.library.database.run(
            """
            INSERT INTO hand (consumer_id, photo_id, position, reserved_at)
            VALUES (:c, :a, 0, 0), (:c, :b, 1, 0);
            """,
            ["c": .int(consumer.id), "a": .int(ids[0]), "b": .int(ids[1])]
        )

        let tighter = PhotoCache(
            database: fixture.library.database,
            root: fixture.cache.root,
            settings: CacheSettings(photoCap: 3),
            sources: fixture.store
        )
        let result = try tighter.evictIfNeeded()
        #expect(result.protectedFromEviction == 2)

        // Without this guard a fast consumer could evict a photo moments before
        // requesting it.
        #expect(try fixture.cache.residentURL(forPhoto: ids[0]) != nil)
        #expect(try fixture.cache.residentURL(forPhoto: ids[1]) != nil)
    }

    @Test("The byte ceiling evicts early even when the count is fine")
    func byteCeilingIsASafetyValve() async throws {
        let fixture = try await Fixture(
            photos: (0..<10).map { "photo-\($0).png" },
            settings: CacheSettings(photoCap: 100, chunkSize: 10, burstSize: 10)
        )
        _ = try await fixture.cache.fill()
        #expect(try fixture.cache.status().bytesOnDisk == 1000)

        // Count is nowhere near the cap; bytes are over the ceiling.
        let capped = PhotoCache(
            database: fixture.library.database,
            root: fixture.cache.root,
            settings: CacheSettings(photoCap: 100, byteCeiling: 450),
            sources: fixture.store
        )
        let result = try capped.evictIfNeeded()
        #expect(result.evicted > 0)
        #expect(try capped.status().bytesOnDisk <= 450)
    }

    @Test("Under the cap, eviction does nothing")
    func evictionIsQuietWhenUnderCap() async throws {
        let fixture = try await Fixture(
            photos: ["a.png", "b.png"],
            settings: CacheSettings(photoCap: 100)
        )
        _ = try await fixture.cache.fill()
        #expect(try fixture.cache.evictIfNeeded() == PhotoCache.EvictionResult(
            evicted: 0, bytesFreed: 0, protectedFromEviction: 0))
    }

    // MARK: - Clearing

    @Test("Clearing states its price before charging it")
    func clearingReportsItsCost() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png"])
        _ = try await fixture.cache.fill()

        let cost = try fixture.cache.costOfClearing(.everything)
        #expect(cost.needingRefetch == 3)
        #expect(cost.bytesFreed == 300)
        #expect(!cost.costsNothingToRefetch)

        // Clearing only what is gone frees space at zero future cost, which is
        // the variant to reach for first.
        #expect(try fixture.cache.costOfClearing(.unavailableSources).costsNothingToRefetch)
    }

    @Test("Clearing discards bytes and keeps shuffle history")
    func clearingKeepsDeckHistory() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png"])
        _ = try await fixture.cache.fill()
        _ = try fixture.deck.dealSequence(count: 5, settings: .default)

        let seqBefore = try fixture.deck.currentDealSeq()
        let shownBefore = try fixture.library.database.scalarInt("SELECT SUM(times_shown) FROM photo;")

        let result = try fixture.cache.clear(.everything)
        #expect(result.cleared == 3)
        #expect(result.bytesFreed == 300)
        #expect(try fixture.cache.status().residentCount == 0)

        // Epochs, shuffle keys, and last-shown times are untouched, so a
        // cleared cache refills into the same rotation.
        #expect(try fixture.deck.currentDealSeq() == seqBefore)
        #expect(try fixture.library.database.scalarInt("SELECT SUM(times_shown) FROM photo;") == shownBefore)
        #expect(try fixture.deck.poolSize() == 3)
    }

    @Test("Clearing everything returns outstanding hands")
    func clearingReturnsHands() async throws {
        let fixture = try await Fixture(photos: (0..<6).map { "photo-\($0).png" })
        _ = try await fixture.cache.fill()
        let consumer = try fixture.deck.register(kind: .screensaver, handSize: 4)
        try fixture.deck.reserveHand(for: consumer.id)

        let result = try fixture.cache.clear(.everything)
        #expect(result.handsReturned == 4)
        #expect(try fixture.deck.outstandingHand(for: consumer.id).isEmpty)
    }

    @Test("Clearing one source leaves the others alone")
    func clearingOneSource() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        let other = TemporaryFolder(name: "pgr-cache-other")
        other.write("x.png", bytes: 50)
        let second = try fixture.store.add(kind: .folder, locator: other.path)
        try await fixture.store.scan(second)
        try fixture.library.database.run("UPDATE photo SET storage = 'materialized';")
        _ = try await fixture.cache.fill()
        #expect(try fixture.cache.status().residentCount == 3)

        let result = try fixture.cache.clear(.source(fixture.source.id))
        #expect(result.cleared == 2)
        #expect(try fixture.cache.status().residentCount == 1)
        // One directory removal, not a thousand unlinks.
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.cache.root.appending(path: "\(fixture.source.id)")
                    .path(percentEncoded: false))
        )
    }

    @Test("Clearing unavailable sources frees exactly the orphans")
    func clearingUnavailableSources() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        let other = TemporaryFolder(name: "pgr-cache-live")
        other.write("x.png", bytes: 50)
        let live = try fixture.store.add(kind: .folder, locator: other.path)
        try await fixture.store.scan(live)
        try fixture.library.database.run("UPDATE photo SET storage = 'materialized';")
        _ = try await fixture.cache.fill()

        try fixture.store.markUnavailable(sourceID: fixture.source.id, reason: "drive unplugged")
        let result = try fixture.cache.clear(.unavailableSources)
        #expect(result.cleared == 2)
        #expect(try fixture.cache.status().residentCount == 1)
    }

    // MARK: - Referenced photos

    @Test("Referenced photos cost no cache budget and need no materialization")
    func referencedPhotosAreFree() async throws {
        let folder = TemporaryFolder(name: "pgr-ref-src")
        for name in ["a.png", "b.png"] { folder.write(name, bytes: 100) }
        let cacheRoot = TemporaryFolder(name: "pgr-ref-dst")

        let library = try TestLibrary()
        let store = SourceStore(database: library.database)
        let cache = PhotoCache(
            database: library.database,
            root: cacheRoot.url.appending(path: "cache"),
            sources: store
        )
        try cache.prepare()
        let source = try store.add(kind: .folder, locator: folder.path)
        try await store.scan(source)

        // A temporary directory is on the boot volume, so these classify as
        // referenced without any help.
        let status = try cache.status()
        #expect(status.referencedCount == 2)
        #expect(status.residentCount == 0)
        #expect(status.pendingCount == 0)
        #expect(try cache.materializationQueue(limit: 10).isEmpty)
        #expect(try await cache.fillNextChunk() == .nothingToDo)

        // But their bytes are readable, resolved through the access seam.
        let ids = try library.database.all("SELECT id FROM photo;") { try $0.int64("id") }
        for id in ids {
            #expect(try cache.residentURL(forPhoto: id) != nil)
        }

        // And eviction is a no-op for them.
        #expect(try cache.evictIfNeeded().evicted == 0)
    }

    @Test("A referenced photo the user deletes stops being readable at once")
    func deletedReferencedPhotoIsGone() async throws {
        let folder = TemporaryFolder(name: "pgr-ref-del")
        folder.write("a.png", bytes: 100)
        folder.write("b.png", bytes: 100)
        let cacheRoot = TemporaryFolder(name: "pgr-ref-del-dst")

        let library = try TestLibrary()
        let store = SourceStore(database: library.database)
        let cache = PhotoCache(
            database: library.database,
            root: cacheRoot.url.appending(path: "cache"),
            sources: store
        )
        let source = try store.add(kind: .folder, locator: folder.path)
        try await store.scan(source)

        let target = try #require(
            try library.database.first(
                "SELECT id FROM photo WHERE external_id = 'a.png';") { try $0.int64("id") }
        )
        #expect(try cache.residentURL(forPhoto: target) != nil)

        // Referenced photos *are* their bytes: deleting one removes it, rather
        // than starting a countdown.
        folder.remove("a.png")
        #expect(try cache.residentURL(forPhoto: target) == nil)
    }
}
