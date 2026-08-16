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
    public let sourceID: Int64
    /// A `PHAsset` local identifier, a Google media item id, or — for folder
    /// sources — the path relative to the source's own path.
    public let externalID: String
    public let storage: PhotoStorage
    /// Absolute for referenced photos; relative to the cache root for
    /// materialized ones. Nil when the bytes are not resident.
    public let cachePath: String?
    /// The deal ordinal assigned when this card was played. Nil for a card that
    /// has been reserved into a hand but not yet played.
    public let dealSeq: Int64?

    public init(
        id: Int64,
        sourceID: Int64,
        externalID: String,
        storage: PhotoStorage,
        cachePath: String?,
        dealSeq: Int64?
    ) {
        self.id = id
        self.sourceID = sourceID
        self.externalID = externalID
        self.storage = storage
        self.cachePath = cachePath
        self.dealSeq = dealSeq
    }

    init(row: Row, dealSeq: Int64?) throws {
        self.init(
            id: try row.int64("id"),
            sourceID: try row.int64("source_id"),
            externalID: try row.string("external_id"),
            storage: PhotoStorage(rawValue: try row.string("storage")) ?? .materialized,
            cachePath: try row.optionalString("cache_path"),
            dealSeq: dealSeq
        )
    }
}
