import Foundation
import PhotoGoRoundAgentAPI

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

    /// One page of a source's entries, ordered by row id, starting after `after`.
    ///
    /// Paged rather than whole because the pool is the one thing in this system
    /// that is as large as the user's library, and **nothing outside the queue is
    /// ever held in memory**. Loading a source's contents into a dictionary — as
    /// the diff-based refresh used to — cost about 7 KB per photo and would have
    /// been most of a gigabyte on a hundred-thousand-photo library.
    ///
    /// Ordering by `id` and resuming after the last one seen means a page is a
    /// cursor rather than an offset, so rows deleted mid-walk cannot make the
    /// walk skip anything.
    public func page(
        ofSource sourceID: Int64,
        after: Int64 = 0,
        limit: Int = PhotoPool.batchSize
    ) throws -> [Entry] {
        try database.all(
            """
            SELECT id, uuid, external_id, storage, byte_size
              FROM photo
             WHERE source_id = :id AND id > :after
             ORDER BY id
             LIMIT :limit;
            """,
            ["id": .int(sourceID), "after": .int(after), "limit": .int(Int64(limit))]
        ) { row in
            Entry(
                id: try row.int64("id"),
                uuid: try row.string("uuid"),
                externalID: try row.string("external_id"),
                storage: PhotoStorage(rawValue: try row.string("storage")) ?? .materialized,
                byteSize: try row.optionalInt64("byte_size")
            )
        }
    }

    public struct Entry: Sendable, Equatable {
        public let id: Int64
        /// Durable identity, and what the cache's filenames carry.
        public let uuid: String
        public let externalID: String
        public let storage: PhotoStorage
        public let byteSize: Int64?
    }

    /// The same upsert, for a caller that is already `async`.
    ///
    /// **This is the write that holds SQLite's writer longest.** A scan of a
    /// network folder inserts thousands of rows, five hundred to a transaction,
    /// for as long as the walk takes — thirty-nine seconds for one source on
    /// 2026-08-25. Done through the synchronous form from an async task, every
    /// contended batch parks a cooperative-pool thread, and four concurrent
    /// walks are enough to leave nothing for serving to run on: eight picture
    /// requests went unanswered across ninety-two seconds, returning neither a
    /// photograph nor a `204`.
    ///
    /// Awaiting between batches also gives the rest of the process a turn, which
    /// the synchronous loop never did.
    @discardableResult
    public func upsert(
        _ photos: [DiscoveredPhoto],
        to source: Source,
        at now: Date = Date(),
        isolation: isolated (any Actor)? = #isolation,
        onAdded: ((DiscoveredPhoto) -> Void)? = nil
    ) async throws -> (added: Int, updated: Int) {
        var added = 0
        var updated = 0
        for batch in photos.chunked(into: Self.batchSize) {
            let counts = try await database.transaction(.immediate) {
                try applyUpsert(batch, to: source, at: now, onAdded: onAdded)
            }
            added += counts.added
            updated += counts.updated
        }
        return (added, updated)
    }

    /// The same removal, for a caller that is already `async`.
    @discardableResult
    public func remove(
        _ photoIDs: [Int64],
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Removal {
        guard !photoIDs.isEmpty else { return .none }
        var removed = 0
        var orphaned: [String] = []
        for batch in photoIDs.chunked(into: Self.batchSize) {
            let batchResult = try await database.transaction(.immediate) {
                try applyRemoval(batch)
            }
            removed += batchResult.removed
            orphaned.append(contentsOf: batchResult.orphaned)
        }
        if removed > 0 {
            Log.sources.notice("removed \(removed, privacy: .public) entries from the pool")
        }
        return Removal(count: removed, orphaned: orphaned)
    }

    /// What makes two rows the same photograph, whichever source found them.
    ///
    /// **File-backed kinds resolve to the absolute path; everything else is
    /// already globally unique.** A `PHAsset.localIdentifier` names one asset
    /// in one library no matter how many collections contain it, and a Google
    /// media item id is the same kind of thing. Only files need assembling,
    /// because `external_id` is stored relative to the source that found them
    /// and the same file under two overlapping folders is stored twice under
    /// two different relative paths.
    ///
    /// **A file source's locator is the photograph**, which is why it does not
    /// join anything — `FileAccess.withPhotoURL` takes the same branch, and the
    /// two must agree or one file added twice, once on its own and once inside
    /// a folder, would be two rows.
    ///
    /// `SchemaV9` states this rule a second time, in SQL, to backfill rows that
    /// predate the column. `MigrationTests` holds the two against each other,
    /// because nothing else would notice them drifting apart.
    static func identity(of externalID: String, in source: Source) -> String {
        if source.kind == .file { return source.locator }
        // The trailing slash is applied in `SourceSpec.init`, so this is a
        // join and not a guess.
        if source.kind == .folder { return source.locator + externalID }
        return externalID
    }

    /// Rows per write transaction. Large enough that a fifty-thousand-photo
    /// folder is not fifty thousand transactions, small enough that it never
    /// holds the single writer lock long enough for a consumer to notice.
    public static let batchSize = 500

    /// Inserts what is new and updates what changed, one batch at a time.
    ///
    /// Two statements rather than an upsert, because the caller needs to know
    /// which photos were *new* — that is what gets reported as a change — and
    /// `changes()` cannot tell an insert from a conflict-update. The second
    /// statement only runs when the first found the row already there.
    ///
    /// `onAdded` fires per new photo so the caller can report it without
    /// collecting a list. Nothing here retains a photo past its batch.
    @discardableResult
    public func upsert(
        _ photos: [DiscoveredPhoto],
        to source: Source,
        at now: Date = Date(),
        onAdded: ((DiscoveredPhoto) -> Void)? = nil
    ) throws -> (added: Int, updated: Int) {
        var added = 0
        var updated = 0
        for batch in photos.chunked(into: Self.batchSize) {
            let counts = try database.transaction(.immediate) {
                try applyUpsert(batch, to: source, at: now, onAdded: onAdded)
            }
            added += counts.added
            updated += counts.updated
        }
        return (added, updated)
    }

    /// One batch, assumed to be inside a transaction already — which is what
    /// lets the synchronous and `async` forms above differ in nothing but how
    /// they wait for the writer.
    private func applyUpsert(
        _ batch: ArraySlice<DiscoveredPhoto>,
        to source: Source,
        at now: Date,
        onAdded: ((DiscoveredPhoto) -> Void)?
    ) throws -> (added: Int, updated: Int) {
        var added = 0
        var updated = 0
        for photo in batch {
            try database.run(
                """
                INSERT OR IGNORE INTO photo
                    (uuid, source_id, external_id, identity, media_type, source_enabled,
                     storage, byte_size, shuffle_key, added_at)
                VALUES (:uuid, :source, :external, :identity, :media, :enabled,
                        :storage, :size, :key, :now);
                """,
                [
                    // Durable identity, generated here because it is what
                    // the cache's filenames carry and the row id is not
                    // stable across a rebuilt database.
                    "uuid": .text(UUID().uuidString.lowercased()),
                    "source": .int(source.id),
                    "external": .text(photo.externalID),
                    // The second `OR IGNORE` this statement can hit, and the
                    // one that matters here: the row is already present from
                    // *another* source. It stays that source's, and this scan
                    // moves on. See `SchemaV9`.
                    "identity": .text(Self.identity(of: photo.externalID, in: source)),
                    "media": .text(photo.mediaType.rawValue),
                    "enabled": SQLValue(source.enabled),
                    "storage": .text(photo.storage.rawValue),
                    "size": SQLValue(photo.byteSize),
                    "key": .double(Double.random(in: 0..<1)),
                    "now": SQLValue(now),
                ]
            )
            if database.changes == 1 {
                added += 1
                onAdded?(photo)
                continue
            }

            // Already known. Update only if something we track moved,
            // so an unchanged library does not dirty a page per photo
            // per scan. `IS NOT` rather than `<>` because byte_size is
            // nullable and `NULL <> NULL` is null, not true.
            try database.run(
                """
                UPDATE photo
                   SET storage = :storage, byte_size = :size
                 WHERE source_id = :source AND external_id = :external
                   AND (storage <> :storage OR byte_size IS NOT :size);
                """,
                [
                    "source": .int(source.id),
                    "external": .text(photo.externalID),
                    "storage": .text(photo.storage.rawValue),
                    "size": SQLValue(photo.byteSize),
                ]
            )
            updated += database.changes
        }
        return (added, updated)
    }

    /// What a removal left behind for someone else to clean up.
    public struct Removal: Sendable, Equatable {
        public let count: Int
        /// The identities of the photographs that went. The pool has no idea
        /// where the cache root is, so it reports these rather than deleting
        /// anything; whoever owns the bytes discards them by identity.
        public let orphaned: [String]

        public static let none = Removal(count: 0, orphaned: [])
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
            let result = try database.transaction(.immediate) { try applyRemoval(batch) }
            removed += result.removed
            orphaned.append(contentsOf: result.orphaned)
        }
        if removed > 0 {
            Log.sources.notice("removed \(removed, privacy: .public) entries from the pool")
        }
        return Removal(count: removed, orphaned: orphaned)
    }

    /// One batch, assumed to be inside a transaction already.
    private func applyRemoval(_ batch: ArraySlice<Int64>) throws -> (removed: Int, orphaned: [String]) {
        var removed = 0
        var orphaned: [String] = []
        do {
                for id in batch {
                    // Read the path before the row goes, or there is no way to
                    // find the bytes afterwards.
                    //
                    // The closure is parenthesized rather than trailing: inside
                    // an `if` condition a trailing closure reads as the body of
                    // the statement, and the compiler says so.
                    //
                    // Doubly optional because the query may match no row and the
                    // column itself is nullable — a referenced photo has no
                    // cache path. Both mean "nothing to delete", so they flatten.
                    if let uuid = try database.first(
                        "SELECT uuid FROM photo WHERE id = :id;", ["id": .int(id)],
                        { try $0.string("uuid") }
                    ) {
                        orphaned.append(uuid)
                    }
                    try database.run("DELETE FROM photo WHERE id = :id;", ["id": .int(id)])
                    removed += database.changes
                }
        }
        return (removed, orphaned)
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

    /// What one source contributes, broken down the way the questions are
    /// actually asked: how much of it is dealable, how much of it has bytes, and
    /// how much of it somebody is fetching right now.
    ///
    /// Exposed rather than left to a caller's own SQL, because a harness that
    /// reaches past the interface tests nothing — and because Phase 3's deck
    /// inspector wants exactly this.
    public struct SourceStats: Sendable, Equatable {
        public let total: Int
        public let images: Int
        public let videos: Int
        /// Referenced in place: no copy, no cache budget.
        public let referenced: Int
        /// Claimed by a producer that is fetching them. A handful is normal; a
        /// lot means producers are dying mid-fetch, and the claims will expire
        /// on their own either way.
        public let claimed: Int
    }

    public func stats(forSource sourceID: Int64) throws -> SourceStats {
        try database.first(
            """
            SELECT COUNT(*)                                                AS total,
                   SUM(CASE WHEN media_type = 'image' THEN 1 ELSE 0 END)   AS images,
                   SUM(CASE WHEN storage = 'referenced' THEN 1 ELSE 0 END) AS referenced,
                   SUM(CASE WHEN claimed_at IS NOT NULL THEN 1 ELSE 0 END) AS claimed
              FROM photo WHERE source_id = :id;
            """,
            ["id": .int(sourceID)]
        ) { row in
            let total = try row.int("total")
            let images = try row.optionalInt("images") ?? 0
            return SourceStats(
                total: total,
                images: images,
                videos: total - images,
                referenced: try row.optionalInt("referenced") ?? 0,
                claimed: try row.optionalInt("claimed") ?? 0
            )
        } ?? SourceStats(total: 0, images: 0, videos: 0, referenced: 0, claimed: 0)
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
