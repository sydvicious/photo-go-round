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
    /// Cache-relative paths whose photos are gone. The store has no idea where
    /// the cache root is, so it reports them and whoever owns the root deletes
    /// them. Bounded by how many photos actually disappeared, not by library
    /// size — a scan that removes nothing carries nothing.
    public let orphaned: [String]

    public init(
        sourceID: Int64, added: Int, removed: Int, unchanged: Int,
        sourceUnavailable: Bool, reason: String?, orphaned: [String] = []
    ) {
        self.sourceID = sourceID
        self.added = added
        self.removed = removed
        self.unchanged = unchanged
        self.sourceUnavailable = sourceUnavailable
        self.reason = reason
        self.orphaned = orphaned
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

    private let providers: [SourceKind: any SourceProvider]

    public init(
        database: Database,
        fileAccess: any FileAccess = UnsandboxedFileAccess(),
        providers: [any SourceProvider]
    ) {
        self.database = database
        self.fileAccess = fileAccess
        self.pool = PhotoPool(database: database)
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.kind, $0) })
    }

    /// The providers Phase 1 ships with: files on disk, and nothing else.
    public init(database: Database, fileAccess: any FileAccess = UnsandboxedFileAccess()) {
        self.init(
            database: database,
            fileAccess: fileAccess,
            providers: [
                FolderSourceProvider(fileAccess: fileAccess),
                FileSourceProvider(fileAccess: fileAccess),
            ]
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

    /// Removes a source and everything that came from it.
    public func remove(id: Int64) throws {
        try database.run("DELETE FROM source WHERE id = :id;", ["id": .int(id)])
        Log.sources.notice("removed source \(id, privacy: .public)")
    }

    // MARK: - Reconciling with preferences

    /// What reconciling changed.
    public struct Reconciliation: Sendable, Equatable {
        public let added: Int
        public let removed: Int
        public let changed: Int

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
    @discardableResult
    public func reconcile(with specs: [SourceSpec], now: Date = Date()) throws -> Reconciliation {
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
        for source in existing where !wanted.contains(source.locator) {
            try remove(id: source.id)
            removed += 1
        }

        let result = Reconciliation(added: added, removed: removed, changed: changed)
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

        func flush() throws {
            guard !pending.isEmpty else { return }
            let counts = try pool.upsert(pending, to: source, at: now) { photo in
                onChange?(.added(externalID: photo.externalID))
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
            if pending.count >= PhotoPool.batchSize { try flush() }
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
        try flush()

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

        // ── Removals: asked one photo at a time ──
        //
        // There is no diff and no set of what was seen. The pool is walked a
        // page at a time and each entry's provider is asked whether that photo
        // is still there, which is the same three-valued check that guarantees a
        // deleted photo is never shown.
        //
        var removed = 0
        // Photos the walk found still in place. The walk runs after the inserts,
        // so it sees this pass's additions too — they are discounted at the end
        // rather than tracked here, which would mean knowing which rows were new.
        var survived = 0
        var cursor: Int64 = 0
        var orphaned: [String] = []

        while true {
            let batch = try pool.page(ofSource: source.id, after: cursor)
            guard let last = batch.last else { break }
            cursor = last.id

            var departed: [Int64] = []
            for entry in batch {
                switch await provider.existence(of: entry.externalID, in: source) {
                case .absent:
                    departed.append(entry.id)
                    onChange?(.removed(externalID: entry.externalID))
                case .present, .unknown:
                    // `.unknown` is not `.absent`. The photo keeps its row and
                    // its history, and the question gets asked again next pass.
                    survived += 1
                }
            }

            if !departed.isEmpty {
                let removal = try pool.remove(departed)
                removed += removal.count
                orphaned += removal.orphaned
            }
        }

        try markAvailable(sourceID: source.id, scannedAt: now)

        let result = ScanResult(
            sourceID: source.id, added: added, removed: removed,
            unchanged: max(0, survived - added), sourceUnavailable: false, reason: nil,
            orphaned: orphaned
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

    public func markUnavailable(sourceID: Int64, reason: String, at now: Date = Date()) throws {
        try database.run(
            """
            UPDATE source
               SET available = 0, unavailable_reason = :reason, unavailable_at = :now,
                   scanned_at = :now
             WHERE id = :id;
            """,
            ["reason": .text(reason), "now": SQLValue(now), "id": .int(sourceID)]
        )
        Log.sources.notice(
            "source \(sourceID, privacy: .public) unavailable: \(reason, privacy: .public)"
        )
    }

    public func markAvailable(sourceID: Int64, scannedAt now: Date = Date()) throws {
        let wasUnavailable =
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
        if wasUnavailable {
            Log.sources.notice("source \(sourceID, privacy: .public) is available again")
        }
    }

    /// Whether a source is reachable right now, asked at the moment it matters
    /// rather than remembered from the last refresh.
    ///
    /// This is what decides the two very different meanings of a failed
    /// download: a file missing from a source that is *there* is a file that is
    /// gone, and a file missing from a source that is *not* there says nothing
    /// about the file at all.
    public func isOnline(_ source: Source) -> Bool {
        guard source.kind.isFileBacked else { return source.available }
        return (try? fileAccess.withSourceURL(source) { url in
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }) ?? false
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
