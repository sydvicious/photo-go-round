import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import PhotoGoRoundAgentAPI

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

            source = try await store.add(kind: .folder, locator: folder.path, recursive: true)
            await store.refresh(source)
            if materialized {
                try library.database.run("UPDATE photo SET storage = 'materialized';")
            }
        }

        var deck: Deck { library.deck }

        /// Deals every card the deck offers, then fetches their bytes — the
        /// order the agent works in since 2026-09-05.
        @discardableResult
        func produceAll(limit: Int = 200) async throws -> Int {
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
        #expect(try fixture.cache.status().residentCount == 0)

        #expect(try fixture.cache.deal())

        // Dealing reads a row and writes a row. The bytes are the queue's
        // business, fetched after the card is on it — see the fetch tests
        // below.
        #expect(try fixture.cache.queue.size() == 1)
        #expect(try fixture.cache.status().residentCount == 0)
    }

    // MARK: - The queue fetching its own cards

    @Test("A dealt card is fetched, and the queue is walked head first")
    func queuedCardsAreFetchedHeadFirst() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png"])
        while try fixture.cache.deal() {}
        let order = try fixture.cache.queue.peek(3).map(\.id)
        #expect(order.count == 3)

        // Each step fetches the next cold card in queue order and says so.
        let first = await fixture.cache.fetchQueuedOnce()
        guard case .fetched(let p1) = first else { Issue.record("\(first)"); return }
        let second = await fixture.cache.fetchQueuedOnce(after: p1)
        guard case .fetched(let p2) = second else { Issue.record("\(second)"); return }
        let third = await fixture.cache.fetchQueuedOnce(after: p2)
        guard case .fetched(let p3) = third else { Issue.record("\(third)"); return }
        #expect(p1 < p2 && p2 < p3)
        #expect(await fixture.cache.fetchQueuedOnce(after: p3) == .drained)

        // Three originals held, in the order the cards will be shown. The
        // cards kept their places: nothing rejoined, nothing was reordered.
        #expect(try fixture.cache.status().residentCount == 3)
        #expect(try fixture.cache.queue.peek(3).map(\.id) == order)
    }

    @Test("A card that is already held is not fetched again, and is walked past")
    func heldCardsAreWalkedPast() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try await fixture.produceAll()
        #expect(try fixture.cache.status().residentCount == 2)

        // Everything queued has bytes: nothing to do, at once.
        #expect(await fixture.cache.fetchQueuedOnce() == .drained)
    }

    @Test("A card whose fetch fails leaves the queue and keeps its row")
    func failedFetchDropsTheCard() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        while try fixture.cache.deal() {}
        #expect(try fixture.cache.queue.size() == 2)

        // The drive goes away before anything is fetched. The provider cannot
        // read either file and cannot confirm either gone, so the rows stay.
        try fixture.library.database.run(
            "UPDATE source SET locator = :locator WHERE id = :id;",
            ["locator": "/Volumes/NotMounted/photos", "id": .int(fixture.source.id)]
        )

        let step = await fixture.cache.fetchQueuedOnce()
        guard case .failed = step else { Issue.record("expected a failed fetch, got \(step)"); return }

        // **Syd's rule: move on with the next card.** One card gone from the
        // queue, its photograph still in the library and dealable again.
        #expect(try fixture.cache.queue.size() == 1)
        #expect(try fixture.library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 2)
        #expect(try fixture.deck.poolSize() == 2)
        #expect(try fixture.cache.status().residentCount == 0)
    }

    @Test("A card whose file is gone from a present source is dropped from the library")
    func absentFileIsRemovedByItsFetch() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        while try fixture.cache.deal() {}
        let head = try #require(try fixture.cache.queue.peek().first)
        fixture.folder.remove(head.externalID)

        let step = await fixture.cache.fetchQueuedOnce()
        guard case .failed = step else { Issue.record("expected a failed fetch, got \(step)"); return }

        // The source is right there and says the file is gone, so the row goes
        // and the card goes with it by cascade. The other card is untouched.
        #expect(try fixture.library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 1)
        #expect(try fixture.cache.queue.size() == 1)
    }

    @Test("A benched source's cards are walked past and left in place")
    func benchedCardsAreLeftForLater() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        var cache = fixture.cache
        let bench = SourceBench(pauseAfter: 1)
        cache.bench = bench
        while try cache.deal() {}

        // One timeout benches the source outright.
        bench.failed(fixture.source.id)

        let step = await cache.fetchQueuedOnce()
        guard case .benched(let position) = step else { Issue.record("\(step)"); return }
        // The lane moves past it and finds only more of the same, then drains.
        let next = await cache.fetchQueuedOnce(after: position)
        guard case .benched(let position2) = next else { Issue.record("\(next)"); return }
        #expect(await cache.fetchQueuedOnce(after: position2) == .drained)

        // Nothing fetched, nothing dropped: the cards wait for the bench to end.
        #expect(try cache.queue.size() == 2)
        #expect(try cache.status().residentCount == 0)
    }

    @Test("Fetching a queued card takes the claim, and finishing releases it")
    func fetchingClaimsAndReleases() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        while try fixture.cache.deal() {}

        let step = fixture.cache.nextQueuedToFetch()
        guard case .card(let card, _, _) = step else { Issue.record("\(step)"); return }
        // Claimed: a second lane asking for the head gets nothing.
        #expect(try fixture.deck.claim(photoID: card.id) == false)
        guard case .drained = fixture.cache.nextQueuedToFetch() else {
            Issue.record("a claimed card was handed to a second lane"); return
        }

        let landed = await fixture.cache.fetch(card)
        #expect(landed)
        fixture.cache.finishFetch(card, landed: landed)
        #expect(try fixture.deck.claim(photoID: card.id) == true)
    }

    @Test("Each deal yields a different picture, and running out is an ordinary answer")
    func dealingDoesNotRepeat() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png"])
        // Stocks the cache and deals from it, which is the order v2 works in.
        try await fixture.produceAll()

        #expect(try fixture.cache.queue.size() == 3)
        #expect(Set(try fixture.cache.queue.peek(10).map(\.id)).count == 3)

        // Everything it has is queued, so there is nothing left to deal.
        #expect(try fixture.cache.deal() == false)
    }

    @Test("A volume at its floor stops the cache, and dealing is unaffected")
    func lowDiskStopsCaching() async throws {
        let fixture = try await Fixture(
            photos: ["a.png", "b.png"],
            settings: CacheSettings(minimumFreeBytes: .max, criticalFreeBytes: .max)
        )

        // **"Dealing is unaffected" is the point of this test again.** It was
        // false from 2026-08-26 to 2026-09-05, when the deck's pool was the
        // cache and a cache that could not grow was a deck that stayed empty.
        // The deck deals every available photograph now, so a card is dealt
        // whatever the disk is doing; what the floor stops is the fetch behind
        // it, before any credit arithmetic and before the queue is looked at.
        #expect(try fixture.cache.deal() == true)
        #expect(await fixture.cache.fetchQueuedOnce() == .blocked)
        #expect(try fixture.cache.status().residentCount == 0)
        #expect(try fixture.cache.queue.size() == 1, "a blocked fetch is not a failed one")
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

        let unreachable = try await fixture.store.add(kind: .folder, locator: "/Volumes/NotMounted/photos")
        let verdict = await provider.existence(of: "a.png", in: unreachable)
        #expect(verdict != .absent)
        if case .unknown = verdict {} else {
            Issue.record("expected .unknown for an unreachable source, got \(verdict)")
        }
    }

    @Test("Offline keeps its cached bytes, and keeps dealing and serving them")
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

        // The cached copies are the most valuable thing we have now, and they
        // stay in the pool: a photograph is served out of the cache regardless
        // of reachability, and reachability is not part of the deal at all.
        #expect(try await fixture.cache.serve() != nil)
        #expect(try fixture.deck.poolSize() == 3)
        #expect(try fixture.cache.status().residentCount == 3)
    }

    // MARK: - Eviction

    private func uuidsByID(_ fixture: Fixture) throws -> [String] {
        try fixture.library.database.all("SELECT uuid FROM photo ORDER BY id;") {
            try $0.string("uuid")
        }
    }

    /// Records that these photographs were shown, oldest first.
    ///
    /// **This replaces ageing the files by hand.** Eviction used to be FIFO by
    /// write time, so a test had to backdate modification dates because a
    /// produce loop finishes in microseconds and every file shared a timestamp.
    /// The order is `COALESCE(last_shown_at, cached_at)` now, which is a fact
    /// about the photograph rather than about its file — so the test states it
    /// directly.
    private func shown(_ fixture: Fixture, oldestFirst uuids: [String]) throws {
        for (index, uuid) in uuids.enumerated() {
            try fixture.library.database.run(
                "UPDATE photo SET last_shown_at = :at WHERE uuid = :uuid;",
                ["at": .int(Int64(1000 + index)), "uuid": .text(uuid)])
        }
    }

    @Test("Eviction takes the longest-unseen first")
    func evictionIsLeastRecentlyViewed() async throws {
        let fixture = try await Fixture(
            photos: (0..<10).map { "photo-\($0).png" },
            settings: CacheSettings(byteCeiling: 10_000)
        )
        try await fixture.produceAll()

        let uuids = try uuidsByID(fixture)
        try shown(fixture, oldestFirst: uuids)

        // Through a cache whose *settings* carry the tight ceiling: the
        // eviction order comes from the database, so it has to go through
        // `PhotoCache`, and that reasserts the store's ceiling from its own
        // settings every time.
        let tight = PhotoCache(
            database: fixture.library.database, root: fixture.cache.root,
            settings: CacheSettings(byteCeiling: 400), sources: fixture.store,
            store: fixture.cache.store
        )
        let result = try tight.evictIfNeeded()
        #expect(result.evicted == 6)

        // The four most recently seen survive. **Nothing is queued-protected**:
        // every one of these is on the deck, and the ceiling is reached anyway.
        let held = uuids.filter {
            fixture.cache.store.url(for: PhotoStore.Key(photoUUID: $0)) != nil
        }
        #expect(held == Array(uuids.suffix(4)))
    }

    @Test("A photograph that has never been shown is the last to go, not the first")
    func neverShownSortsNewest() async throws {
        // The whole of the `COALESCE`. Read literally, "most recently viewed"
        // makes a photograph nobody has viewed infinitely old — so the cache
        // would reach its ceiling and then discard every download on arrival,
        // freezing on whatever happened to be resident at that moment.
        let fixture = try await Fixture(
            photos: (0..<6).map { "photo-\($0).png" },
            settings: CacheSettings(byteCeiling: 10_000)
        )
        try await fixture.produceAll()

        let uuids = try uuidsByID(fixture)
        // Five have been seen; the sixth has only just landed.
        try shown(fixture, oldestFirst: Array(uuids.prefix(5)))
        let fresh = try #require(uuids.last)

        let tight = PhotoCache(
            database: fixture.library.database, root: fixture.cache.root,
            settings: CacheSettings(byteCeiling: 200), sources: fixture.store,
            store: fixture.cache.store
        )
        #expect(try tight.evictIfNeeded().evicted > 0)

        #expect(
            fixture.cache.store.url(for: PhotoStore.Key(photoUUID: fresh)) != nil,
            "the cache evicted the photograph it had just paid for")
    }

    @Test("Nothing is exempt, so the ceiling is always reachable")
    func theCeilingIsAlwaysReachable() async throws {
        // **The protection that used to be here made the ceiling unreachable.**
        // Everything cached was also queued, so eviction could free nothing at
        // all — set `byteCeiling` low, or let the volume fill from outside the
        // agent, and we sat over the limit holding entries we were forbidden to
        // touch.
        let fixture = try await Fixture(
            photos: (0..<10).map { "photo-\($0).png" },
            settings: CacheSettings(byteCeiling: 10_000)
        )
        try await fixture.produceAll()
        #expect(try fixture.cache.queue.size() == 10, "every photograph is on the deck")

        let tighter = PhotoCache(
            database: fixture.library.database, root: fixture.cache.root,
            settings: CacheSettings(byteCeiling: 300), sources: fixture.store,
            store: fixture.cache.store
        )
        let result = try tighter.evictIfNeeded()

        #expect(result.evicted > 0)
        #expect(fixture.cache.store.totals.byteCount <= 300)
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

    @Test("A crashed download's staging leftovers are reclaimed at the next launch")
    func stagingLeftoversAreReclaimedAtPrepare() async throws {
        let fixture = try await Fixture(photos: ["a.png"])

        // A crash mid-download leaves its temporary behind, and the index walk
        // never looks inside `.staging` — its name is neither `.original` nor a
        // size — so nothing else can ever reclaim it: it is invisible to byte
        // accounting and to eviction alike.
        let staging = fixture.cache.root.appending(path: ".staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let leftover = staging.appending(path: "\(UUID().uuidString.lowercased()).jpg")
        try Data(repeating: 0xFF, count: 64).write(to: leftover)

        try fixture.cache.prepare()  // the next launch
        #expect(!FileManager.default.fileExists(atPath: leftover.path(percentEncoded: false)))
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

    @Test("Cards survive a restart, and so does what the cache holds for them")
    func dealtCardsSurviveARestart() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])

        // **The premise changed and the property did not.** This used to deal
        // cards with no bytes behind them, because that was the ordinary state
        // of a materialized card. It cannot be now — so the cache is stocked
        // first, and what a restart must not do is throw the queue away.
        try await fixture.produceAll()
        let dealt = try fixture.cache.queue.size()
        #expect(dealt == 2)
        #expect(try fixture.cache.status().residentCount == 2)

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

        // **The rows are all still there, and so is the pool.** Clearing is a
        // storage operation and never a shuffle one — deal ordinals, shuffle
        // keys and last-shown times are untouched, which is what `seqBefore`
        // above holds down. From 2026-08-26 to 2026-09-05 the pool was the
        // cache and clearing emptied it; the deck deals every available
        // photograph again, so the pictures are dealt cold and fetched by the
        // queue.
        #expect(try fixture.library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 3)
        #expect(try fixture.deck.poolSize() == 3)
    }

    @Test("Clearing one source frees its bytes and leaves every other source alone")
    func clearingOneSourceSparesTheRest() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        let second = TemporaryFolder(name: "pgr-cache-src2")
        defer { _ = second }
        for name in ["c.png", "d.png", "e.png"] { second.write(name, bytes: 100) }
        let other = try await fixture.store.add(kind: .folder, locator: second.path, recursive: true)
        await fixture.store.refresh(other)
        try fixture.library.database.run("UPDATE photo SET storage = 'materialized';")
        try await fixture.produceAll()
        #expect(try fixture.cache.status().residentCount == 5)

        // One directory removal rather than thousands of unlinks, which is the
        // whole reason the cache layout has a per-source level.
        let result = try fixture.cache.clear(.source(fixture.source.id))
        #expect(result.cleared == 2)
        #expect(result.bytesFreed == 200)
        #expect(try fixture.cache.status().residentCount == 3, "the other source lost bytes too")

        // Rows and shuffle history are untouched: clearing is a storage
        // operation, never a shuffle operation, and since 2026-09-05 the pool
        // is the rows rather than the bytes — so it is untouched too.
        #expect(try fixture.library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 5)
        #expect(try fixture.deck.poolSize() == 5)
    }

    @Test("Clearing unavailable sources frees only what can never be fetched again")
    func clearingUnavailableSourcesIsNarrow() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        let gone = TemporaryFolder(name: "pgr-cache-gone")
        defer { _ = gone }
        for name in ["c.png", "d.png"] { gone.write(name, bytes: 100) }
        let missing = try await fixture.store.add(kind: .folder, locator: gone.path, recursive: true)
        await fixture.store.refresh(missing)
        try fixture.library.database.run("UPDATE photo SET storage = 'materialized';")
        try await fixture.produceAll()
        try fixture.library.database.run(
            "UPDATE source SET available = 0 WHERE id = :id;", ["id": .int(missing.id)])

        // The variant to reach for first: photographs whose source is gone can
        // never be re-fetched, so this frees space at zero future cost.
        let cost = try fixture.cache.costOfClearing(.unavailableSources)
        #expect(cost.costsNothingToRefetch)
        #expect(cost.bytesFreed == 200)

        let result = try fixture.cache.clear(.unavailableSources)
        #expect(result.cleared == 2)
        #expect(result.bytesFreed == 200)
        // The reachable source keeps everything. The cleared ones kept their
        // rows too, and since 2026-09-05 rows are the pool: clearing is a
        // storage operation, and reachability is not part of the deal.
        #expect(try fixture.cache.status().residentCount == 2)
        #expect(try fixture.library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 4)
        #expect(try fixture.deck.poolSize() == 4)
    }

    @Test("An explicit clear states its price before charging it")
    func clearingReportsItsCost() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png", "c.png"])
        try await fixture.produceAll()

        // For materialized photographs the price is a re-download apiece; the
        // command and the UI both say so before confirming.
        let cost = try fixture.cache.costOfClearing(.everything)
        #expect(cost.needingRefetch == 3)
        #expect(cost.bytesFreed == 300)
        #expect(cost.referencedAndFree == 0)
        #expect(!cost.costsNothingToRefetch, "a full clear is never free")
    }

    @Test("Referenced photographs cost nothing to re-retrieve, because that means opening a file")
    func referencedPhotographsAreFreeToClear() async throws {
        // Never copied, so there is nothing of theirs to free and nothing to
        // fetch again.
        let fixture = try await Fixture(photos: ["a.png", "b.png"], materialized: false)
        try await fixture.produceAll()

        let cost = try fixture.cache.costOfClearing(.everything)
        #expect(cost.referencedAndFree == 2)
        #expect(cost.needingRefetch == 0)
        #expect(cost.bytesFreed == 0)
    }

    /// Reaching the critical branch takes a cache built for it: the settings
    /// clamp `criticalFreeBytes` to `minimumFreeBytes`, and a minimum that
    /// every volume is under stops anything being cached in the first place.
    /// So the bytes are put there under ordinary settings and the pass is run
    /// by a second cache over the same store — the same shape the ceiling
    /// tests use.
    @Test("Below the critical floor, eviction runs ahead of the ceiling")
    func criticallyLowDiskEvictsAheadOfTheCeiling() async throws {
        let fixture = try await Fixture(photos: (0..<10).map { "photo-\($0).png" })
        try await fixture.produceAll()
        try fixture.library.database.run("DELETE FROM queue;")
        #expect(try fixture.cache.status().bytesOnDisk == 1000)

        // The ceiling sits above what is held, so nothing would go on the
        // ordinary path — and `criticalFreeBytes: .max` makes every volume
        // critically low, which is how the branch is reached without a
        // filesystem that can be starved on demand.
        let starved = PhotoCache(
            database: fixture.library.database, root: fixture.cache.root,
            settings: CacheSettings(
                byteCeiling: 1500, minimumFreeBytes: .max, criticalFreeBytes: .max),
            sources: fixture.store, store: fixture.cache.store
        )
        // Halved: running out of disk degrades into a smaller cache rather
        // than a full volume, which on macOS is a bad day for everything else
        // running.
        #expect(try starved.evictIfNeeded().evicted > 0)
        #expect(try starved.status().bytesOnDisk <= 750)
    }

    @Test("With free space in hand, the ceiling is the whole policy")
    func healthyDiskEvictsOnlyAtTheCeiling() async throws {
        let fixture = try await Fixture(photos: (0..<10).map { "photo-\($0).png" })
        try await fixture.produceAll()
        try fixture.library.database.run("DELETE FROM queue;")

        // The same thousand bytes under the same ceiling, with the floor not
        // tripped: nothing goes.
        let healthy = PhotoCache(
            database: fixture.library.database, root: fixture.cache.root,
            settings: CacheSettings(
                byteCeiling: 1500, minimumFreeBytes: 0, criticalFreeBytes: 0),
            sources: fixture.store, store: fixture.cache.store
        )
        #expect(try healthy.evictIfNeeded().evicted == 0)
        #expect(try healthy.status().bytesOnDisk == 1000)
    }
}

