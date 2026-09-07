import Foundation

/// What a source whose locator does not name itself is called, and where it
/// sits — everything a person needs to recognise an album that is no longer
/// there.
///
/// A folder's path is its own description, so a file-backed source never has
/// one. A Photos album's identifier is `A1B2C3D4-…/L0/040`, which is why this
/// exists: the provider hands one back when the album is added and again on
/// every refresh that finds it, and the store keeps it beside the identifier.
/// See `Missing Albums Plan.md`.
public struct SourceDescription: Sendable, Equatable, Hashable {
    /// `localizedTitle` as the library gave it. Empty is a real answer — an
    /// untitled album — and is not the same as no description.
    public let title: String
    /// `LibraryCollectionKind`'s raw value: `userAlbum`, `favorites`, and so
    /// on. What tells a smart album from one somebody made, which is what
    /// decides whether the title means anything for matching.
    public let collectionKind: String
    /// The folders containing it, outermost first. Empty for a top-level album
    /// and for every smart album, which Photos never puts in a folder.
    public let folders: [String]

    public init(title: String, collectionKind: String, folders: [String] = []) {
        self.title = title
        self.collectionKind = collectionKind
        self.folders = folders
    }
}
