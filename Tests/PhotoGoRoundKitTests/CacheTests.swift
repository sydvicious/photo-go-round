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
            // Two steps now: deal the cards, then fetch the bytes for what was
            // dealt. Dealing alone leaves a queue of cards with nothing behind
            // them, which is a state the agent has but a test asserting on
            // *cached* pictures does not want.
            try await cache.fillCompletely(limit: limit)
        }
    }

    // MARK: - Layout

    @Test("Cache paths are source, then size, then the photograph's own identity")
    func cacheLayoutIsSourceThenSize() {
        let store = PhotoStore(root: URL(filePath: "/cache"))
        let original = store.url(
            for: PhotoStore.Key(photoUUID: "abc"), sourceUUID: "src", pathExtension: "HEIC")
        #expect(original.path(percentEncoded: false) == "/cache/src/.original/abc.heic")

        let rendered = store.url(
            for: PhotoStore.Key(photoUUID: "abc", size: .init(width: 3840, height: 2160)),
            sourceUUID: "src", pathExtension: "heic")
        #expect(rendered.path(percentEncoded: false) == "/cache/src/3840x2160/abc.heic")

        // A file with no extension keeps none, rather than gaining a stray dot.
        let bare = store.url(
            for: PhotoStore.Key(photoUUID: "abc"), sourceUUID: "src", pathExtension: "")
        #expect(bare.path(percentEncoded: false) == "/cache/src/.original/abc")
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

    // MARK: - Dealing, which costs nothing

    @Test("Dealing queues a card and fetches nothing")
    func dealingDoesNotFetch() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png"])

        #expect(try fixture.cache.deal())

        // The queue holds cards, not bytes. Nothing was downloaded, and that is
        // the inversion: whether this picture can be shown is found out by
        // trying to show it.
        #expect(try fixture.cache.queue.size() == 1)
        #expect(try fixture.cache.status().residentCount == 0)
    }

    @Test("Each deal yields a different picture, and running out is an ordinary answer")
    func dealingDoesNotRepeat() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png"])

        var dealt = 0
        while try fixture.cache.deal() { dealt += 1 }
        #expect(dealt == 3)
        #expect(try fixture.cache.queue.size() == 3)
        #expect(Set(try fixture.cache.queue.peek(10).map(\.id)).count == 3)

        // Everything it has is queued, so there is nothing left to deal.
        #expect(try fixture.cache.deal() == false)
    }

    @Test("Caching is what stops rather than filling the volume; dealing is unaffected")
    func lowDiskStopsCachingNotDealing() async throws {
        let fixture = try await Fixture(
            photos: ["a.png", "b.png"],
            settings: CacheSettings(minimumFreeBytes: .max, criticalFreeBytes: .max)
        )

        // Dealing writes a row and costs no space, so the floor has nothing to
        // say about it. Fetching bytes is where the volume can fill up.
        #expect(try fixture.cache.deal())
        let queued = try #require(try fixture.cache.queue.peek().first)
        #expect(try await fixture.cache.cache(photoID: queued.id) == false)
        #expect(try fixture.cache.status().residentCount == 0)
    }

    @Test("A disabled source is not dealt from")
    func disabledSourcesAreNotDealt() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try fixture.store.setEnabled(false, for: fixture.source.id)
        #expect(try fixture.cache.deal() == false)
    }

    @Test("A file that vanished before its download leaves the pool")
    func failedDownloadFromAnOnlineSourceRemovesTheEntry() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        fixture.folder.remove("a.png")

        // Two attempts: one hits the missing file and removes it, the other
        // succeeds. The source is right there, so a missing file is a file that
        // no longer exists.
        _ = try await fixture.cache.fillCompletely() > 0
        _ = try await fixture.cache.fillCompletely() > 0

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
        #expect(try fixture.cache.indexCache().discarded == 0)
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

    /// Entries are written in deck order, so oldest-written is longest-since-
    /// dealt. The test ages them by hand because a produce loop finishes in
    /// microseconds and every file would otherwise share a timestamp.
    private func age(_ fixture: Fixture, oldestFirst uuids: [String]) throws {
        for (index, uuid) in uuids.enumerated() {
            guard let url = fixture.cache.store.url(for: PhotoStore.Key(photoUUID: uuid))
            else { continue }
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))],
                ofItemAtPath: url.path(percentEncoded: false))
        }
        try fixture.cache.indexCache()
    }

    private func uuidsByID(_ fixture: Fixture) throws -> [String] {
        try fixture.library.database.all("SELECT uuid FROM photo ORDER BY id;") {
            try $0.string("uuid")
        }
    }

    @Test("Eviction is FIFO by the order entries were written")
    func evictionIsFIFO() async throws {
        let fixture = try await Fixture(
            photos: (0..<10).map { "photo-\($0).png" },
            settings: CacheSettings(byteCeiling: 10_000)
        )
        try await fixture.produceAll()

        let uuids = try uuidsByID(fixture)
        // Nothing queued, so nothing is protected.
        try fixture.library.database.run("DELETE FROM queue;")
        try age(fixture, oldestFirst: uuids)

        fixture.cache.store.byteCeiling = 400
        let result = fixture.cache.store.evictIfNeeded()
        #expect(result.evicted == 6)

        // The four newest survive; the six oldest are the ones the deck is
        // furthest from reaching again.
        let held = uuids.filter {
            fixture.cache.store.url(for: PhotoStore.Key(photoUUID: $0)) != nil
        }
        #expect(held == Array(uuids.suffix(4)))
    }

    @Test("A queued picture is never evicted, however old")
    func queuedPicturesAreProtected() async throws {
        let fixture = try await Fixture(
            photos: (0..<10).map { "photo-\($0).png" },
            settings: CacheSettings(byteCeiling: 10_000)
        )
        try await fixture.produceAll()

        try age(fixture, oldestFirst: try uuidsByID(fixture))

        // Everything is queued, so nothing may be evicted — these are about to
        // be shown.
        let tighter = PhotoCache(
            database: fixture.library.database, root: fixture.cache.root,
            settings: CacheSettings(byteCeiling: 300), sources: fixture.store,
            store: fixture.cache.store
        )
        let result = try tighter.evictIfNeeded()
        #expect(result.evicted == 0)
        #expect(result.protectedFromEviction > 0)
    }

    @Test("The byte ceiling evicts early even when the count is fine")
    func byteCeilingIsASafetyValve() async throws {
        let fixture = try await Fixture(
            photos: (0..<10).map { "photo-\($0).png" },
            settings: CacheSettings(byteCeiling: 10_000)
        )
        try await fixture.produceAll()
        try fixture.library.database.run("DELETE FROM queue;")
        #expect(try fixture.cache.status().bytesOnDisk == 1000)

        let capped = PhotoCache(
            database: fixture.library.database, root: fixture.cache.root,
            settings: CacheSettings(byteCeiling: 450), sources: fixture.store,
            store: fixture.cache.store
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
        let uuid = try #require(
            try fixture.library.database.first(
                "SELECT uuid FROM photo WHERE id = :id;", ["id": .int(doomed)]
            ) { try $0.string("uuid") }
        )
        let held = try #require(fixture.cache.store.url(for: PhotoStore.Key(photoUUID: uuid)))

        #expect(try fixture.cache.remove(doomed).count == 1)
        #expect(!FileManager.default.fileExists(atPath: held.path(percentEncoded: false)))
        // And it left the queue by cascade.
        #expect(try fixture.cache.queue.size() == 1)
        #expect(try fixture.cache.indexCache().discarded == 0)
    }

    @Test("A file nothing claims is deleted when the index is rebuilt")
    func unclaimedBytesAreDiscarded() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try await fixture.produceAll()

        // A file whose UUID is in no row: what a crash mid-write leaves, and
        // what a rebuilt database leaves behind of its predecessor.
        let stray = fixture.cache.root
            .appending(path: fixture.source.uuid)
            .appending(path: PhotoStore.originalDirectory)
            .appending(path: "\(UUID().uuidString).png")
        try Data(count: 250).write(to: stray)

        let result = try fixture.cache.indexCache()
        #expect(result.discarded == 1)
        #expect(!FileManager.default.fileExists(atPath: stray.path(percentEncoded: false)))
        #expect(try fixture.cache.status().residentCount == 2)
    }

    @Test("Bytes that vanished are noticed at the next rebuild, not served")
    func missingBytesAreForgotten() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try await fixture.produceAll()

        let uuid = try #require(
            try fixture.library.database.first("SELECT uuid FROM photo ORDER BY id LIMIT 1;") {
                try $0.string("uuid")
            }
        )
        let held = try #require(fixture.cache.store.url(for: PhotoStore.Key(photoUUID: uuid)))
        try FileManager.default.removeItem(at: held)

        // The index is built *from* the disk, so it cannot claim what is not
        // there. The queue keeps both cards: one whose bytes went missing is a
        // card to fetch again, not a card to throw away.
        try fixture.cache.indexCache()
        #expect(try fixture.cache.status().residentCount == 1)
        #expect(try fixture.cache.queue.size() == 2)
    }

    @Test("A card dealt before its bytes exist survives a restart")
    func dealtCardsSurviveARestart() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])

        // Dealt and nothing more: no bytes were fetched, which is the ordinary
        // state of a materialized card. Reaching the head uncached is *how* a
        // photograph's bytes come to be asked for.
        while try fixture.cache.deal() {}
        let dealt = try fixture.cache.queue.size()
        #expect(dealt == 2)
        #expect(try fixture.cache.status().residentCount == 0)

        // A restart rebuilds the byte index from the disk, and must leave the
        // queue alone. Dropping every card whose bytes are absent discards
        // precisely the materialized ones, so a source reachable only through
        // the cache queue never gets a turn — it is emptied out of the deck at
        // every launch and refilled with the referenced cards that never needed
        // bytes in the first place.
        try fixture.cache.indexCache()
        #expect(try fixture.cache.queue.size() == dealt)
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