/// Eviction on a library that lives on the boot volume.
///
/// **The ordinary case, and the one the eviction order first got wrong.** A
/// referenced photograph is read in place and never copied, so it has no
/// `cached_at` — but the cache still holds *renderings* for it, and those are
/// the only thing it ever holds for one. An eviction order built from
/// `cached_at` cannot see them, and an entry the order does not rank is the
/// first thing out.
@Suite("Eviction on the boot volume")
struct ReferencedEvictionTests {

    private struct Fixture {
        let folder: TemporaryFolder
        let cacheRoot: TemporaryFolder
        let library: TestLibrary
        let sources: SourceStore
        let cache: PhotoCache

        init(photos: Int, byteCeiling: Int64) async throws {
            folder = TemporaryFolder(name: "pgr-ref-evict")
            cacheRoot = TemporaryFolder(name: "pgr-ref-evict-cache")
            for i in 0..<photos { folder.write("photo-\(i).png", bytes: 64) }

            library = try TestLibrary()
            sources = SourceStore(database: library.database)
            cache = PhotoCache(
                database: library.database,
                root: cacheRoot.url.appending(path: "cache"),
                settings: CacheSettings(byteCeiling: byteCeiling),
                sources: sources
            )
            try cache.prepare()
            let source = try await sources.add(
                kind: .folder, locator: folder.path, recursive: true)
            await sources.refresh(source)
            // Everything in a temporary directory really is on the boot volume,
            // so this is what the classifier decides on its own.
            try library.database.run("UPDATE photo SET storage = 'referenced';")
        }

