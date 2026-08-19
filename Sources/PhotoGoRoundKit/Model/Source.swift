import Foundation

/// What kind of thing a source is.
///
/// Deliberately not an enum, and the schema deliberately carries no CHECK
/// constraint: once the provider protocol exists, a new source kind is a new
/// provider rather than a migration. Google Photos is a late phase because of
/// its OAuth flow, not because of anything structural.
public struct SourceKind: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// A directory on disk, optionally walked recursively.
    public static let folder = SourceKind("folder")
    /// One explicitly chosen image file.
    ///
    /// Not a folder with a single entry. Modelling it that way would have put a
    /// "but what if it is really just one file" branch in every folder-scan
    /// path, and it could not have expressed the Photos equivalent at all,
    /// since a pinned asset has no path.
    public static let file = SourceKind("file")
    /// An album, smart album, or Favorites in the system Photos library.
    public static let photosCollection = SourceKind("photos_collection")
    /// One pinned asset in the system Photos library.
    public static let photosAsset = SourceKind("photos_asset")
    /// An album in Google Photos.
    public static let googleAlbum = SourceKind("google_album")

    /// Whether this kind is backed by files the user handed us directly, and is
    /// therefore eligible for the extended-attribute stamp that survives a
    /// rename or a move.
    public var isFileBacked: Bool {
        self == .folder || self == .file
    }
}

extension SourceKind: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}

extension SourceKind: CustomStringConvertible {
    public var description: String { rawValue }
}

/// A row in `source`. Never a setting.
public struct Source: Sendable, Equatable, Identifiable {
    public let id: Int64
    /// Durable identity, and what names this source's directory in the cache.
    /// The row id is not stable: the database is disposable and a rebuilt one
    /// renumbers from 1.
    public let uuid: String
    public let kind: SourceKind
    /// Path, `PHAssetCollection` id, `PHAsset` id, Google album id. For folder
    /// and file sources this is the only absolute path in the system — photos
    /// inside a folder are stored relative to it.
    public let locator: String
    /// Durable identity, stored from the first commit even though the Mac runs
    /// unsandboxed and ignores it today.
    public let bookmark: Data?
    /// The UUID written into the item's `com.apple.metadata:` extended
    /// attribute, which is what Spotlight can be asked for when the path stops
    /// resolving.
    public let stampUUID: String?
    /// Disabling is not deleting: it drops the source's photos from the deck
    /// without discarding their deal history.
    public let enabled: Bool
    /// Folder sources only.
    public let recursive: Bool?
    /// A source that lost everything at once, rather than one whose contents
    /// were deleted.
    public let available: Bool
    public let unavailableReason: String?
    public let unavailableAt: Date?
    public let addedAt: Date
    public let scannedAt: Date?

    init(row: Row) throws {
        id = try row.int64("id")
        uuid = try row.string("uuid")
        kind = SourceKind(try row.string("kind"))
        locator = try row.string("locator")
        bookmark = try row.optionalData("bookmark")
        stampUUID = try row.optionalString("stamp_uuid")
        enabled = try row.bool("enabled")
        recursive = try row.optionalInt("recursive").map { $0 != 0 }
        available = try row.bool("available")
        unavailableReason = try row.optionalString("unavailable_reason")
        unavailableAt = try row.optionalDate("unavailable_at")
        addedAt = try row.date("added_at")
        scannedAt = try row.optionalDate("scanned_at")
    }
}

/// One photo as a provider found it. Identifiers and metadata only; no bytes.
public struct DiscoveredPhoto: Sendable, Equatable {
    /// A `PHAsset` local identifier, a Google media item id, or — for folder
    /// sources — the path relative to the source's own path.
    public let externalID: String
    public let mediaType: MediaType
    /// Whether the bytes can go away, decided from *where the file lives*
    /// rather than from which provider found it.
    public let storage: PhotoStorage
    public let byteSize: Int64?

    public init(externalID: String, mediaType: MediaType, storage: PhotoStorage, byteSize: Int64?) {
        self.externalID = externalID
        self.mediaType = mediaType
        self.storage = storage
        self.byteSize = byteSize
    }
}

/// What a provider found, plus whether it could look at all.
public struct SourceEnumeration: Sendable, Equatable {
    public let photos: [DiscoveredPhoto]
    /// Nil when the source was reachable. Set when the source itself is gone —
    /// the volume is unmounted, the folder was deleted, the Photos library
    /// changed, permission was revoked.
    ///
    /// The provider reports this rather than the scanner inferring it, because
    /// only the provider can tell "the drive is not plugged in" from "the
    /// folder is empty".
    public let unavailableReason: String?

    public init(photos: [DiscoveredPhoto], unavailableReason: String? = nil) {
        self.photos = photos
        self.unavailableReason = unavailableReason
    }

    public static func unavailable(_ reason: String) -> SourceEnumeration {
        SourceEnumeration(photos: [], unavailableReason: reason)
    }

    public var isAvailable: Bool { unavailableReason == nil }
}
