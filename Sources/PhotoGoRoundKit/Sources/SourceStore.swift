import Foundation

/// One photo entering or leaving the pool during a refresh, reported as it
/// happens. The counts in `ScanResult` are what the agent acts on; this is what
/// a person watching a folder wants to see.
public enum ScanChange: Sendable, Equatable {
    case added(externalID: String)
    case removed(externalID: String)

    public var externalID: String {
        switch self {
        case .added(let id), .removed(let id): id
        }
    }
}

/// What a refresh changed.
public struct ScanResult: Sendable, Equatable {
    public let sourceID: Int64
    public let added: Int
    public let removed: Int
    public let unchanged: Int
    /// True when the source itself could not be reached, in which case nothing
    /// was removed from the pool at all.
    public let sourceUnavailable: Bool
    public let reason: String?
    /// Cached bytes deleted along with the rows, because a photograph that has
    /// left its source is not coming back and its bytes are not worth keeping.
    ///
    /// This used to be a list of orphaned paths handed to *whoever owned the
    /// cache root*, on the reasoning that the store did not know where that was.
    /// Nothing ever consumed it, so every photograph that left a source kept its
    /// bytes until the next launch rebuilt the index. The store now holds the
    /// byte index itself and deletes them here, and this number is what it
    /// freed — visible rather than assumed, so a caller that forgot to hand one
    /// over reports zero instead of quietly leaking.
    public let bytesFreed: Int64

    public init(
        sourceID: Int64, added: Int, removed: Int, unchanged: Int,
        sourceUnavailable: Bool, reason: String?, bytesFreed: Int64 = 0
    ) {
        self.sourceID = sourceID
        self.added = added
        self.removed = removed
        self.unchanged = unchanged
        self.sourceUnavailable = sourceUnavailable
        self.reason = reason
        self.bytesFreed = bytesFreed
    }

    public var isEmpty: Bool { added == 0 && removed == 0 }
}

/// Adding, listing, enabling, and refreshing sources.
///
/// A refresh is per source and self-contained: it enumerates one provider, diffs
/// the result against the pool, and puts entries in or takes them out. It never
/// touches the queue, and nothing about it assumes it is the only one running.
/// The host decides how many run at once.
public struct SourceStore {
    public let database: Database
    /// The seam every file read goes through. Exposed so that anything else
    /// needing a URL for a photo — the cache, a display layer — resolves it the
    /// same way rather than reaching for a path.
    public let fileAccess: any FileAccess
    /// Add and remove entries. The queue pulls from this and does not care who
    /// filled it.
    public let pool: PhotoPool
    /// What is on disk, so that removing a photograph's row can remove its bytes
    /// in the same breath.
    ///
    /// **A row without its bytes is a leak.** Whenever a photograph leaves a
    /// source — the source removed, recursion switched off, the file deleted
    /// under us — the pool loses the row and nothing was left pointing at the
    /// cached original and its renderings. They used to survive until the next
    /// launch rebuilt the index from the filesystem and discarded what nothing
    /// claimed, which is a long time to hold a library's worth of bytes.
    ///
    /// Optional because plenty of callers only ever *read* sources — the picture
    /// endpoint, the statistical rig — and a byte index they never use should
    /// not be a construction cost. Every path that removes reports what it
    /// freed, so a caller that removes without one is visible rather than
    /// silent.
    public let bytes: PhotoStore?

    private let providers: [SourceKind: any SourceProvider]