        /// Keeps a rendering for each photograph, which is the only thing the
        /// cache ever holds for a referenced one.
        func render(_ uuids: [String], bytes: Int) throws {
            let size = PhotoStore.Size(width: 100, height: 100)
            for uuid in uuids {
                try cache.store.store(
                    Data(count: bytes), for: PhotoStore.Key(photoUUID: uuid, size: size),
                    sourceUUID: "src", pathExtension: "jpeg")
            }
        }

        func uuids() throws -> [String] {
            try library.database.all("SELECT uuid FROM photo ORDER BY id;") {
                try $0.string("uuid")
            }
        }

        func held(_ uuid: String) -> Bool {
            cache.store.url(
                for: PhotoStore.Key(
                    photoUUID: uuid, size: PhotoStore.Size(width: 100, height: 100))) != nil
        }
    }

    @Test("A referenced photograph's rendering is evicted by recency, not first")
    func referencedRenderingsAreRanked() async throws {
        let fixture = try await Fixture(photos: 6, byteCeiling: 250)
        let uuids = try fixture.uuids()
        try fixture.render(uuids, bytes: 100)

        // Shown oldest-first, so the last two are the ones worth keeping.
        for (index, uuid) in uuids.enumerated() {
            try fixture.library.database.run(
                "UPDATE photo SET last_shown_at = added_at + :at WHERE uuid = :uuid;",
                ["at": .int(Int64(1000 + index)), "uuid": .text(uuid)])
        }

        #expect(try fixture.cache.evictIfNeeded().evicted > 0)

        // The two most recently shown must survive. Ordering the whole cache by
        // a column referenced photographs never have puts every one of them
        // ahead of everything else, so the ones just displayed go first.
        #expect(fixture.held(uuids[5]), "evicted the rendering shown most recently")
        #expect(fixture.held(uuids[4]), "evicted the rendering shown second most recently")
        #expect(!fixture.held(uuids[0]), "kept the rendering nobody has looked at in longest")
    }

