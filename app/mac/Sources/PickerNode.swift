import Foundation

/// One line in the collection picker: a section, a folder, or an album.
///
/// **A folder is not a source and can never be ticked.** Photos folders hold
/// albums rather than photographs, so a folder row is a twisty and a label and
/// nothing else — `collection` being nil is what says so, rather than a flag
/// that could disagree with it.
struct PickerNode: Identifiable, Equatable {
    /// Stable across reads, because it is what the collapsed set remembers: a
    /// section's name, a folder's path under it, or an album's own identifier.
    let id: String
    let title: String
    /// How far in to indent. The tree is rendered as rows rather than as
    /// nested containers, so each row has to carry its own depth.
    let depth: Int
    /// Nil for a section or a folder.
    let collection: SourceService.Library.Collection?
    let children: [PickerNode]

    var isAlbum: Bool { collection != nil }

    /// Every album at or beneath this node, so a closed folder can still say
    /// how much is inside it and how much of that is chosen.
    var albums: [SourceService.Library.Collection] {
        if let collection { return [collection] }
        return children.flatMap(\.albums)
    }
}
