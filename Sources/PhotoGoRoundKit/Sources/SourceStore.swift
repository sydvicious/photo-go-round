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
                INSERT INTO source (kind, locator, bookmark, stamp_uuid, enabled, recursive, added_at)
                VALUES (:kind, :locator, :bookmark, :stamp, 1, :recursive, :now);
                """,
                [
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

        let enumeration = try await provider.enumerate(source)

        // A source that could not be reached keeps every entry it has. An
        // external drive that is not plugged in makes ten thousand photos
        // vanish at once, and emptying the pool over it would mean
        // re-enumerating and re-downloading everything on every undock.
        if let reason = enumeration.unavailableReason {
            try markUnavailable(sourceID: source.id, reason: reason, at: now)
            return ScanResult(
                sourceID: source.id, added: 0, removed: 0, unchanged: 0,
                sourceUnavailable: true, reason: reason
            )
        }

        let existing = try pool.contents(ofSource: source.id)

        // The same rule, generalised: a source that loses *everything* at once
        // has become unavailable; its contents were not deleted. This covers a
        // Photos library switch and a share that silently disconnected.
        if enumeration.photos.isEmpty, !existing.isEmpty {
            let reason = "enumerated to nothing, but was not empty before"
            Log.sources.notice(
                "source \(source.id, privacy: .public) \(reason, privacy: .public); leaving \(existing.count, privacy: .public) entries in the pool"
            )
            try markUnavailable(sourceID: source.id, reason: reason, at: now)
            return ScanResult(
                sourceID: source.id, added: 0, removed: 0, unchanged: existing.count,
                sourceUnavailable: true, reason: reason
            )
        }

        var discovered = Set<String>()
        discovered.reserveCapacity(enumeration.photos.count)
        var additions: [DiscoveredPhoto] = []
        var updates: [(id: Int64, photo: DiscoveredPhoto)] = []
        var unchanged = 0

        for photo in enumeration.photos {
            discovered.insert(photo.externalID)
            guard let entry = existing[photo.externalID] else {
                additions.append(photo)
                continue
            }
            if entry.storage != photo.storage || entry.byteSize != photo.byteSize {
                updates.append((entry.id, photo))
            } else {
                unchanged += 1
            }
        }

        let departed = existing.filter { !discovered.contains($0.key) }

        try pool.add(additions, to: source, at: now)
        for (id, photo) in updates {
            try pool.refresh(id, storage: photo.storage, byteSize: photo.byteSize)
        }
        try pool.remove(departed.values.map(\.id))

        try markAvailable(sourceID: source.id, scannedAt: now)

        if let onChange {
            for photo in additions { onChange(.added(externalID: photo.externalID)) }
            for externalID in departed.keys { onChange(.removed(externalID: externalID)) }
        }

        let result = ScanResult(
            sourceID: source.id, added: additions.count, removed: departed.count,
            unchanged: unchanged + updates.count, sourceUnavailable: false, reason: nil
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
        SELECT id, kind, locator, bookmark, stamp_uuid, enabled, recursive,
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