    @Test("A referenced photograph nobody has shown still ranks, and ranks oldest")
    func neverShownReferencedRanksOldest() async throws {
        // The third `COALESCE` term. A referenced photograph that has never
        // been displayed has no `last_shown_at` and no `cached_at` — only
        // `added_at`. Without that term it is unranked, which is to say first
        // out, and a rendering made for it is thrown away before anything that
        // has actually been looked at.
        let fixture = try await Fixture(photos: 4, byteCeiling: 250)
        let uuids = try fixture.uuids()
        try fixture.render(uuids, bytes: 100)

        // Two shown; two never shown at all. **Relative to `added_at`**, not an
        // arbitrary small number: these columns are all real timestamps on the
        // same scale, and a photograph cannot be shown before it was added.
        // Writing 5000 here made the shown ones sort oldest and the test failed
        // against correct code — worth saying, because it is an easy way to
        // write a test that lies.
        for uuid in uuids.suffix(2) {
            try fixture.library.database.run(
                """
                UPDATE photo SET last_shown_at = added_at + 1000 WHERE uuid = :uuid;
                """,
                ["uuid": .text(uuid)])
        }

        #expect(try fixture.cache.evictIfNeeded().evicted > 0)

        // The two that were displayed survive; the two nobody has looked at go.
        #expect(fixture.held(uuids[2]) && fixture.held(uuids[3]))
    }

