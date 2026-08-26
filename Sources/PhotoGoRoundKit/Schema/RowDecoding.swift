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
            available: try row.bool("available"),
            unavailableReason: try row.optionalString("unavailable_reason"),
            unavailableAt: try row.optionalDate("unavailable_at"),
            addedAt: try row.date("added_at"),
            scannedAt: try row.optionalDate("scanned_at")
        )
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
