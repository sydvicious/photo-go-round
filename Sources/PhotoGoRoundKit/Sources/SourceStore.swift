import Foundation

/// One photo changing state during a scan, reported as it happens.
///
/// The counts in `ScanResult` are what the agent acts on; this is what a person
/// watching a folder wants to see.
public enum ScanChange: Sendable, Equatable {
    case added(externalID: String)
    /// Was unavailable, and has come back — with its deal history intact.
    case returned(externalID: String)
    case vanished(externalID: String)

    public var externalID: String {
        switch self {
        case .added(let id), .returned(let id), .vanished(let id): id
        }
    }
}

/// What a scan changed.
public struct ScanResult: Sendable, Equatable {
    public let sourceID: Int64
    public let added: Int
    /// Photos that had gone missing and have come back, with their deal history
    /// intact.
    public let returned: Int
    public let vanished: Int
    public let unchanged: Int
    /// True when the source itself could not be reached, in which case no photo
    /// row was touched at all.
    public let sourceUnavailable: Bool
    public let reason: String?

    public var isEmpty: Bool { added == 0 && returned == 0 && vanished == 0 }
}

/// Adding, listing, enabling, and rescanning sources.
///
/// The deck is the union of every enabled source, so nothing in here ever
/// assumes there is one of them.
public struct SourceStore {
    public let database: Database
    private let providers: [SourceKind: any SourceProvider]

    /// Rows per write transaction during a scan. Large enough that a
    /// fifty-thousand-photo folder is not fifty thousand transactions, small
    /// enough that it never holds the single writer lock for a minute.
    static let batchSize = 500