    @Test("Local and remote photographs compete for the ceiling on one rule")
    func aMixedLibraryRanksOnOneOrder() async throws {
        // **The case the whole design turns on**, and the one no unit test
        // reached until now: a library with both kinds in it. A referenced
        // photograph's rendering and a fetched original are both bytes under
        // the same ceiling, and the order that decides between them has to be
        // one order — not "everything remote, then everything local".
        let fixture = try await Fixture(photos: 6, byteCeiling: 250)
        let uuids = try fixture.uuids()
        try fixture.render(uuids, bytes: 100)

        // Half the library is remote and its originals have landed.
        for uuid in uuids.prefix(3) {
            try fixture.library.database.run(
                """
                UPDATE photo SET storage = 'materialized', cached_at = 2000
                 WHERE uuid = :uuid;
                """,
                ["uuid": .text(uuid)])
        }

        // Interleaved by recency, deliberately alternating the two kinds: the
        // most recently shown is remote, the next is local, and so on.
        let order = [uuids[0], uuids[3], uuids[1], uuids[4], uuids[2], uuids[5]]
        for (index, uuid) in order.enumerated() {
            try fixture.library.database.run(
                "UPDATE photo SET last_shown_at = added_at + :at WHERE uuid = :uuid;",
                ["at": .int(Int64(1000 + index)), "uuid": .text(uuid)])
        }

        #expect(try fixture.cache.evictIfNeeded().evicted > 0)

        // The survivors are the most recently shown *whatever kind they are*.
        #expect(fixture.held(uuids[5]), "a local rendering lost to recency it should have won")
        #expect(fixture.held(uuids[2]), "a remote rendering lost to recency it should have won")
        #expect(!fixture.held(uuids[0]), "the longest-unseen was kept")
    }
}
