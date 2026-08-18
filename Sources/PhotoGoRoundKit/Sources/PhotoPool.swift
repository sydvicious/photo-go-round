import Foundation

/// The global pool: every photo the system knows about, from every source.
///
/// This is the seam between the two halves of the system. **Providers put
/// entries in and take entries out; the queue pulls from what is there and does
/// not care where any of it came from.** Neither side knows about the other,
/// which is what lets refresh run per-source and concurrently while the queue
/// carries on undisturbed.
///
/// Removal is a real delete rather than a flag. "Removed from the pool" means
/// removed: the row goes, and its queue entry cascades away with it. A file that comes back later is a new entry with no history, which is
/// exactly how it should behave — it competes immediately rather than resuming
/// a place in a rotation it was absent from.
public struct PhotoPool {
    public let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// What the pool already holds for a source, keyed by external identifier.
    /// The input to every diff.
    public func contents(ofSource sourceID: Int64) throws -> [String: Entry] {
        var entries: [String: Entry] = [:]
        try database.query(
            """
            SELECT id, external_id, storage, byte_size, cache_path
              FROM photo WHERE source_id = :id;
            """,
            ["id": .int(sourceID)]
        ) { row in
            entries[try row.string("external_id")] = Entry(
                id: try row.int64("id"),
                storage: PhotoStorage(rawValue: try row.string("storage")) ?? .materialized,
                byteSize: try row.optionalInt64("byte_size"),
                isCached: try row.optionalString("cache_path") != nil
            )
        }
        return entries
    }

    public struct Entry: Sendable, Equatable {
        public let id: Int64
        public let storage: PhotoStorage
        public let byteSize: Int64?
        /// For a materialized photo, whether its bytes have been fetched. For a
        /// referenced one this is meaningless — its cache entry *is* the pointer
        /// to the file, which exists as soon as the entry does.
        public let isCached: Bool
    }

    /// Rows per write transaction. Large enough that a fifty-thousand-photo
    /// folder is not fifty thousand transactions, small enough that it never
    /// holds the single writer lock long enough for a consumer to notice.
    public static let batchSize = 500

    /// Adds entries. New entries have a null deal ordinal and a fresh shuffle
    /// key, which makes them eligible immediately without being placed anywhere
    /// special.
    @discardableResult
    public func add(
        _ photos: [DiscoveredPhoto],
        to source: Source,
        at now: Date = Date()
    ) throws -> Int {
        var added = 0
        for batch in photos.chunked(into: Self.batchSize) {
            try database.transaction(.immediate) {
                for photo in batch {
                    try database.run(
                        """
                        INSERT OR IGNORE INTO photo
                            (source_id, external_id, media_type, source_enabled,
                             storage, byte_size, shuffle_key, added_at)
                        VALUES (:source, :external, :media, :enabled, :storage, :size, :key, :now);
                        """,
                        [
                            "source": .int(source.id),
                            "external": .text(photo.externalID),
                            "media": .text(photo.mediaType.rawValue),
                            "enabled": SQLValue(source.enabled),
                            "storage": .text(photo.storage.rawValue),
                            "size": SQLValue(photo.byteSize),
                            "key": .double(Double.random(in: 0..<1)),
                            "now": SQLValue(now),
                        ]
                    )
                    added += database.changes
                }
            }
        }
        return added
    }

    /// What a removal left behind for someone else to clean up.
    public struct Removal: Sendable, Equatable {
        public let count: Int
        /// Cache-relative paths whose entries no longer exist. The pool has no
        /// idea where the cache root is, so it reports these rather than
        /// deleting them; whoever owns the root deletes them at once, and
        /// `PhotoCache.sweepOrphans` catches anything missed.
        public let orphanedCachePaths: [String]

        public static let none = Removal(count: 0, orphanedCachePaths: [])
    }

    /// Removes entries by row id.
    ///
    /// Queue entries for these photos cascade away, so removing from the pool
    /// takes them out of the queue in the same statement.
    @discardableResult
    public func remove(_ photoIDs: [Int64]) throws -> Removal {
        guard !photoIDs.isEmpty else { return .none }
        var removed = 0
        var orphaned: [String] = []

        for batch in photoIDs.chunked(into: Self.batchSize) {
            try database.transaction(.immediate) {
                for id in batch {
                    // Read the path before the row goes, or there is no way to
                    // find the bytes afterwards.
                    if let path = try database.first(
                        "SELECT cache_path FROM photo WHERE id = :id;", ["id": .int(id)]
                    ) { try $0.optionalString("cache_path") } ?? nil {
                        orphaned.append(path)
                    }
                    try database.run("DELETE FROM photo WHERE id = :id;", ["id": .int(id)])
                    removed += database.changes
                }
            }
        }
        if removed > 0 {
            Log.sources.notice("removed \(removed, privacy: .public) entries from the pool")
        }
        return Removal(count: removed, orphanedCachePaths: orphaned)
    }

    @discardableResult
    public func remove(_ photoID: Int64) throws -> Removal {
        try remove([photoID])
    }

    /// Updates what we know about an entry without disturbing its place in the
    /// rotation — a file whose size changed, or that moved between volumes and
    /// so changed how it must be stored.
    public func refresh(
        _ photoID: Int64,
        storage: PhotoStorage,
        byteSize: Int64?
    ) throws {
        try database.run(
            "UPDATE photo SET storage = :storage, byte_size = :size WHERE id = :id;",
            ["storage": .text(storage.rawValue), "size": SQLValue(byteSize), "id": .int(photoID)]
        )
    }

    /// How many photos the pool holds, across every source.
    public func size() throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM photo;") ?? 0
    }

    /// How many one source contributes.
    public func size(forSource sourceID: Int64) throws -> Int {
        try database.scalarInt(
            "SELECT COUNT(*) FROM photo WHERE source_id = :source;",
            ["source": .int(sourceID)]
        ) ?? 0
    }

    /// How many photos the deck can actually draw on — enabled sources only.
    ///
    /// This is the number the queue has to compare itself against. A pool
    /// smaller than the queue's target means the queue can never fill, and a
    /// producer that does not know that will ask forever.
    public func dealableSize() throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM photo WHERE source_enabled = 1;") ?? 0
    }
}
