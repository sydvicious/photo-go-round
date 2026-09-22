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
    /// Where what is added and removed is counted, once each batch commits.
    /// The shared record everywhere; a test hands in its own.
    public let changes: LibraryChanges
    /// Where each batch's `REFRESH:` line goes. See `RefreshBatchTiming`.
    public var reportBatch: @Sendable (RefreshBatchTiming) -> Void = { $0.report() }

    public init(database: Database, changes: LibraryChanges = .shared) {
        self.database = database
        self.changes = changes
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
    /// **This is the write that held SQLite's writer longest.** A scan of a
    /// network folder writes for as long as the walk takes — thirty-nine seconds
    /// for one source on 2026-08-25. Done through the synchronous form from an
    /// async task, every contended page parks a cooperative-pool thread, and
    /// four concurrent walks were enough to leave nothing for serving to run on:
    /// eight picture requests went unanswered across ninety-two seconds,
    /// returning neither a photograph nor a `204`.
    ///
    /// Awaiting between pages also gives the rest of the process a turn, which
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
        for page in photos.chunked(into: Self.batchSize) {
            var timing = RefreshBatchTiming(work: .upsert, rows: page.count, source: source.id)
            let plan = try planUpsert(page, to: source, timing: &timing)
            var written = UpsertWrite()
            if !plan.isEmpty {
                timing.locked = true
                let asked = ContinuousClock.now
                var bodyEnded = asked
                written = try await database.transaction(.immediate) {
                    timing.waited = ContinuousClock.now - asked
                    let holding = ContinuousClock.now
                    defer {
                        bodyEnded = ContinuousClock.now
                        timing.held = bodyEnded - holding
                    }
                    return try applyUpsert(plan, to: source, at: now, timing: &timing)
                }
                timing.commit = ContinuousClock.now - bodyEnded
                timing.held += timing.commit
            }
            await finishUpsert(written, to: source, timing: &timing, onAdded: onAdded)
            added += written.added.count
            updated += written.updated
        }
        return (added, updated)
    }

    /// The same removal, for a caller that is already `async`.
    @discardableResult
    public func remove(
        _ photoIDs: [Int64],
        countingChanges: Bool = true,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Removal {
        guard !photoIDs.isEmpty else { return .none }
        var removal = Removal.none
        for page in photoIDs.chunked(into: Self.batchSize) {
            var timing = RefreshBatchTiming(work: .remove, rows: page.count, source: nil)
            let rows = try planRemoval(page, timing: &timing)
            var deleted: [RemovalRow] = []
            if !rows.isEmpty {
                timing.locked = true
                let asked = ContinuousClock.now
                var bodyEnded = asked
                deleted = try await database.transaction(.immediate) {
                    timing.waited = ContinuousClock.now - asked
                    let holding = ContinuousClock.now
                    defer {
                        bodyEnded = ContinuousClock.now
                        timing.held = bodyEnded - holding
                    }
                    return try applyRemoval(rows, timing: &timing)
                }
                timing.commit = ContinuousClock.now - bodyEnded
                timing.held += timing.commit
            }
            reportBatch(timing)
            await finishRemoval(deleted, into: &removal, countingChanges: countingChanges)
        }
        if removal.count > 0 {
            Log.sources.notice("removed \(removal.count, privacy: .public) entries from the pool")
        }
        return removal
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

    /// Rows per page: what one unlocked read decides, and one write lock covers.
    ///
    /// **100 since 2026-09-16; it was 500.** Syd: "long locks in the database
    /// are death", and "pages of 100". The probe that night measured 500-row
    /// batches holding the writer up to 1,114 ms while adding nothing, and on
    /// why pages at all: "I don't mind building large lists in memory, doing a
    /// lock, and doing a large SQL command; however, doing this 100 at a time
    /// saves ram and keeps the database locks short". `Agent Performance
    /// Overhaul.md`, *The refresh locks only to write*.
    public static let batchSize = 100

    /// Inserts what is new and updates what changed, a page at a time.
    ///
    /// **Each page is read before it is written.** The lookups that decide what
    /// a page must write run with no lock, and the lock is taken only when they
    /// found something — so a refresh that finds its source as it left it takes
    /// no write lock for its photographs at all. Until 2026-09-16 every page
    /// took the lock and did its lookups inside it.
    ///
    /// Two statements rather than an upsert, because the caller needs to know
    /// which photos were *new* — that is what gets reported as a change — and
    /// `changes()` cannot tell an insert from a conflict-update.
    ///
    /// `onAdded` fires per new photo, after its page commits, so the caller can
    /// report it without collecting a list. Nothing here retains a photo past
    /// its page.
    @discardableResult
    public func upsert(
        _ photos: [DiscoveredPhoto],
        to source: Source,
        at now: Date = Date(),
        onAdded: ((DiscoveredPhoto) -> Void)? = nil
    ) async throws -> (added: Int, updated: Int) {
        var added = 0
        var updated = 0
        for page in photos.chunked(into: Self.batchSize) {
            var timing = RefreshBatchTiming(work: .upsert, rows: page.count, source: source.id)
            let plan = try planUpsert(page, to: source, timing: &timing)
            var written = UpsertWrite()
            if !plan.isEmpty {
                timing.locked = true
                let asked = ContinuousClock.now
                var bodyEnded = asked
                written = try await database.transaction(.immediate) {
                    timing.waited = ContinuousClock.now - asked
                    let holding = ContinuousClock.now
                    defer {
                        bodyEnded = ContinuousClock.now
                        timing.held = bodyEnded - holding
                    }
                    return try applyUpsert(plan, to: source, at: now, timing: &timing)
                }
                timing.commit = ContinuousClock.now - bodyEnded
                timing.held += timing.commit
            }
            await finishUpsert(written, to: source, timing: &timing, onAdded: onAdded)
            added += written.added.count
            updated += written.updated
        }
        return (added, updated)
    }

    /// What a page's lookups found it must write.
    struct UpsertPlan {
        var additions: [DiscoveredPhoto] = []
        var changes: [DiscoveredPhoto] = []
        var isEmpty: Bool { additions.isEmpty && changes.isEmpty }
    }

    /// What a page's write did.
    struct UpsertWrite {
        var added: [DiscoveredPhoto] = []
        var updated = 0
    }

    /// Reads, with no lock, what a page must write: the photographs this source
    /// holds no row for, and those whose storage or size moved.
    ///
    /// A photograph another source already holds under the same identity is
    /// neither. It stays that source's, as `INSERT OR IGNORE` left it before
    /// (`SchemaV9`).
    private func planUpsert(
        _ page: ArraySlice<DiscoveredPhoto>, to source: Source, timing: inout RefreshBatchTiming
    ) throws -> UpsertPlan {
        let started = ContinuousClock.now
        defer { timing.lookups = ContinuousClock.now - started }
        var plan = UpsertPlan()
        for photo in page {
            let row = try database.first(
                "SELECT storage, byte_size FROM photo WHERE source_id = :source AND external_id = :external;",
                ["source": .int(source.id), "external": .text(photo.externalID)],
                { (storage: try $0.string("storage"), size: try $0.optionalInt64("byte_size")) }
            )
            if let row {
                if row.storage != photo.storage.rawValue || row.size != photo.byteSize {
                    plan.changes.append(photo)
                }
                continue
            }
            let elsewhere = try database.scalarInt(
                "SELECT COUNT(*) FROM photo WHERE identity = :identity;",
                ["identity": .text(Self.identity(of: photo.externalID, in: source))]) ?? 0
            if elsewhere == 0 { plan.additions.append(photo) }
        }
        return plan
    }

    /// A page's writes, inside a transaction already.
    ///
    /// **The statements keep their guards** — `INSERT OR IGNORE`, and the
    /// update's `WHERE` on what moved — so a row another writer added or
    /// changed between the lookups and the lock is left as that writer made it,
    /// and the next refresh sees it as it is.
    private func applyUpsert(
        _ plan: UpsertPlan, to source: Source, at now: Date, timing: inout RefreshBatchTiming
    ) throws -> UpsertWrite {
        var written = UpsertWrite()
        let inserting = ContinuousClock.now
        for photo in plan.additions {
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
                    // The row may have arrived from *another* source since
                    // the lookups. It stays that source's. See `SchemaV9`.
                    "identity": .text(Self.identity(of: photo.externalID, in: source)),
                    "media": .text(photo.mediaType.rawValue),
                    "enabled": SQLValue(source.enabled),
                    "storage": .text(photo.storage.rawValue),
                    "size": SQLValue(photo.byteSize),
                    "key": .double(Double.random(in: 0..<1)),
                    "now": SQLValue(now),
                ]
            )
            if database.changes == 1 { written.added.append(photo) }
        }
        timing.inserts = ContinuousClock.now - inserting

        // `IS NOT` rather than `<>` because byte_size is nullable and
        // `NULL <> NULL` is null, not true.
        let updating = ContinuousClock.now
        for photo in plan.changes {
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
            written.updated += database.changes
        }
        timing.updates = ContinuousClock.now - updating
        return written
    }

    /// After a page's lock: the callbacks, the count, and the `REFRESH:` line.
    private func finishUpsert(
        _ written: UpsertWrite, to source: Source, timing: inout RefreshBatchTiming,
        onAdded: ((DiscoveredPhoto) -> Void)?
    ) async {
        let calling = ContinuousClock.now
        if let onAdded { for photo in written.added { onAdded(photo) } }
        timing.callbacks = ContinuousClock.now - calling
        timing.added = written.added.count
        timing.changed = written.updated
        reportBatch(timing)
        changes.added(written.added.count, toSource: source.id)
    }

    /// What a removal left behind for someone else to clean up.
    public struct Removal: Sendable, Equatable {
        public var count: Int
        /// The identities of the photographs that went. The pool has no idea
        /// where the cache root is, so it reports these rather than deleting
        /// anything; whoever owns the bytes discards them by identity.
        public var orphaned: [String]
        /// The files of the resized copies that went with them. Their rows
        /// cascade away with the photographs'; the files are read first, so
        /// whoever owns the bytes can delete those too. `PhotoStore.discard`.
        public var orphanedCopies: [String] = []

        public static let none = Removal(count: 0, orphaned: [])
    }

    /// Removes entries by row id, a page at a time.
    ///
    /// Queue entries for these photos cascade away, so removing from the pool
    /// takes them out of the queue in the same statement.
    ///
    /// **Each page is read before the lock**, like an upsert's: the identity,
    /// source and copies of each row, which are needed after it goes. A copy
    /// saved in the moment between is left as a file with no row, which the
    /// first eviction after the next launch clears.
    ///
    /// `countingChanges` is false for a whole source going, which is counted
    /// once as the source's (`LibraryChanges.sourceRemoved`).
    @discardableResult
    public func remove(_ photoIDs: [Int64], countingChanges: Bool = true) async throws -> Removal {
        guard !photoIDs.isEmpty else { return .none }
        var removal = Removal.none
        for page in photoIDs.chunked(into: Self.batchSize) {
            var timing = RefreshBatchTiming(work: .remove, rows: page.count, source: nil)
            let rows = try planRemoval(page, timing: &timing)
            var deleted: [RemovalRow] = []
            if !rows.isEmpty {
                timing.locked = true
                let asked = ContinuousClock.now
                var bodyEnded = asked
                deleted = try await database.transaction(.immediate) {
                    timing.waited = ContinuousClock.now - asked
                    let holding = ContinuousClock.now
                    defer {
                        bodyEnded = ContinuousClock.now
                        timing.held = bodyEnded - holding
                    }
                    return try applyRemoval(rows, timing: &timing)
                }
                timing.commit = ContinuousClock.now - bodyEnded
                timing.held += timing.commit
            }
            reportBatch(timing)
            await finishRemoval(deleted, into: &removal, countingChanges: countingChanges)
        }
        if removal.count > 0 {
            Log.sources.notice("removed \(removal.count, privacy: .public) entries from the pool")
        }
        return removal
    }

    /// One row a removal page found, with what must be known before it goes.
    struct RemovalRow {
        let id: Int64
        /// How the bytes are found afterwards.
        let uuid: String
        /// What the removal is counted against.
        let source: Int64
        /// Its resized copies' files; their rows cascade with it.
        let copies: [String]
    }

    /// Reads, with no lock, the rows of a page that are still there.
    private func planRemoval(
        _ page: ArraySlice<Int64>, timing: inout RefreshBatchTiming
    ) throws -> [RemovalRow] {
        let started = ContinuousClock.now
        defer { timing.lookups = ContinuousClock.now - started }
        var rows: [RemovalRow] = []
        for id in page {
            // The closure is parenthesized rather than trailing, so the call
            // reads the same wherever it is moved to.
            guard
                let row = try database.first(
                    "SELECT uuid, source_id FROM photo WHERE id = :id;", ["id": .int(id)],
                    { (uuid: try $0.string("uuid"), source: try $0.int64("source_id")) }
                )
            else { continue }
            rows.append(
                RemovalRow(
                    id: id, uuid: row.uuid, source: row.source,
                    copies: try ResizedCopies.files(ofPhotos: [id], in: database)))
        }
        return rows
    }

    /// A page's deletes, inside a transaction already. Answers the rows it
    /// deleted: one another writer took first is not this removal's.
    private func applyRemoval(
        _ rows: [RemovalRow], timing: inout RefreshBatchTiming
    ) throws -> [RemovalRow] {
        let deleting = ContinuousClock.now
        defer { timing.deletes = ContinuousClock.now - deleting }
        var deleted: [RemovalRow] = []
        for row in rows {
            try database.run("DELETE FROM photo WHERE id = :id;", ["id": .int(row.id)])
            if database.changes > 0 { deleted.append(row) }
        }
        return deleted
    }

    /// After a page's lock: what went, added to the removal so far.
    private func finishRemoval(
        _ deleted: [RemovalRow], into removal: inout Removal, countingChanges: Bool
    ) async {
        removal.count += deleted.count
        removal.orphaned += deleted.map(\.uuid)
        removal.orphanedCopies += deleted.flatMap(\.copies)
        guard countingChanges else { return }
        for (source, rows) in Dictionary(grouping: deleted, by: \.source) {
            changes.removed(rows.count, fromSource: source)
        }
    }

    @discardableResult
    public func remove(_ photoID: Int64) async throws -> Removal {
        try await remove([photoID])
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
