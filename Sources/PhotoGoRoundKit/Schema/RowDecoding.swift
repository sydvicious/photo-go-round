import Foundation
import PhotoGoRoundAgentAPI

/// Turning database rows into the model types.
///
/// **These live here rather than beside the types they build.** `Source` and
/// `DeckCard` are shared with the app, which has no database and never will —
/// the whole point of `PhotoGoRoundAgentAPI` is that a client links the value
/// types without linking the store that produced them. A row initialiser
/// declared next to the struct would drag `Row`, and behind it SQLite, into
/// every process that wants to draw a source's name.
extension Source {
    init(row: Row) throws {
        self.init(
            id: try row.int64("id"),
            uuid: try row.string("uuid"),
            kind: SourceKind(try row.string("kind")),
            locator: try row.string("locator"),
            bookmark: try row.optionalData("bookmark"),
            stampUUID: try row.optionalString("stamp_uuid"),
            enabled: try row.bool("enabled"),
            recursive: try row.optionalInt("recursive").map { $0 != 0 },
            description: try Self.description(in: row),
            available: try row.bool("available"),
            unavailableReason: try row.optionalString("unavailable_reason"),
            unavailableAt: try row.optionalDate("unavailable_at"),
            addedAt: try row.date("added_at"),
            scannedAt: try row.optionalDate("scanned_at")
        )
    }

    /// The three columns migration 11 added, read back as one value or none.
    /// A title without a kind is a row nothing in this project writes, and it
    /// reads as no description rather than as half of one.
    private static func description(in row: Row) throws -> SourceDescription? {
        guard let title = try row.optionalString("title"),
            let kind = try row.optionalString("collection_kind")
        else { return nil }
        return SourceDescription(
            title: title, collectionKind: kind,
            folders: try Self.folders(in: row))
    }

    /// `folders` is a JSON array of names. **Absent is none, and unreadable
    /// is an error rather than none**: a row this project wrote is either
    /// `NULL` or well-formed, and anything else is somebody's hand edit,
    /// which should be seen rather than silently read as a top-level album.
    private static func folders(in row: Row) throws -> [String] {
        guard let text = try row.optionalString("folders") else { return [] }
        return try JSONDecoder().decode([String].self, from: Data(text.utf8))
    }
}

extension SourceDescription {
    /// The `folders` column's value: `NULL` for a top-level album, so the
    /// common case reads as an absence rather than as `[]`.
    var foldersColumn: String? {
        guard !folders.isEmpty,
            let data = try? JSONEncoder().encode(folders)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

extension DeckCard {
    init(row: Row, dealSeq: Int64?) throws {
        self.init(
            id: try row.int64("id"),
            uuid: try row.string("uuid"),
            sourceID: try row.int64("source_id"),
            sourceUUID: try row.string("source_uuid"),
            externalID: try row.string("external_id"),
            storage: PhotoStorage(rawValue: try row.string("storage")) ?? .materialized,
            dealSeq: dealSeq
        )
    }
}

extension Consumer {
    init(row: Row) throws {
        self.init(
            id: try row.int64("id"),
            kind: ConsumerKind(try row.string("kind")),
            displayID: try row.optionalString("display_id"),
            seenAt: try row.date("seen_at"),
            createdAt: try row.date("created_at")
        )
    }
}
