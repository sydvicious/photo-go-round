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

    private let sources: SourceStore
    private let deck: Deck

    public init(
        database: Database,
        root: URL,
        settings: CacheSettings = .default,
        sources: SourceStore,
        deck: Deck? = nil,
        queueSize: Int = 1000
    ) {
        self.database = database
        self.root = root
        self.settings = settings
        self.sources = sources
        self.deck = deck ?? Deck(database: database)
        self.queue = PhotoQueue(database: database, nominalSize: queueSize)
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
            SELECT p.storage, p.cache_path, p.external_id, p.source_id
              FROM photo p WHERE p.id = :id;
            """,
            ["id": .int(photoID)]
        ) { row in
            (
                storage: PhotoStorage(rawValue: try row.string("storage")) ?? .materialized,
                cachePath: try row.optionalString("cache_path"),
                externalID: try row.string("external_id"),
                sourceID: try row.int64("source_id")
            )
        }
        guard let row else { return nil }

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
        /// Pictures waiting in the queue, ready to show.
        public let queued: Int
    }

    public func status() throws -> Status {
        let counts = try database.first(
            """
            SELECT
              SUM(CASE WHEN storage = 'materialized' AND cache_path IS NOT NULL THEN 1 ELSE 0 END) AS resident,
              SUM(CASE WHEN storage = 'referenced' THEN 1 ELSE 0 END)                              AS referenced,
              SUM(CASE WHEN storage = 'materialized' AND cache_path IS NULL THEN 1 ELSE 0 END)    AS pending,
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

        let queued = try queue.size()

        return Status(
            residentCount: counts?.resident ?? 0,
            referencedCount: counts?.referenced ?? 0,
            pendingCount: counts?.pending ?? 0,
            bytesOnDisk: counts?.bytes ?? 0,
            cap: settings.photoCap,
            freeBytesOnVolume: freeBytesOnVolume(),
            queued: queued
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

        if candidate.storage == .materialized, candidate.cachePath == nil {
            let relative = Self.relativePath(
                sourceID: sourceID, photoID: candidate.id, externalID: candidate.externalID
            )
            do {
                let file = try await provider.materialize(
                    externalID: candidate.externalID,
                    from: source,
                    to: root.appending(path: relative)
                )
                try database.run(
                    """
                    UPDATE photo
                       SET cache_path = :path, byte_size = :size, materialized_at = :now
                     WHERE id = :id;
                    """,
                    [
                        "path": .text(relative), "size": .int(file.byteSize),
                        "now": SQLValue(now), "id": .int(candidate.id),
                    ]
                )
            } catch {
                try handleFailedDownload(candidate, source: source, error: error)
                return false
            }
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
                        id: card.id, sourceID: card.sourceID, externalID: card.externalID,
                        storage: card.storage, cachePath: card.cachePath, dealSeq: seq
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
        for path in removal.orphanedCachePaths {
            try? FileManager.default.removeItem(at: root.appending(path: path))
        }
        return removal
    }

    @discardableResult
    public func remove(_ photoID: Int64) throws -> PhotoPool.Removal {
        try remove([photoID])
    }

    /// Confirms every materialized entry's bytes are still on disk, and clears
    /// the ones that are not.
    ///
    /// The database's claim can go stale without anybody lying: a purge, a
    /// half-written entry from a run killed mid-copy, someone tidying a
    /// directory. Clearing `cache_path` puts the photo back in contention rather
    /// than leaving a queue entry that resolves to nothing.
    @discardableResult
    public func verifyResidency() throws -> Int {
        let claimed = try database.all(Self.residentSQL) {
            (id: try $0.int64("id"), path: try $0.string("cache_path"))
        }
        var cleared = 0
        for entry in claimed {
            let url = root.appending(path: entry.path)
            guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                continue
            }
            try database.run(
                "UPDATE photo SET cache_path = NULL, materialized_at = NULL WHERE id = :id;",
                ["id": .int(entry.id)]
            )
            try queue.remove(photoID: entry.id)
            cleared += 1
        }
        if cleared > 0 {
            Log.cache.notice(
                "\(cleared, privacy: .public) cache entries had lost their bytes"
            )
        }
        return cleared
    }

    /// Deletes cached bytes that no pool entry claims.
    ///
    /// Removing an entry deletes its row, which cascades to the queue but says
    /// nothing about the file on disk — and once the row is gone the evictor
    /// cannot see those bytes either, because it walks rows rather than the
    /// filesystem. Without this they would sit there for ever. It also cleans up
    /// after a crash between the copy and the row update.
    @discardableResult
    public func sweepOrphans() throws -> (files: Int, bytes: Int64) {
        var claimed = Set<String>()
        try database.query("SELECT cache_path FROM photo WHERE cache_path IS NOT NULL;") { row in
            claimed.insert(try row.string("cache_path"))
        }

        guard
            let directories = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            )
        else { return (0, 0) }

        var files = 0
        var bytes: Int64 = 0
        for directory in directories {
            let sourceComponent = directory.lastPathComponent
            guard Int64(sourceComponent) != nil else { continue }
            let contents =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.fileSizeKey]
                )) ?? []

            for file in contents {
                let relative = "\(sourceComponent)/\(file.lastPathComponent)"
                guard !claimed.contains(relative) else { continue }
                let size =
                    (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                try? FileManager.default.removeItem(at: file)
                files += 1
                bytes += size
            }

            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))?
                .isEmpty == true
            {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        if files > 0 {
            Log.cache.notice(
                "swept \(files, privacy: .public) orphaned cache files, freeing \(bytes, privacy: .public) bytes"
            )
        }
        return (files, bytes)
    }

    // MARK: - Eviction

    public struct EvictionResult: Sendable, Equatable {
        public let evicted: Int
        public let bytesFreed: Int64
        /// Pictures that were over the cap but sitting in the queue, and so left
        /// alone.
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
        let protectedIDs = try queuedPhotoIDs()
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

            // Never evict a picture that is in the queue, whatever its age — it
            // is about to be shown. Without this a fast consumer could evict a
            // photo moments before asking for it.
            guard !protectedIDs.contains(entry.id) else {
                skipped += 1
                continue
            }

            try evictEntry(photoID: entry.id, relativePath: entry.path)
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

    /// Pictures waiting in the queue, which the evictor must not touch whatever
    /// their age — they are about to be shown.
    func queuedPhotoIDs() throws -> Set<Int64> {
        Set(try database.all("SELECT photo_id FROM queue;") { try $0.int64("photo_id") })
    }

    private func evictEntry(photoID: Int64, relativePath: String) throws {
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
            "cleared \(paths.count, privacy: .public) cached photos, freeing \(cost.bytesFreed, privacy: .public) bytes"
        )
        return ClearResult(
            cleared: paths.count, bytesFreed: cost.bytesFreed, queueCleared: queueCleared
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

    private static let residentSQL = """
        SELECT id, cache_path, byte_size
          FROM photo
         WHERE storage = 'materialized' AND cache_path IS NOT NULL
         ORDER BY materialized_at, id;
        """
}
