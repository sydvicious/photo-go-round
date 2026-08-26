import Foundation

/// One collection in the photo library, as a picker needs it.
///
/// **No PhotoKit types**, for the reason the whole seam exists: the grouping
/// and ordering rules below are judgment calls, and judgment belongs where a
/// test can reach it. `SystemPhotoLibrary` translates a `PHAssetCollection`
/// into this and decides nothing.
public struct LibraryCollection: Sendable, Equatable, Identifiable {
    /// The `PHAssetCollection` local identifier, which is what a source's
    /// locator holds.
    public let identifier: String
    /// `localizedTitle`, which is what a person calls it. Empty is possible and
    /// is not the same as absent.
    public let title: String
    public let kind: LibraryCollectionKind
    /// How many images it holds, or nil for *not counted yet*.
    ///
    /// **Optional because counting is not free and listing is.** Phase 1
    /// measured 439 collections at 34 seconds to count — a flat ~78 ms per
    /// album whether it holds one photograph or 95,901, which is a round trip
    /// rather than a scan. `estimatedAssetCount`, the documented cheap answer,
    /// is `NSNotFound` for *every* smart album, Favorites included. So nothing
    /// can list and count in one pass at a speed anybody would wait for, and
    /// the two are separate operations here.
    ///
    /// **Images only** when it is known, matching what would actually be
    /// served — videos are excluded at the fetch by predicate. So it will not
    /// agree with the number Photos shows for a collection holding videos, and
    /// the video-only smart albums read zero rather than nil.
    public let count: Int?
    /// The folders containing it, outermost first, or empty for a collection
    /// that sits at the top level.
    ///
    /// **This is how Photos tells two albums of the same name apart**, and it
    /// is the structure four flat sections throw away. Only user albums can be
    /// in a folder; a smart album is never in one.
    public let folders: [String]

    public var id: String { identifier }

    public init(
        identifier: String, title: String, kind: LibraryCollectionKind, count: Int? = nil,
        folders: [String] = []
    ) {
        self.identifier = identifier
        self.title = title
        self.kind = kind
        self.count = count
        self.folders = folders
    }

    public var section: LibrarySection { kind.section }

    /// The same collection with a count attached, for whatever fills them in.
    public func counted(_ count: Int) -> LibraryCollection {
        LibraryCollection(
            identifier: identifier, title: title, kind: kind, count: count, folders: folders)
    }

    /// The same collection, placed in the folder tree.
    public func inside(_ folders: [String]) -> LibraryCollection {
        LibraryCollection(
            identifier: identifier, title: title, kind: kind, count: count, folders: folders)
    }
}

/// What a collection *is*, one case per thing this project has an opinion
/// about.
///
/// **Coarser than `PHAssetCollectionSubtype` on purpose.** Fifteen subtypes say
/// "this album is about a kind of media" — Panoramas, Live Photos, Screenshots,
/// RAW — and every one of them is grouped identically, so they arrive here as
/// `.mediaType`. Translating a subtype to a case is mechanical and lives in the
/// PhotoKit binding; deciding what a case *means* is this file's job.
public enum LibraryCollectionKind: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// An album somebody made.
    case userAlbum
    /// Synced in from iTunes, long ago. Vanishingly rare and harmless to list.
    case syncedAlbum
    /// An iCloud Shared Album.
    case sharedAlbum
    /// My Photo Stream.
    case photoStream
    /// Imported from a camera or card. Photos files this under Utilities.
    case imported
    /// `smartAlbumUserLibrary` — every photograph, as one collection.
    case wholeLibrary
    case favorites
    case recentlyAdded
    case hidden
    case unableToUpload
    /// A smart album about the *kind* of media: Panoramas, Live Photos,
    /// Screenshots, Videos, Slo-mo, RAW, and the rest of that family.
    case mediaType
    /// A smart album this build has no opinion about — including any subtype
    /// Apple adds after it shipped. Listed rather than hidden: a collection a
    /// person can see in Photos and not here is a bug they cannot diagnose.
    case otherSmartAlbum
}

/// The four groups Photos' own sidebar uses.
///
/// **Four, not three.** Media Types sits between Sharing and Utilities and is
/// where Live Photos, Panoramas, Selfies and Screenshots live. Folding it into
/// Utilities puts the album this project's own spike was run against in the
/// drawer marked *miscellaneous*.
public enum LibrarySection: String, Sendable, Equatable, CaseIterable, Codable {
    case albums
    case sharing
    case mediaTypes
    case utilities

    /// What to call it on screen, matching Photos.
    public var title: String {
        switch self {
        case .albums: "Albums"
        case .sharing: "Sharing"
        case .mediaTypes: "Media Types"
        case .utilities: "Utilities"
        }
    }
}

extension LibraryCollectionKind {
    /// **Where Photos puts Library, Favorites and Recents is nowhere**, which
    /// is the one place this cannot match it: those three sit *above* the
    /// sidebar's sections, in a group with no heading. They are also three of
    /// the most useful things a person could choose, so they go in Albums
    /// rather than being hidden or given a fifth group of their own.
    public var section: LibrarySection {
        switch self {
        case .userAlbum, .syncedAlbum, .wholeLibrary, .favorites, .recentlyAdded: .albums
        case .sharedAlbum, .photoStream: .sharing
        case .mediaType: .mediaTypes
        case .imported, .hidden, .unableToUpload, .otherSmartAlbum: .utilities
        }
    }
}

/// One section of a picker: its heading, and what belongs under it.
public struct LibrarySectionGroup: Sendable, Equatable {
    public let section: LibrarySection
    public let collections: [LibraryCollection]

    public init(section: LibrarySection, collections: [LibraryCollection]) {
        self.section = section
        self.collections = collections
    }
}

extension LibrarySectionGroup {
    /// Groups collections into Photos' four sections, each sorted by name.
    ///
    /// **Sections keep their sidebar order; collections sort by name.** The
    /// order of the sections is a fact about Photos and never varies, so it is
    /// `LibrarySection.allCases`. Within one, nothing but the name means
    /// anything to a person looking for an album they made.
    ///
    /// **`localizedStandardCompare`**, so "Album 2" precedes "Album 10" and
    /// accented names land where the reader's language puts them.
    ///
    /// A section nothing falls into is omitted rather than shown empty. A
    /// library with no shared albums should not be told it has a Sharing
    /// section with nothing in it.
    public static func grouped(_ collections: [LibraryCollection]) -> [LibrarySectionGroup] {
        LibrarySection.allCases.compactMap { section in
            let members = collections
                .filter { $0.section == section }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            guard !members.isEmpty else { return nil }
            return LibrarySectionGroup(section: section, collections: members)
        }
    }
}