    public init(database: Database, providers: [any SourceProvider]) {
        self.database = database
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.kind, $0) })
    }

    /// The providers Phase 1 ships with: files on disk, and nothing else.
    public init(database: Database, fileAccess: any FileAccess = UnsandboxedFileAccess()) {
        self.init(
            database: database,
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
    /// Disabling is not deleting: the photos leave the deck but keep their deal
    /// history, so re-enabling resumes where it left off rather than restarting
    /// the shuffle.
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
            // Cards already reserved from a source that is being switched off
            // would otherwise be shown after the user turned it off.
            if !enabled {
                try database.run(
                    """
                    DELETE FROM hand
                     WHERE played_at IS NULL
                       AND photo_id IN (SELECT id FROM photo WHERE source_id = :id);
                    """,
                    ["id": .int(sourceID)]
                )
            }
        }
        Log.sources.notice(
            "source \(sourceID, privacy: .public) \(enabled ? "enabled" : "disabled", privacy: .public)"
        )
    }

    /// Removes a source and everything that came from it. The photo rows and
    /// their hands cascade.
    public func remove(id: Int64) throws {
        try database.run("DELETE FROM source WHERE id = :id;", ["id": .int(id)])
        Log.sources.notice("removed source \(id, privacy: .public)")
    }

    // MARK: - Scanning

    /// Rescans every enabled source.
    public func scanAll(
        now: Date = Date(),
        onChange: ((Source, ScanChange) -> Void)? = nil
    ) async throws -> [ScanResult] {
        var results: [ScanResult] = []
        for source in try enabled() {
            results.append(
                try await scan(source, now: now, onChange: onChange.map { report in
                    { change in report(source, change) }
                })
            )
        }
        return results
    }

    /// Diffs a source against the database and flips flags in both directions.
    ///
    /// Incremental by construction: new photos are inserted with a null deal
    /// ordinal, which makes them eligible at once without being placed anywhere
    /// special; vanished ones are soft-deleted; returning ones come back with
    /// their history.
    @discardableResult
    public func scan(
        _ source: Source,
        now: Date = Date(),
        onChange: ((ScanChange) -> Void)? = nil
    ) async throws -> ScanResult {
        guard let provider = providers[source.kind] else {
            throw SourceProviderError.wrongProvider(expected: source.kind, got: source.kind)
        }

        let interval = Log.signposter.beginInterval("scan")
        defer { Log.signposter.endInterval("scan", interval) }

        let enumeration = try await provider.enumerate(source)

        // A source that could not be reached at all keeps every photo row and
        // every deal ordinal. An external drive that is not plugged in makes ten
        // thousand photos vanish at once, and processing that as ten thousand
        // individual disappearances would mean re-enumerating and re-downloading
        // everything on every undock.
        if let reason = enumeration.unavailableReason {
            try markUnavailable(sourceID: source.id, reason: reason, at: now)
            return ScanResult(
                sourceID: source.id, added: 0, returned: 0, vanished: 0, unchanged: 0,
                sourceUnavailable: true, reason: reason
            )
        }

        let existing = try existingPhotos(ofSource: source.id)

        // The same rule, generalised: a source that loses *everything* at once
        // has become unavailable; it has not had its contents deleted. This is
        // what covers a Photos library switch and a share that silently
        // disconnected, and it is why an emptied folder is reported rather than
        // acted on.
        if enumeration.photos.isEmpty, existing.contains(where: { $0.value.available }) {
            let reason = "enumerated to nothing, but was not empty before"
            Log.sources.notice(
                "source \(source.id, privacy: .public) \(reason, privacy: .public); leaving \(existing.count, privacy: .public) rows intact"
            )
            try markUnavailable(sourceID: source.id, reason: reason, at: now)
            return ScanResult(
                sourceID: source.id, added: 0, returned: 0, vanished: 0, unchanged: existing.count,
                sourceUnavailable: true, reason: reason
            )
        }

        var added = 0
        var returned = 0
        var unchanged = 0
        var discoveredIDs = Set<String>()
        discoveredIDs.reserveCapacity(enumeration.photos.count)

        var inserts: [DiscoveredPhoto] = []
        var revivals: [(id: Int64, photo: DiscoveredPhoto)] = []
        var updates: [(id: Int64, photo: DiscoveredPhoto)] = []

        for photo in enumeration.photos {
            discoveredIDs.insert(photo.externalID)
            guard let row = existing[photo.externalID] else {
                inserts.append(photo)
                continue
            }
            if !row.available {
                revivals.append((row.id, photo))
            } else if row.storage != photo.storage || row.byteSize != photo.byteSize {
                updates.append((row.id, photo))
            } else {
                unchanged += 1
            }
        }

        let vanished = existing.filter { $0.value.available && !discoveredIDs.contains($0.key) }

        try insert(inserts, into: source, at: now)
        added = inserts.count
        try revive(revivals, at: now)
        returned = revivals.count
        try refresh(updates)
        unchanged += updates.count
        try markVanished(vanished.values.map(\.id))

        if let onChange {
            for photo in inserts { onChange(.added(externalID: photo.externalID)) }
            for (_, photo) in revivals { onChange(.returned(externalID: photo.externalID)) }
            for externalID in vanished.keys { onChange(.vanished(externalID: externalID)) }
        }

        try markAvailable(sourceID: source.id, scannedAt: now)

        let result = ScanResult(
            sourceID: source.id, added: added, returned: returned, vanished: vanished.count,
            unchanged: unchanged, sourceUnavailable: false, reason: nil
        )
        if !result.isEmpty {
            Log.sources.notice(
                """
                scanned source \(source.id, privacy: .public): \
                added \(added, privacy: .public), \
                returned \(returned, privacy: .public), \
                vanished \(vanished.count, privacy: .public), \
                unchanged \(unchanged, privacy: .public)
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

    // MARK: - The diff, applied

    private struct ExistingPhoto {
        let id: Int64
        let available: Bool
        let storage: PhotoStorage
        let byteSize: Int64?
    }

    private func existingPhotos(ofSource sourceID: Int64) throws -> [String: ExistingPhoto] {
        var rows: [String: ExistingPhoto] = [:]
        try database.query(
            "SELECT id, external_id, available, storage, byte_size FROM photo WHERE source_id = :id;",
            ["id": .int(sourceID)]
        ) { row in
            rows[try row.string("external_id")] = ExistingPhoto(
                id: try row.int64("id"),
                available: try row.bool("available"),
                storage: PhotoStorage(rawValue: try row.string("storage")) ?? .materialized,
                byteSize: try row.optionalInt64("byte_size")
            )
        }
        return rows
    }

    private func insert(_ photos: [DiscoveredPhoto], into source: Source, at now: Date) throws {
        for batch in photos.chunked(into: Self.batchSize) {
            try database.transaction(.immediate) {
                for photo in batch {
                    try database.run(
                        """
                        INSERT INTO photo (source_id, external_id, media_type, source_enabled,
                                           available, storage, byte_size, shuffle_key, added_at)
                        VALUES (:source, :external, :media, :enabled, 1, :storage, :size, :key, :now);
                        """,
                        [
                            "source": .int(source.id),
                            "external": .text(photo.externalID),
                            "media": .text(photo.mediaType.rawValue),
                            "enabled": SQLValue(source.enabled),
                            "storage": .text(photo.storage.rawValue),
                            "size": SQLValue(photo.byteSize),
                            // A fresh key and a null deal ordinal: eligible at
                            // once, competing with everything else.
                            "key": .double(Double.random(in: 0..<1)),
                            "now": SQLValue(now),
                        ]
                    )
                }
            }
        }
    }

    private func revive(_ photos: [(id: Int64, photo: DiscoveredPhoto)], at now: Date) throws {
        for batch in photos.chunked(into: Self.batchSize) {
            try database.transaction(.immediate) {
                for (id, photo) in batch {
                    try database.run(
                        """
                        UPDATE photo
                           SET available = 1, storage = :storage, byte_size = :size
                         WHERE id = :id;
                        """,
                        [
                            "storage": .text(photo.storage.rawValue),
                            "size": SQLValue(photo.byteSize),
                            "id": .int(id),
                        ]
                    )
                }
            }
        }
    }

    private func refresh(_ photos: [(id: Int64, photo: DiscoveredPhoto)]) throws {
        for batch in photos.chunked(into: Self.batchSize) {
            try database.transaction(.immediate) {
                for (id, photo) in batch {
                    try database.run(
                        "UPDATE photo SET storage = :storage, byte_size = :size WHERE id = :id;",
                        [
                            "storage": .text(photo.storage.rawValue),
                            "size": SQLValue(photo.byteSize),
                            "id": .int(id),
                        ]
                    )
                }
            }
        }
    }

    /// Soft delete. The row stays, with `available = 0`, because keeping it
    /// costs 200 bytes and buys three things: an unmounted volume is not ten
    /// thousand deletions, rename tracking has something to match against
    /// later, and `times_shown` stays honest across an absence.
    private func markVanished(_ ids: [Int64]) throws {
        for batch in ids.chunked(into: Self.batchSize) {
            try database.transaction(.immediate) {
                for id in batch {
                    try database.run(
                        "UPDATE photo SET available = 0 WHERE id = :id;", ["id": .int(id)]
                    )
                    // Its bytes are gone, so an outstanding card for it is not
                    // playable — return it rather than showing a gap.
                    try database.run(
                        "DELETE FROM hand WHERE photo_id = :id AND played_at IS NULL;",
                        ["id": .int(id)]
                    )
                }
            }
        }
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
