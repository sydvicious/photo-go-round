import Foundation

/// The bounded window of actual image files.
///
/// The single most important thing to keep straight is that there are two
/// populations and only one of them is bounded. Every photo in every source has
/// a row; the cache holds bytes for a bounded number of them. If the database
/// only held what was cached, the shuffle would be a shuffle of a thousand
/// photos and the other forty-nine thousand would surface only through whatever
/// refill policy pulled them in.
///
/// So the cache is purely a performance layer — a prediction about which photos
/// are needed soon, wrong at worst, never a constraint on what can appear.
public struct PhotoCache {
    public let database: Database
    /// Where materialized bytes live. Supplied by the host; the kit never
    /// constructs a path from a hardcoded root.
    public let root: URL
    public let settings: CacheSettings

    /// Pictures that are ready to show. The cache fills it and serves from it.
    public let queue: PhotoQueue
    /// The bytes, and the only record of them. Nothing in the database describes
    /// what is cached.
    public let store: PhotoStore

    private let sources: SourceStore
    private let deck: Deck

    public init(
        database: Database,
        root: URL,
        settings: CacheSettings = .default,
        sources: SourceStore,
        deck: Deck? = nil,
        queueSize: Int = 1000,
        store: PhotoStore? = nil
    ) {
        self.database = database
        self.root = root
        self.settings = settings
        self.sources = sources
        self.deck = deck ?? Deck(database: database)
        self.queue = PhotoQueue(database: database, nominalSize: queueSize)
        self.store = store ?? PhotoStore(root: root, byteCeiling: settings.byteCeiling)
    }

