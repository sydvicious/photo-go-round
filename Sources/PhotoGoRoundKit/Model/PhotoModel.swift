import Foundation

/// Whether a photo's bytes can go away, which is a property of *where the file
/// lives* rather than of which provider found it.
public enum PhotoStorage: String, Sendable, CaseIterable {
    /// A file on the internal boot volume. We store its path and copy nothing,
    /// because copying a file that is always there is pure waste. It does not
    /// count against the cache cap and eviction is a no-op.
    case referenced
    /// Everything else: external, removable, network, ubiquitous, or a provider
    /// with no file to point at in the first place. Copied into the cache, and
    /// governed by the cap.
    case materialized

    /// Classifies a URL from the volume properties the scanner reads.
    ///
    /// The default when a property cannot be read is `materialized`: copying a
    /// file we did not need to copy wastes disk, whereas referencing one that
    /// disappears blanks a screen.
    public static func classify(
        volumeIsInternal: Bool?,
        volumeIsRemovable: Bool?,
        volumeIsEjectable: Bool?,
        volumeIsLocal: Bool?,
        isUbiquitous: Bool?
    ) -> PhotoStorage {
        if isUbiquitous == true { return .materialized }
        if volumeIsRemovable == true || volumeIsEjectable == true { return .materialized }
        if volumeIsLocal == false { return .materialized }
        return volumeIsInternal == true ? .referenced : .materialized
    }
}

/// Still images only in v1. `video` is expressible and never selected, so
/// turning video on later is a change to a predicate rather than a rescan of
/// every source the user has ever added.
public enum MediaType: String, Sendable, CaseIterable {
    case image
    case video
}

/// One card, as handed to a consumer.
public struct DeckCard: Sendable, Equatable, Identifiable {
    public let id: Int64
    /// Durable identity, and what the cache's filenames carry. The row id is not
    /// stable: the database is disposable and a rebuilt one renumbers from 1.
    public let uuid: String
    public let sourceID: Int64
    /// The source's durable identity, which names its directory in the cache.
    public let sourceUUID: String
    /// A `PHAsset` local identifier, a Google media item id, or — for folder
    /// sources — the path relative to the source's own path.
    public let externalID: String
    public let storage: PhotoStorage
    /// The ordinal assigned when this picture was shown. Nil for one that is
    /// queued or merely selected, and so has not been shown yet.
    public let dealSeq: Int64?

    public init(
        id: Int64,
        uuid: String,
        sourceID: Int64,
        sourceUUID: String,
        externalID: String,
        storage: PhotoStorage,
        dealSeq: Int64?
    ) {
        self.id = id
        self.uuid = uuid
        self.sourceID = sourceID
        self.sourceUUID = sourceUUID
        self.externalID = externalID
        self.storage = storage
        self.dealSeq = dealSeq
    }

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