    public init(
        database: Database,
        fileAccess: any FileAccess = UnsandboxedFileAccess(),
        providers: [any SourceProvider],
        bytes: PhotoStore? = nil
    ) {
        self.database = database
        self.fileAccess = fileAccess
        self.pool = PhotoPool(database: database)
        self.bytes = bytes
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.kind, $0) })
    }

    /// The providers Phase 1 ships with: files on disk, and nothing else.
    public init(
        database: Database,
        fileAccess: any FileAccess = UnsandboxedFileAccess(),
        bytes: PhotoStore? = nil
    ) {
        self.init(
            database: database,
            fileAccess: fileAccess,
            providers: [
                FolderSourceProvider(fileAccess: fileAccess),
                FileSourceProvider(fileAccess: fileAccess),
            ],
            bytes: bytes
        )
    }

    public func provider(for kind: SourceKind) -> (any SourceProvider)? {
        providers[kind]
    }

    // MARK: - Managing sources

    @discardableResult
    public func add(
        kind: SourceKind,
        locator: String,
        recursive: Bool? = nil,
        bookmark: Data? = nil,
        stampUUID: String? = nil,
        now: Date = Date()
    ) throws -> Source {
        try database.transaction(.immediate) {
            try database.run(
                """
                INSERT INTO source (uuid, kind, locator, bookmark, stamp_uuid, enabled, recursive, added_at)
                VALUES (:uuid, :kind, :locator, :bookmark, :stamp, 1, :recursive, :now);
                """,
                [
                    "uuid": .text(UUID().uuidString.lowercased()),
                    "kind": .text(kind.rawValue),
                    "locator": .text(locator),
                    "bookmark": bookmark.map { SQLValue.blob($0) } ?? .null,
                    "stamp": SQLValue(stampUUID),
                    "recursive": recursive.map { SQLValue($0) } ?? .null,
                    "now": SQLValue(now),
                ]
            )
            let id = database.lastInsertRowID
            Log.sources.notice(
                "added \(kind.rawValue, privacy: .public) source \(id, privacy: .public)"
            )
            return try source(id: id)!
        }
    }

    public func source(id: Int64) throws -> Source? {
        try database.first(Self.selectSourceSQL + " WHERE id = :id;", ["id": .int(id)]) {
            try Source(row: $0)
        }
    }

    /// The one a client named.
    ///
    /// **`uuid` rather than `id`, because the row id is not stable**: the
    /// database is disposable and a rebuilt one renumbers sources from 1, while
    /// the UUID is minted once and is already what names a source's bytes in the
    /// cache. It is therefore what the service hands out and what it takes back.
    public func source(uuid: String) throws -> Source? {
        try database.first(
            Self.selectSourceSQL + " WHERE uuid = :uuid;", ["uuid": .text(uuid)]
        ) { try Source(row: $0) }
    }

    public func all() throws -> [Source] {
        try database.all(Self.selectSourceSQL + " ORDER BY id;") { try Source(row: $0) }
    }

    public func enabled() throws -> [Source] {
        try database.all(Self.selectSourceSQL + " WHERE enabled = 1 ORDER BY id;") {
            try Source(row: $0)
        }
    }

    /// Enables or disables a source, and keeps the deck's denormalised copy in
    /// step.
    ///
    /// Disabling is not removing: the photos leave the deck but stay in the
    /// pool, so re-enabling brings them straight back.
    public func setEnabled(_ enabled: Bool, for sourceID: Int64) throws {
        try database.transaction(.immediate) {
            try database.run(
                "UPDATE source SET enabled = :enabled WHERE id = :id;",
                ["enabled": SQLValue(enabled), "id": .int(sourceID)]
            )
            try database.run(
                "UPDATE photo SET source_enabled = :enabled WHERE source_id = :id;",
                ["enabled": SQLValue(enabled), "id": .int(sourceID)]
            )
            // Pictures already queued from a source being switched off would
            // otherwise still be shown after the user turned it off.
            if !enabled {
                try database.run(
                    """
                    DELETE FROM queue
                     WHERE photo_id IN (SELECT id FROM photo WHERE source_id = :id);
                    """,
                    ["id": .int(sourceID)]
                )
            }
        }
        Log.sources.notice(
            "source \(sourceID, privacy: .public) \(enabled ? "enabled" : "disabled", privacy: .public)"
        )
    }

    /// Removes a source and everything that came from it: the row, its
    /// photographs and their queue entries by cascade, and **its cached bytes**.
    ///
    /// The bytes go by source rather than photo by photo, because the cache is
    /// already laid out by source `uuid` — one directory, one removal, and no
    /// walk proportional to how many photographs were in it.
    ///
    /// Returns the bytes freed, which is zero when there was nothing cached and
    /// also zero when no byte index was handed to this store. Nothing on the
    /// *source* is touched: removal is not deletion.
    @discardableResult
    public func remove(id: Int64) throws -> Int64 {
        let uuid = try database.scalarString(
            "SELECT uuid FROM source WHERE id = :id;", ["id": .int(id)])
        try database.run("DELETE FROM source WHERE id = :id;", ["id": .int(id)])
        let freed = uuid.map { bytes?.removeSource($0) ?? 0 } ?? 0
        Log.sources.notice(
            "removed source \(id, privacy: .public), freeing \(freed, privacy: .public) bytes")
        return freed
    }

    // MARK: - Reconciling with preferences

    /// Held across a preferences write and the reconcile that projects it.
    ///
    /// Recursive because the editing calls take it and then reconcile, which
    /// takes it again. Static because the two writers that matter are in one
    /// process — the agent's loop and the endpoint answering a client — and a
    /// `SourceStore` is per connection rather than per library.

    /// What reconciling changed.
    static let editing = NSRecursiveLock()

    public struct Reconciliation: Sendable, Equatable {
        public let added: Int
        public let removed: Int
        public let changed: Int
        /// Cached bytes freed by the sources that went. A person removing a
        /// folder of eight thousand photographs should be told what came back,
        /// and a zero here after a real removal is how a missing byte index
        /// announces itself.
        public let bytesFreed: Int64

        public init(added: Int, removed: Int, changed: Int, bytesFreed: Int64 = 0) {
            self.added = added
            self.removed = removed
            self.changed = changed
            self.bytesFreed = bytesFreed
        }

        public var isEmpty: Bool { added == 0 && removed == 0 && changed == 0 }
    }

    /// Makes the `source` table match the durable list in preferences.
    ///
    /// **Preferences are the truth; the table is a projection.** A source the
    /// user chose cannot be derived from anything, so it lives in preferences —
    /// and everything the table holds about it can be found again by looking, so
    /// deleting the database throws away a cache rather than a decision.
    ///
    /// Run at launch and whenever the source list changes. A fresh database
    /// rebuilds itself from preferences and rescans; the user notices only that
    /// it took a moment.
    /// Makes the table match the durable list **as it stands now**.
    ///
    /// It reads the list itself rather than being handed one, and that is the
    /// whole point of the signature. The table is rebuilt from whatever it is
    /// given, so a caller holding a copy from a moment ago re-creates anything
    /// removed since — the agent's loop reads the list, walks its sources for as
    /// long as that takes, and a source deleted in the meantime comes back with
    /// its photographs and starts being shown again. Nobody can hold a stale
    /// copy of something they never receive.
    @discardableResult
    public func reconcile(with preferences: Preferences, now: Date = Date()) throws
        -> Reconciliation
    {
        Self.editing.lock()
        defer { Self.editing.unlock() }
        return try reconcile(specs: preferences.sources, now: now)
    }

    /// The projection itself, against an explicit list.
    ///
    /// Internal, and deliberately not public: an explicit list is exactly the
    /// thing that goes stale. Tests that want to assert the projection rules
    /// with a list they wrote are the reason it exists at all.
    @discardableResult
    func reconcile(specs: [SourceSpec], now: Date = Date()) throws -> Reconciliation {
        Self.editing.lock()
        defer { Self.editing.unlock() }

        let existing = try all()
        var added = 0
        var changed = 0

        for spec in specs {
            guard let match = existing.first(where: { $0.locator == spec.locator }) else {
                try add(
                    kind: spec.kind, locator: spec.locator,
                    recursive: spec.kind == .folder ? spec.recursive : nil, now: now
                )
                added += 1
                continue
            }
            if match.enabled != spec.enabled {
                try setEnabled(spec.enabled, for: match.id)
                changed += 1
            }
            if spec.kind == .folder, (match.recursive ?? false) != spec.recursive {
                try database.run(
                    "UPDATE source SET recursive = :r WHERE id = :id;",
                    ["r": SQLValue(spec.recursive), "id": .int(match.id)]
                )
                changed += 1
            }
        }

        // A source no longer listed is gone: its rows and its queue entries go
        // with it, because they were only ever a cache of it.
        let wanted = Set(specs.map(\.locator))
        var removed = 0
        var freed: Int64 = 0
        for source in existing where !wanted.contains(source.locator) {
            freed += try remove(id: source.id)
            removed += 1
        }

        let result = Reconciliation(
            added: added, removed: removed, changed: changed, bytesFreed: freed)
        if !result.isEmpty {
            Log.sources.notice(
                "reconciled sources with preferences: +\(added, privacy: .public) -\(removed, privacy: .public) ~\(changed, privacy: .public)"
            )
        }
        return result
    }

    // MARK: - Refreshing

    /// Refreshes every enabled source, one after another.
    ///
    /// Convenience for a single-threaded caller. The agent runs a task per
    /// source instead, because concurrency is scheduling and scheduling belongs
    /// to the host — but either way one source failing never stops the others.
    public func refreshAll(
        now: Date = Date(),
        onChange: ((Source, ScanChange) -> Void)? = nil
    ) async -> [ScanResult] {
        var results: [ScanResult] = []
        for source in (try? enabled()) ?? [] {
            results.append(
                await refresh(source, now: now, onChange: onChange.map { report in
                    { change in report(source, change) }
                })
            )
        }
        return results
    }

    /// Diffs one source against the pool and applies the difference.
    ///
    /// Never throws. A source that cannot be enumerated, has no provider, or
    /// fails outright becomes an unavailable source and nothing else — the worst
    /// outcome anywhere in this system is fewer photos, never an exception
    /// reaching the loop that is trying to show one.
    @discardableResult
    public func refresh(
        _ source: Source,
        now: Date = Date(),
        onChange: ((ScanChange) -> Void)? = nil
    ) async -> ScanResult {
        do {
            return try await applyRefresh(source, now: now, onChange: onChange)
        } catch let error as SQLiteError where error.isBusy {
            // **Contention is not a source going away, and confusing the two is
            // the expensive mistake this whole model exists to avoid.**
            //
            // `markUnavailable` is how the system says *these photographs are
            // not reachable* — it is meant for an unplugged drive or a revoked
            // permission. A database that was merely busy says nothing whatever
            // about the source; the folder is right there. Reporting it as
            // unavailable takes a healthy library off the screen and puts a
            // reason next to it in the settings panel that is simply untrue.
            //
            // This became reachable when SQLite stopped absorbing busy waits
            // internally: statements outside a transaction have no retry, so a
            // contended `UPDATE source` now surfaces rather than blocking. Seen
            // on 2026-08-25 — "source 22 unavailable: database is locked" for a
            // local folder that was perfectly fine.
            //
            // Nothing is written and nothing is claimed. The next pass tries
            // again, which is all a busy database ever asks of anybody.
            let reason = "refresh skipped: the library was busy"
            Log.sources.notice(
                "source \(source.id, privacy: .public) \(reason, privacy: .public)"
            )
            return ScanResult(
                sourceID: source.id, added: 0, removed: 0, unchanged: 0,
                sourceUnavailable: false, reason: reason
            )
        } catch {
            let reason = "refresh failed: \(error)"
            Log.sources.error(
                "source \(source.id, privacy: .public) \(reason, privacy: .public)"
            )
            try? markUnavailable(sourceID: source.id, reason: reason, at: now)
            return ScanResult(
                sourceID: source.id, added: 0, removed: 0, unchanged: 0,
                sourceUnavailable: true, reason: reason
            )
        }
    }

    private func applyRefresh(
        _ source: Source,
        now: Date,
        onChange: ((ScanChange) -> Void)?
    ) async throws -> ScanResult {
        guard let provider = providers[source.kind] else {
            // A source kind whose provider has not shipped yet — a Photos album
            // added before Phase 3. Unavailable, not an error: its entries stay
            // in the pool untouched until the provider arrives.
            let reason = "no provider for \(source.kind) in this build"
            try markUnavailable(sourceID: source.id, reason: reason, at: now)
            return ScanResult(
                sourceID: source.id, added: 0, removed: 0, unchanged: 0,
                sourceUnavailable: true, reason: reason
            )
        }

        let interval = Log.signposter.beginInterval("refresh")
        defer { Log.signposter.endInterval("refresh", interval) }

        // ── Additions: streamed, never collected ──
        //
        // A photo arrives, a row goes in, the value is dropped. Nothing about
        // this step scales with the size of the library, which is the whole
        // point: the only photos this system holds in memory are the ones in
        // the queue.
        var added = 0
        var updated = 0
        var seen = 0
        var pending: [DiscoveredPhoto] = []
        pending.reserveCapacity(PhotoPool.batchSize)

        // What this walk saw, held in SQLite rather than in memory.
        //
        // **The provider contract forbids building a collection of a whole
        // source, and this does not break it.** The rule is about the process's
        // heap — a hundred-thousand-photo library is about 7 KB per photo as
        // values — and what goes here is one short string per photograph, in a
        // temporary table the database spills to disk as it sees fit. Nothing
        // accumulates in memory beyond the batch already being written.
        //
        // Temporary, because it is *this walk's observation*. The durable
        // snapshot of the filesystem is the `photo` table itself; this is the
        // new reading being compared against it, and it is worthless the moment
        // the comparison is done.
        try database.run(
            """
            CREATE TEMP TABLE IF NOT EXISTS walk_seen (
              source_id   INTEGER NOT NULL,
              external_id TEXT    NOT NULL,
              PRIMARY KEY (source_id, external_id)
            );
            """
        )
        // Scoped and cleared, so a connection that refreshes several sources in
        // turn cannot let one walk's findings condemn another's photographs.
        try database.run(
            "DELETE FROM walk_seen WHERE source_id = :id;", ["id": .int(source.id)])

        // **`async`, so the batch write suspends rather than blocking.** This is
        // the write that holds SQLite's writer longest — thousands of rows, five
        // hundred to a transaction, for as long as a network walk takes. Doing
        // it synchronously from an async task parked a cooperative-pool thread
        // on every contended batch, and four concurrent walks left nothing for
        // serving to run on. See `PhotoPool.upsert`'s async form.
        func flush() async throws {
            guard !pending.isEmpty else { return }
            let counts = try await pool.upsert(pending, to: source, at: now) { photo in
                onChange?(.added(externalID: photo.externalID))
            }
            for photo in pending {
                try database.run(
                    """
                    INSERT OR IGNORE INTO walk_seen (source_id, external_id)
                    VALUES (:source, :external);
                    """,
                    ["source": .int(source.id), "external": .text(photo.externalID)]
                )
            }
            added += counts.added
            updated += counts.updated
            pending.removeAll(keepingCapacity: true)
        }

        let reachability = try await provider.enumerate(source) { photo in
            seen += 1
            pending.append(photo)
            // Batched only to keep the write transaction count sane. The buffer
            // is five hundred entries, not a library.
            if pending.count >= PhotoPool.batchSize { try await flush() }
        }

        if let reason = reachability.unavailableReason {
            // A source that could not be reached keeps every entry it has. An
            // external drive that is not plugged in makes ten thousand photos
            // vanish at once, and emptying the pool over it would mean
            // re-enumerating and re-downloading everything on every undock.
            try markUnavailable(sourceID: source.id, reason: reason, at: now)
            return ScanResult(
                sourceID: source.id, added: 0, removed: 0, unchanged: 0,
                sourceUnavailable: true, reason: reason
            )
        }
        try await flush()

        // A source that loses *everything* at once has become unavailable; its
        // contents were not deleted. This covers a Photos library switch and a
        // share that silently disconnected, and it survives the move away from
        // diffing because both halves of it are counters — how many the walk
        // produced, and how many rows exist — rather than the contents of either.
        if seen == 0 {
            let held = try pool.size(forSource: source.id)
            if held > 0 {
                let reason = "enumerated to nothing, but was not empty before"
                Log.sources.notice(
                    "source \(source.id, privacy: .public) \(reason, privacy: .public); leaving \(held, privacy: .public) entries in the pool"
                )
                try markUnavailable(sourceID: source.id, reason: reason, at: now)
                return ScanResult(
                    sourceID: source.id, added: 0, removed: 0, unchanged: held,
                    sourceUnavailable: true, reason: reason
                )
            }
        }

        // ── Removals: the difference between what is held and what was seen ──
        //
        // **One walk, not one question per photograph.** This used to page
        // through the pool asking the provider about every entry it held, which
        // is a round trip each. On a folder that is a stat and invisible; on a
        // network volume it is most of a second, so a source of five thousand
        // photographs took over an hour — and because the agent awaits its
        // refresh, everything else it does stopped for the duration.
        //
        // The walk that just ran already knows what is there. Anything the pool
        // holds that the walk did not produce is gone, and that is one query.
        //
        // The three-valued existence check is not lost, only moved to where it
        // is worth its cost: serving still asks it about the single photograph
        // it is about to display, which is where the deleted-photo guarantee
        // actually lives.
        var removed = 0
        var freed: Int64 = 0

        while true {
            let departed = try database.all(
                """
                SELECT p.id AS id, p.external_id AS external_id
                  FROM photo p
                 WHERE p.source_id = :id
                   AND NOT EXISTS (
                         SELECT 1 FROM walk_seen w
                          WHERE w.source_id = p.source_id
                            AND w.external_id = p.external_id)
                 LIMIT :limit;
                """,
                ["id": .int(source.id), "limit": .int(Int64(PhotoPool.batchSize))]
            ) { (id: try $0.int64("id"), externalID: try $0.string("external_id")) }
            guard !departed.isEmpty else { break }

            for entry in departed { onChange?(.removed(externalID: entry.externalID)) }
            let removal = try await pool.remove(departed.map(\.id))
            removed += removal.count
            // The bytes go with the rows, here rather than at the next launch. A
            // photograph that has left its source — deleted from the folder, or
            // nested in one that is no longer recursive — is not coming back,
            // and the cached original and its renderings were the only things
            // still holding that space.
            for uuid in removal.orphaned {
                freed += bytes?.remove(photoUUID: uuid) ?? 0
            }
        }

        // Done with, and dropped rather than left for the connection's lifetime:
        // an agent refreshing every five minutes would otherwise carry the last
        // walk's findings around between passes for no reason.
        try database.run(
            "DELETE FROM walk_seen WHERE source_id = :id;", ["id": .int(source.id)])

        try markAvailable(sourceID: source.id, scannedAt: now)

        let result = ScanResult(
            sourceID: source.id, added: added, removed: removed,
            unchanged: max(0, seen - added), sourceUnavailable: false, reason: nil,
            bytesFreed: freed
        )
        if !result.isEmpty {
            Log.sources.notice(
                """
                refreshed source \(source.id, privacy: .public): \
                added \(result.added, privacy: .public), \
                removed \(result.removed, privacy: .public), \
                unchanged \(result.unchanged, privacy: .public)
                """
            )
        }
        return result
    }

    // MARK: - Availability

    /// **Inside a transaction so that contention is waited out rather than
    /// surfaced.** A bare statement has no retry of its own, and these two run
    /// at the end of every refresh — squarely in the path of whatever else is
    /// writing. Failing here used to turn a busy database into a source marked
    /// unavailable, which is a lie about the user's library.
    public func markUnavailable(sourceID: Int64, reason: String, at now: Date = Date()) throws {
        try database.transaction(.immediate) {
            try database.run(
                """
                UPDATE source
                   SET available = 0, unavailable_reason = :reason, unavailable_at = :now,
                       scanned_at = :now
                 WHERE id = :id;
                """,
                ["reason": .text(reason), "now": SQLValue(now), "id": .int(sourceID)]
            )
        }
        Log.sources.notice(
            "source \(sourceID, privacy: .public) unavailable: \(reason, privacy: .public)"
        )
    }

    public func markAvailable(sourceID: Int64, scannedAt now: Date = Date()) throws {
        let wasUnavailable = try database.transaction(.immediate) {
            let was =
                try database.scalarInt(
                    "SELECT available FROM source WHERE id = :id;", ["id": .int(sourceID)]
                ) == 0
            try database.run(
                """
                UPDATE source
                   SET available = 1, unavailable_reason = NULL, unavailable_at = NULL,
                       scanned_at = :now
                 WHERE id = :id;
                """,
                ["now": SQLValue(now), "id": .int(sourceID)]
            )
            return was
        }
        if wasUnavailable {
            Log.sources.notice("source \(sourceID, privacy: .public) is available again")
        }
    }

    private static let selectSourceSQL = """
        SELECT id, uuid, kind, locator, bookmark, stamp_uuid, enabled, recursive,
               available, unavailable_reason, unavailable_at, added_at, scanned_at
          FROM source
        """
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        guard !isEmpty, size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            self[$0..<Swift.min($0 + size, count)]
        }
    }
}