    /// Creates the cache directory and keeps it out of Time Machine.
    ///
    /// Letting a backup copy tens of gigabytes of photos that are already in the
    /// Photos library or already in iCloud wastes the user's backup volume on
    /// data we can reconstruct.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
        try indexCache()
    }

    /// Rebuilds the byte index from the disk, discarding anything the database
    /// does not claim.
    ///
    /// This is the whole of what used to be `verifyResidency` and
    /// `sweepOrphans`: an index built *from* the filesystem cannot disagree with
    /// it, and a file whose UUID is unknown has no owner left that could name it
    /// correctly.
    @discardableResult
    public func indexCache() throws -> (kept: Int, discarded: Int, bytes: Int64) {
        var owners: [String: String] = [:]
        try database.query(
            """
            SELECT p.uuid AS photo_uuid, s.uuid AS source_uuid
              FROM photo p JOIN source s ON s.id = p.source_id;
            """
        ) { row in
            owners[try row.string("photo_uuid")] = try row.string("source_uuid")
        }
        let result = store.rebuild(photos: owners)

        // The queue is durable and the index is not, so they are reconciled once
        // at launch, in the direction of the disk.
        var stale = 0
        for card in try queue.peek(Int.max) where card.storage == .materialized {
            if store.url(for: PhotoStore.Key(photoUUID: card.uuid)) == nil {
                try queue.remove(photoID: card.id)
                stale += 1
            }
        }
        if stale > 0 {
            Log.cache.notice(
                "dropped \(stale, privacy: .public) queued pictures whose bytes are not here"
            )
        }
        return result
    }

    // MARK: - Where bytes are

    /// A readable URL for a photo's bytes, or nil when they are not resident.
    ///
    /// Referenced photos resolve through `FileAccess` against their source;
    /// materialized ones resolve against the cache root. A consumer asks this
    /// and does not care which it got.
    public func residentURL(forPhoto photoID: Int64) throws -> URL? {
        let row = try database.first(
            """
            SELECT p.storage, p.uuid, p.external_id, p.source_id
              FROM photo p WHERE p.id = :id;
            """,
            ["id": .int(photoID)]
        ) { row in
            (
                storage: PhotoStorage(rawValue: try row.string("storage")) ?? .materialized,
                uuid: try row.string("uuid"),
                externalID: try row.string("external_id"),
                sourceID: try row.int64("source_id")
            )
        }
        guard let row else { return nil }

        switch row.storage {
        case .materialized:
            return store.url(for: PhotoStore.Key(photoUUID: row.uuid))
        case .referenced:
            guard let source = try sources.source(id: row.sourceID) else { return nil }
            // Through the seam, never from the stored path — so this keeps
            // working unchanged if the Mac is ever forced to sandbox.
            return try sources.fileAccess.withPhotoURL(in: source, externalID: row.externalID) { url in
                FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
            }
        }
    }

    // MARK: - Status

    public struct Status: Sendable, Equatable {
        /// Materialized photos whose original is held.
        public let residentCount: Int
        /// Photos referenced in place. Not copied, not budgeted, free.
        public let referencedCount: Int
        /// Materialized photos still waiting for their bytes.
        public let pendingCount: Int
        /// Renderings held, across every size and photograph.
        public let renderingCount: Int
        public let bytesOnDisk: Int64
        public let byteCeiling: Int64
        public let freeBytesOnVolume: Int64
        /// Pictures waiting in the queue, ready to show.
        public let queued: Int
    }

    public func status() throws -> Status {
        let materialized =
            try database.scalarInt(
                "SELECT COUNT(*) FROM photo WHERE storage = 'materialized';") ?? 0
        let referenced =
            try database.scalarInt(
                "SELECT COUNT(*) FROM photo WHERE storage = 'referenced';") ?? 0
        let totals = store.totals

        return Status(
            residentCount: totals.originals,
            referencedCount: referenced,
            pendingCount: max(0, materialized - totals.originals),
            renderingCount: totals.renderings,
            bytesOnDisk: totals.byteCount,
            byteCeiling: settings.byteCeiling,
            freeBytesOnVolume: freeBytesOnVolume(),
            queued: try queue.size()
        )
    }

    func freeBytesOnVolume() -> Int64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    // MARK: - Producing one picture

    /// Asks this source for one picture, makes sure its bytes are there, and
    /// appends it to the queue.
    ///
    /// This is what a provider *answering a request* amounts to, and it is where
    /// downloading happens. There is no separate fetch stage walking a work
    /// list: producing a picture and fetching its bytes are the same operation,
    /// so a picture is never queued unless it is ready to show.
    ///
    /// Returns false when this source had nothing to offer, which is an ordinary
    /// answer — an empty source, everything already queued, or a download that
    /// failed.
    @discardableResult
    public func produce(
        forSource sourceID: Int64,
        settings: DeckSettings = .default,
        now: Date = Date()
    ) async throws -> Bool {
        // Free space is checked before fetching, so running out of disk degrades
        // into "the queue stops growing" rather than a full volume.
        let free = freeBytesOnVolume()
        guard free >= self.settings.minimumFreeBytes else {
            Log.cache.notice(
                "not producing: \(free, privacy: .public) bytes free, floor is \(self.settings.minimumFreeBytes, privacy: .public)"
            )
            return false
        }

        guard let source = try sources.source(id: sourceID),
            source.enabled,
            let provider = sources.provider(for: source.kind),
            let candidate = try deck.nextCandidate(forSource: sourceID, settings: settings, now: now)
        else { return false }

        // Selection claimed it so that a concurrent producer against this same
        // source picks something else. The claim is ours until we are done with
        // it, and it ends here whatever the outcome — queued, failed, or thrown
        // past. A photo left claimed by a path nobody thought about waits out
        // the timeout for no reason at all.
        defer { try? deck.releaseClaim(photoID: candidate.id) }

        let originalKey = PhotoStore.Key(photoUUID: candidate.uuid)
        if candidate.storage == .materialized, !store.contains(originalKey) {
            let extension_ = (candidate.externalID as NSString).pathExtension
            let staging = root.appending(path: ".staging")
            try? FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true)
            let temporary = staging.appending(
                path: extension_.isEmpty ? candidate.uuid : "\(candidate.uuid).\(extension_)")

            do {
                let file = try await provider.materialize(
                    externalID: candidate.externalID, from: source, to: temporary)
                try store.adopt(
                    fileAt: temporary, for: originalKey,
                    sourceUUID: candidate.sourceUUID, pathExtension: extension_, now: now)
                try database.run(
                    "UPDATE photo SET byte_size = :size WHERE id = :id;",
                    ["size": .int(file.byteSize), "id": .int(candidate.id)]
                )
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                try handleFailedDownload(candidate, source: source, error: error)
                return false
            }
        } else if candidate.storage == .referenced {
            // Referenced photographs are never copied, but the store still has
            // to know which source they belong to, so a rendering of one lands
            // in the right directory.
            store.note(photoUUID: candidate.uuid, sourceUUID: candidate.sourceUUID)
        }

        return try queue.append(photoID: candidate.id, sourceID: sourceID, at: now)
    }

    /// A download that failed means two completely different things depending on
    /// whether the source is there.
    ///
    /// **Source online:** the file is genuinely gone, so the entry leaves the
    /// pool and our copy goes with it. **Source offline:** the failure says
    /// nothing about the file, so the entry stays and only its queue place is
    /// cleared. This is the whole answer to the offline volume problem, and the
    /// check happens here rather than at refresh time because a drive can go
    /// away in between.
    private func handleFailedDownload(_ card: DeckCard, source: Source, error: any Error) throws {
        if sources.isOnline(source) {
            Log.cache.notice(
                "photo \(card.id, privacy: .public) could not be downloaded from an online source; removing it from the pool"
            )
            try self.remove(card.id)
        } else {
            Log.cache.info(
                "photo \(card.id, privacy: .public) is on an offline source; leaving it in the pool"
            )
            try queue.remove(photoID: card.id)
        }
    }

    /// The rendering held for this photograph at this size, if any.
    public func rendering(of card: DeckCard, at size: PhotoStore.Size) -> URL? {
        store.url(for: PhotoStore.Key(photoUUID: card.uuid, size: size))
    }

    /// Keeps a rendering, so the next request for the same photograph at the
    /// same size is a file read rather than a decode.
    @discardableResult
    public func keep(
        _ bytes: Data, of card: DeckCard, at size: PhotoStore.Size, pathExtension: String
    ) throws -> URL {
        try store.store(
            bytes, for: PhotoStore.Key(photoUUID: card.uuid, size: size),
            sourceUUID: card.sourceUUID, pathExtension: pathExtension)
    }

    // MARK: - Serving one picture

    /// Takes the head of the queue and gives it to a consumer.
    ///
    /// **Every picture is checked against its source in the moment before it is
    /// returned**, including one we hold our own copy of. That is the guarantee:
    /// a photo the user deleted is never shown again, not even in the minutes
    /// before a refresh would have noticed.
    ///
    /// Returns nil when there is nothing to show, which is an ordinary answer.
    /// A fresh install has an empty queue and an empty cache, so the first
    /// requests are answered this way and pictures begin arriving as providers
    /// deliver.
    public func serve(
        to consumerID: Int64? = nil,
        now: Date = Date()
    ) async throws -> (card: DeckCard, url: URL)? {
        while let card = try queue.serve(at: now) {
            guard let source = try sources.source(id: card.sourceID),
                let provider = sources.provider(for: source.kind)
            else { continue }

            switch await provider.existence(of: card.externalID, in: source) {
            case .absent:
                Log.cache.notice(
                    "photo \(card.id, privacy: .public) is gone from a reachable source; removing it rather than showing it"
                )
                try self.remove(card.id)

            case .unknown, .present:
                guard let url = try residentURL(forPhoto: card.id) else { continue }
                let seq = try deck.markShown(photoID: card.id, now: now)
                if let consumerID { try? deck.touch(consumerID: consumerID, at: now) }
                // The deck moved, so anything mirroring its position — a
                // diagnostic panel, another surface's idea of what is next —
                // should go and look.
                DarwinNotification.post(.deckAdvanced)
                return (
                    DeckCard(
                        id: card.id, uuid: card.uuid, sourceID: card.sourceID,
                        sourceUUID: card.sourceUUID, externalID: card.externalID,
                        storage: card.storage, dealSeq: seq
                    ),
                    url
                )
            }
        }
        return nil
    }

    // MARK: - Keeping the bytes honest

    /// Removes entries from the pool *and* their cached bytes, together.
    ///
    /// This is what "the file is gone" means: the entry goes, its queue place
    /// goes with it by cascade, and the copy we were holding is deleted rather
    /// than left for the next sweep. A photo missing from a source that is
    /// *there* no longer exists, so there is nothing left worth keeping.
    ///
    /// Contrast a source that is merely offline, where the cached bytes are the
    /// most valuable thing we have and keep being served.
    @discardableResult
    public func remove(_ photoIDs: [Int64]) throws -> PhotoPool.Removal {
        let removal = try sources.pool.remove(photoIDs)
        for uuid in removal.orphaned { store.remove(photoUUID: uuid) }
        return removal
    }

    @discardableResult
    public func remove(_ photoID: Int64) throws -> PhotoPool.Removal {
        try remove([photoID])
    }

    // MARK: - Eviction

    public struct EvictionResult: Sendable, Equatable {
        public let evicted: Int
        public let bytesFreed: Int64
        /// Entries over the ceiling that were left alone because their
        /// photograph is queued.
        public let protectedFromEviction: Int
    }

    /// FIFO by creation time, bounded by bytes, over `(photo, resolution)`
    /// entries rather than over photographs.
    ///
    /// Plain FIFO is correct rather than something cleverer because entries are
    /// written *in deck order*: the order bytes enter the cache is the order
    /// they will be shown, so oldest-written is also longest-since-dealt. The
    /// cache is a sliding window over the deck — expiring off the front, filling
    /// at the back.
    @discardableResult
    public func evictIfNeeded() throws -> EvictionResult {
        // The disk-space guard evicts ahead of the ceiling, folded in as a lower
        // effective ceiling rather than as a second pass.
        let free = freeBytesOnVolume()
        if free < settings.criticalFreeBytes {
            Log.cache.notice(
                "evicting ahead of the ceiling: only \(free, privacy: .public) bytes free"
            )
            store.byteCeiling = max(0, settings.byteCeiling / 2)
        } else {
            store.byteCeiling = settings.byteCeiling
        }

        let result = store.evictIfNeeded(protecting: try queuedPhotoUUIDs())
        return EvictionResult(
            evicted: result.evicted,
            bytesFreed: result.bytesFreed,
            protectedFromEviction: result.protected
        )
    }

    /// Photographs waiting in the queue, which eviction must not touch whatever
    /// their age — they are about to be shown.
    func queuedPhotoUUIDs() throws -> Set<String> {
        Set(
            try database.all(
                "SELECT p.uuid FROM queue q JOIN photo p ON p.id = q.photo_id;"
            ) { try $0.string("uuid") })
    }

    // MARK: - Clearing on purpose

    public enum ClearScope: Sendable, Equatable {
        case everything
        case source(Int64)
        /// Photos belonging to sources that are gone. These can never be
        /// re-fetched anyway, which makes this the variant to reach for first:
        /// it frees space at zero future cost.
        case unavailableSources
    }

    /// What an explicit clear would cost, so the operation can state its price
    /// before charging it.
    ///
    /// Ordinary eviction is incremental, continuous, and invisible. An explicit
    /// clear is the other thing entirely: everything has to be fetched again,
    /// which for an iCloud-optimized library can be tens of gigabytes over a
    /// connection that may be metered.
    public struct ClearCost: Sendable, Equatable {
        /// Materialized photos whose bytes would be discarded and would have to
        /// be fetched again.
        public let needingRefetch: Int
        public let bytesFreed: Int64
        /// Referenced photos in scope — free to "re-retrieve", since that means
        /// opening a file.
        public let referencedAndFree: Int
        /// True when nothing in scope could ever be fetched again, so there is
        /// no future cost to warn about.
        public let costsNothingToRefetch: Bool
    }

    public func costOfClearing(_ scope: ClearScope) throws -> ClearCost {
        let (predicate, bindings) = Self.scopePredicate(scope)
        let rows = try database.all(
            """
            SELECT p.uuid, p.storage FROM photo p JOIN source s ON s.id = p.source_id
             WHERE \(predicate);
            """,
            bindings
        ) { (uuid: try $0.string("uuid"), storage: try $0.string("storage")) }

        var refetch = 0
        var bytes: Int64 = 0
        var referenced = 0
        for row in rows {
            if row.storage == "referenced" { referenced += 1 }
            let held = store.sizes(forPhoto: row.uuid).count
                + (store.contains(PhotoStore.Key(photoUUID: row.uuid)) ? 1 : 0)
            guard held > 0 else { continue }
            if row.storage == "materialized" { refetch += 1 }
        }
        // The byte total comes from the index, since the database no longer
        // records what is held.
        let claimed = Set(rows.map(\.uuid))
        bytes = store.byteCount(ofPhotos: claimed)

        return ClearCost(
            needingRefetch: refetch,
            bytesFreed: bytes,
            referencedAndFree: referenced,
            costsNothingToRefetch: scope == .unavailableSources
        )
    }

    public struct ClearResult: Sendable, Equatable {
        public let cleared: Int
        public let bytesFreed: Int64
        /// Queue entries dropped because their bytes no longer exist.
        public let queueCleared: Int
    }

    /// Discards bytes. Never shuffle state.
    ///
    /// Deal ordinals, shuffle keys, and last-shown times are untouched, so a
    /// cleared cache refills into the same rotation rather than reshuffling the
    /// library. Clearing is a storage operation, never a shuffle operation.
    @discardableResult
    public func clear(_ scope: ClearScope) throws -> ClearResult {
        let (predicate, bindings) = Self.scopePredicate(scope)
        let uuids = try database.all(
            """
            SELECT p.uuid FROM photo p JOIN source s ON s.id = p.source_id
             WHERE \(predicate);
            """,
            bindings
        ) { try $0.string("uuid") }

        var freed: Int64 = 0
        var cleared = 0

        switch scope {
        case .everything:
            freed = store.removeAll()
            cleared = uuids.count
        case .source(let sourceID):
            // One directory removal rather than thousands of unlinks, which is
            // the whole reason the layout has that level.
            if let uuid = try sources.source(id: sourceID)?.uuid {
                freed = store.removeSource(uuid)
            }
            cleared = uuids.count
        case .unavailableSources:
            for uuid in uuids {
                let before = store.byteCount(ofPhotos: [uuid])
                if before > 0 { cleared += 1 }
                freed += store.remove(photoUUID: uuid)
            }
        }

        // Queued pictures point at bytes that no longer exist, so the queue is
        // emptied too. Refilling is then the cold-start path, which already
        // exists: providers are asked, and pictures arrive as they answer.
        var queueCleared = 0
        if scope == .everything {
            try database.transaction(.immediate) {
                try database.run("DELETE FROM queue;")
                queueCleared = database.changes
            }
        }

        Log.cache.notice(
            "cleared \(cleared, privacy: .public) photographs, freeing \(freed, privacy: .public) bytes"
        )
        return ClearResult(cleared: cleared, bytesFreed: freed, queueCleared: queueCleared)
    }

    private static func scopePredicate(_ scope: ClearScope) -> (String, SQLBindings) {
        switch scope {
        case .everything:
            ("1 = 1", [:])
        case .source(let id):
            ("p.source_id = :source", ["source": .int(id)])
        case .unavailableSources:
            ("s.available = 0", [:])
        }
    }

    // MARK: - SQL

}
