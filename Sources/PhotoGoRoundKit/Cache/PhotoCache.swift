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

    private let sources: SourceStore
    private let deck: Deck

    public init(
        database: Database,
        root: URL,
        settings: CacheSettings = .default,
        sources: SourceStore,
        deck: Deck? = nil
    ) {
        self.database = database
        self.root = root
        self.settings = settings
        self.sources = sources
        self.deck = deck ?? Deck(database: database)
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
    }

    // MARK: - Where bytes are

    /// The cache-relative path a photo's bytes would live at.
    ///
    /// One level of structure, and it earns its place for exactly two mechanical
    /// reasons: `clear --source 3` becomes one directory removal instead of a
    /// thousand unlinks, and per-source byte totals become a directory size
    /// instead of a query plus a stat loop. Nobody reads the cache, so it is not
    /// designed to be read.
    static func relativePath(sourceID: Int64, photoID: Int64, externalID: String) -> String {
        let ext = (externalID as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext.lowercased())"
        return "\(sourceID)/\(String(format: "%09lld", photoID))\(suffix)"
    }

    /// A readable URL for a photo's bytes, or nil when they are not resident.
    ///
    /// Referenced photos resolve through `FileAccess` against their source;
    /// materialized ones resolve against the cache root. A consumer asks this
    /// and does not care which it got.
    public func residentURL(forPhoto photoID: Int64) throws -> URL? {
        let row = try database.first(
            """
            SELECT p.storage, p.cache_path, p.external_id, p.available, p.source_id
              FROM photo p WHERE p.id = :id;
            """,
            ["id": .int(photoID)]
        ) { row in
            (
                storage: PhotoStorage(rawValue: try row.string("storage")) ?? .materialized,
                cachePath: try row.optionalString("cache_path"),
                externalID: try row.string("external_id"),
                available: try row.bool("available"),
                sourceID: try row.int64("source_id")
            )
        }
        guard let row, row.available else { return nil }

        switch row.storage {
        case .materialized:
            guard let cachePath = row.cachePath else { return nil }
            let url = root.appending(path: cachePath)
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
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
        /// Materialized photos with bytes on disk. This is what the cap governs.
        public let residentCount: Int
        /// Photos referenced in place. Not copied, not capped, free.
        public let referencedCount: Int
        /// Materialized photos still waiting for their bytes.
        public let pendingCount: Int
        public let bytesOnDisk: Int64
        public let cap: Int
        public let freeBytesOnVolume: Int64
        /// Cards in outstanding hands that have no bytes yet — the work the
        /// prefetcher owes the consumers right now.
        public let outstandingWithoutBytes: Int
    }

    public func status() throws -> Status {
        let counts = try database.first(
            """
            SELECT
              SUM(CASE WHEN storage = 'materialized' AND cache_path IS NOT NULL THEN 1 ELSE 0 END) AS resident,
              SUM(CASE WHEN storage = 'referenced' AND available = 1 THEN 1 ELSE 0 END)            AS referenced,
              SUM(CASE WHEN storage = 'materialized' AND cache_path IS NULL
                        AND available = 1 THEN 1 ELSE 0 END)                                      AS pending,
              IFNULL(SUM(CASE WHEN cache_path IS NOT NULL THEN byte_size ELSE 0 END), 0)          AS bytes
              FROM photo;
            """
        ) { row in
            (
                resident: try row.optionalInt("resident") ?? 0,
                referenced: try row.optionalInt("referenced") ?? 0,
                pending: try row.optionalInt("pending") ?? 0,
                bytes: try row.optionalInt64("bytes") ?? 0
            )
        }

        let outstanding =
            try database.scalarInt(
                """
                SELECT COUNT(*) FROM hand h JOIN photo p ON p.id = h.photo_id
                 WHERE h.played_at IS NULL AND p.storage = 'materialized' AND p.cache_path IS NULL;
                """
            ) ?? 0

        return Status(
            residentCount: counts?.resident ?? 0,
            referencedCount: counts?.referenced ?? 0,
            pendingCount: counts?.pending ?? 0,
            bytesOnDisk: counts?.bytes ?? 0,
            cap: settings.photoCap,
            freeBytesOnVolume: freeBytesOnVolume(),
            outstandingWithoutBytes: outstanding
        )
    }

    func freeBytesOnVolume() -> Int64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    // MARK: - Filling

    public enum ChunkOutcome: Sendable, Equatable {
        case materialized(count: Int, bytes: Int64)
        /// Nothing wanted bytes. The steady state.
        case nothingToDo
        /// The cap is full and everything resident is either newer or pinned.
        case capReached
        /// Free space fell below the floor. The deck stops growing rather than
        /// the volume filling.
        case pausedForDiskSpace(freeBytes: Int64)
    }

    /// Materializes one chunk, in the order the photos are actually needed.
    ///
    /// The queue is not a guess. Reserved hands *are* the answer to "what is
    /// needed soon", explicitly — so unplayed cards come first, in position
    /// order, and everything after that follows deck order. Because
    /// materialization follows deck order, oldest-materialized is also
    /// longest-since-dealt, which is what makes plain FIFO eviction correct.
    @discardableResult
    public func fillNextChunk(size: Int? = nil, now: Date = Date()) async throws -> ChunkOutcome {
        // Checked before every chunk, which is one of the reasons chunks exist.
        let free = freeBytesOnVolume()
        guard free >= settings.minimumFreeBytes else {
            Log.cache.notice(
                "pausing materialization: \(free, privacy: .public) bytes free, floor is \(settings.minimumFreeBytes, privacy: .public)"
            )
            return .pausedForDiskSpace(freeBytes: free)
        }

        let resident = try database.scalarInt(
            "SELECT COUNT(*) FROM photo WHERE storage = 'materialized' AND cache_path IS NOT NULL;"
        ) ?? 0
        guard resident < settings.photoCap else { return .capReached }

        let wanted = min(size ?? settings.chunkSize, settings.photoCap - resident)
        let queue = try materializationQueue(limit: wanted)
        guard !queue.isEmpty else { return .nothingToDo }

        let interval = Log.signposter.beginInterval("materialize")
        defer { Log.signposter.endInterval("materialize", interval) }

        var materialized = 0
        var bytes: Int64 = 0
        for item in queue {
            do {
                let file = try await materialize(item, now: now)
                materialized += 1
                bytes += file.byteSize
            } catch let error as SourceProviderError {
                // The file is gone. Mark it on the spot rather than retrying it
                // on every chunk for ever.
                Log.cache.notice(
                    "photo \(item.photoID, privacy: .public) could not be materialized: \(String(describing: error), privacy: .public)"
                )
                try deck.markUnavailable(photoID: item.photoID, reason: "missing at materialization")
            }
        }

        if materialized > 0 {
            Log.cache.info(
                "materialized \(materialized, privacy: .public) photos, \(bytes, privacy: .public) bytes"
            )
        }
        return .materialized(count: materialized, bytes: bytes)
    }

    /// Fills the opening burst, then keeps going in chunks until the cap, the
    /// disk floor, or nothing left to do stops it.
    ///
    /// The host decides the priority this runs at; the kit has no opinion about
    /// when it is called.
    @discardableResult
    public func fill(maximumChunks: Int = .max, now: Date = Date()) async throws -> ChunkOutcome {
        var totalCount = 0
        var totalBytes: Int64 = 0
        var chunks = 0
        while chunks < maximumChunks, !Task.isCancelled {
            let size = chunks == 0 ? settings.burstSize : settings.chunkSize
            let outcome = try await fillNextChunk(size: size, now: now)
            chunks += 1
            switch outcome {
            case .materialized(let count, let bytes):
                totalCount += count
                totalBytes += bytes
                if count == 0 { return .nothingToDo }
            case .nothingToDo, .capReached, .pausedForDiskSpace:
                return totalCount > 0 ? .materialized(count: totalCount, bytes: totalBytes) : outcome
            }
        }
        return .materialized(count: totalCount, bytes: totalBytes)
    }

    struct QueueItem: Sendable {
        let photoID: Int64
        let sourceID: Int64
        let externalID: String
    }

    /// Unplayed cards first, in the order they will be shown; then deck order.
    ///
    /// Photos whose *source* is unavailable are skipped entirely, so an orphan
    /// is never re-materialized and never produces a storm of failures.
    func materializationQueue(limit: Int) throws -> [QueueItem] {
        guard limit > 0 else { return [] }
        var items = try database.all(Self.outstandingQueueSQL, ["limit": .int(Int64(limit))]) {
            QueueItem(
                photoID: try $0.int64("id"),
                sourceID: try $0.int64("source_id"),
                externalID: try $0.string("external_id")
            )
        }
        guard items.count < limit else { return items }

        let seen = Set(items.map(\.photoID))
        let rest = try database.all(
            Self.deckOrderQueueSQL, ["limit": .int(Int64(limit - items.count))]
        ) {
            QueueItem(
                photoID: try $0.int64("id"),
                sourceID: try $0.int64("source_id"),
                externalID: try $0.string("external_id")
            )
        }
        items.append(contentsOf: rest.filter { !seen.contains($0.photoID) })
        return items
    }

    private func materialize(_ item: QueueItem, now: Date) async throws -> MaterializedFile {
        guard let source = try sources.source(id: item.sourceID),
            let provider = sources.provider(for: source.kind)
        else {
            throw SourceProviderError.notMaterializable(externalID: item.externalID)
        }

        let relative = Self.relativePath(
            sourceID: item.sourceID, photoID: item.photoID, externalID: item.externalID
        )
        let destination = root.appending(path: relative)
        let file = try await provider.materialize(
            externalID: item.externalID, from: source, to: destination
        )

        try database.run(
            """
            UPDATE photo
               SET cache_path = :path, byte_size = :size, materialized_at = :now
             WHERE id = :id;
            """,
            [
                "path": .text(relative),
                "size": .int(file.byteSize),
                "now": SQLValue(now),
                "id": .int(item.photoID),
            ]
        )
        return file
    }

    // MARK: - Eviction

    public struct EvictionResult: Sendable, Equatable {
        public let evicted: Int
        public let bytesFreed: Int64
        /// Cards that were over the cap but held in an outstanding hand, and so
        /// left alone.
        public let protectedFromEviction: Int
    }

    /// FIFO by materialization time, with two guards.
    ///
    /// Plain FIFO is correct here rather than something cleverer because
    /// materialization happens *in deck order*: the order photos enter the cache
    /// is the order they will be dealt, so oldest-added is also
    /// longest-since-dealt. The cache is a sliding window over the deck —
    /// expiring off the front, filling at the back.
    @discardableResult
    public func evictIfNeeded() throws -> EvictionResult {
        let protectedIDs = try deck.outstandingPhotoIDs()
        var evicted = 0
        var freed: Int64 = 0
        var skipped = 0

        // The disk-space guard evicts ahead of the cap, so it is folded in as a
        // lower effective cap rather than as a second pass.
        let free = freeBytesOnVolume()
        let underPressure = free < settings.criticalFreeBytes
        if underPressure {
            Log.cache.notice(
                "evicting ahead of the cap: only \(free, privacy: .public) bytes free"
            )
        }

        let resident = try database.all(Self.residentSQL) { row in
            (
                id: try row.int64("id"),
                path: try row.string("cache_path"),
                bytes: try row.optionalInt64("byte_size") ?? 0
            )
        }

        var count = resident.count
        var bytes = resident.reduce(Int64(0)) { $0 + $1.bytes }
        let targetCount = underPressure ? max(0, settings.photoCap / 2) : settings.photoCap

        for entry in resident {
            let overCount = count > targetCount
            let overBytes = bytes > settings.byteCeiling
            guard overCount || overBytes else { break }

            // Never evict a card in an outstanding hand, whatever its age.
            // Without this a fast consumer could evict a photo moments before
            // requesting it.
            guard !protectedIDs.contains(entry.id) else {
                skipped += 1
                continue
            }

            try remove(photoID: entry.id, relativePath: entry.path)
            evicted += 1
            freed += entry.bytes
            count -= 1
            bytes -= entry.bytes
        }

        if evicted > 0 {
            Log.cache.info(
                "evicted \(evicted, privacy: .public) photos, freed \(freed, privacy: .public) bytes"
            )
        }
        return EvictionResult(evicted: evicted, bytesFreed: freed, protectedFromEviction: skipped)
    }

    private func remove(photoID: Int64, relativePath: String) throws {
        try? FileManager.default.removeItem(at: root.appending(path: relativePath))
        try database.run(
            "UPDATE photo SET cache_path = NULL, materialized_at = NULL WHERE id = :id;",
            ["id": .int(photoID)]
        )
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
        let row = try database.first(
            """
            SELECT
              SUM(CASE WHEN p.cache_path IS NOT NULL THEN 1 ELSE 0 END)               AS refetch,
              IFNULL(SUM(CASE WHEN p.cache_path IS NOT NULL THEN p.byte_size ELSE 0 END), 0) AS bytes,
              SUM(CASE WHEN p.storage = 'referenced' THEN 1 ELSE 0 END)               AS referenced
              FROM photo p JOIN source s ON s.id = p.source_id
             WHERE \(predicate);
            """,
            bindings
        ) { row in
            (
                refetch: try row.optionalInt("refetch") ?? 0,
                bytes: try row.optionalInt64("bytes") ?? 0,
                referenced: try row.optionalInt("referenced") ?? 0
            )
        }
        return ClearCost(
            needingRefetch: row?.refetch ?? 0,
            bytesFreed: row?.bytes ?? 0,
            referencedAndFree: row?.referenced ?? 0,
            costsNothingToRefetch: scope == .unavailableSources
        )
    }

    public struct ClearResult: Sendable, Equatable {
        public let cleared: Int
        public let bytesFreed: Int64
        public let handsReturned: Int
    }

    /// Discards bytes. Never shuffle state.
    ///
    /// Deal ordinals, shuffle keys, and last-shown times are untouched, so a
    /// cleared cache refills into the same rotation rather than reshuffling the
    /// library. Clearing is a storage operation, never a shuffle operation.
    @discardableResult
    public func clear(_ scope: ClearScope) throws -> ClearResult {
        let cost = try costOfClearing(scope)
        let (predicate, bindings) = Self.scopePredicate(scope)

        let paths = try database.all(
            """
            SELECT p.id, p.cache_path FROM photo p JOIN source s ON s.id = p.source_id
             WHERE \(predicate) AND p.cache_path IS NOT NULL;
            """,
            bindings
        ) { (try $0.int64("id"), try $0.string("cache_path")) }

        // One directory removal instead of a thousand unlinks, which is the
        // whole reason the cache has a level of structure at all.
        if case .source(let sourceID) = scope {
            try? FileManager.default.removeItem(at: root.appending(path: "\(sourceID)"))
        } else if scope == .everything {
            try? FileManager.default.removeItem(at: root)
            try prepare()
        }

        try database.transaction(.immediate) {
            for (photoID, path) in paths {
                if case .unavailableSources = scope {
                    try? FileManager.default.removeItem(at: root.appending(path: path))
                }
                try database.run(
                    "UPDATE photo SET cache_path = NULL, materialized_at = NULL WHERE id = :id;",
                    ["id": .int(photoID)]
                )
            }
        }

        // Outstanding hands hold cards whose bytes no longer exist, so they go
        // back to the deck. Recovery is then the cold-start path, which already
        // exists.
        var handsReturned = 0
        if scope == .everything {
            try database.transaction(.immediate) {
                try database.run("DELETE FROM hand WHERE played_at IS NULL;")
                handsReturned = database.changes
            }
        }

        Log.cache.notice(
            "cleared \(paths.count, privacy: .public) cached photos, freeing \(cost.bytesFreed, privacy: .public) bytes"
        )
        return ClearResult(
            cleared: paths.count, bytesFreed: cost.bytesFreed, handsReturned: handsReturned
        )
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

    /// Cards somebody is about to show. Skips sources that are gone, so an
    /// orphan is never re-fetched.
    private static let outstandingQueueSQL = """
        SELECT p.id, p.source_id, p.external_id
          FROM hand h
          JOIN photo p ON p.id = h.photo_id
          JOIN source s ON s.id = p.source_id
         WHERE h.played_at IS NULL
           AND p.storage = 'materialized'
           AND p.cache_path IS NULL
           AND p.available = 1
           AND s.available = 1
         ORDER BY h.consumer_id, h.position
         LIMIT :limit;
        """

    /// Everything else, in deck order — which is what makes FIFO eviction the
    /// right policy downstream.
    private static let deckOrderQueueSQL = """
        SELECT p.id, p.source_id, p.external_id
          FROM photo p
          JOIN source s ON s.id = p.source_id
         WHERE p.source_enabled = 1
           AND p.available = 1
           AND p.media_type = 'image'
           AND p.storage = 'materialized'
           AND p.cache_path IS NULL
           AND s.available = 1
         ORDER BY p.shuffle_key
         LIMIT :limit;
        """

    private static let residentSQL = """
        SELECT id, cache_path, byte_size
          FROM photo
         WHERE storage = 'materialized' AND cache_path IS NOT NULL
         ORDER BY materialized_at, id;
        """
}
