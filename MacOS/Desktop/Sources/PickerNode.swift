import Foundation

/// One line in the collection picker.
///
/// **The shape is `FolderNode`'s**, which the Settings panel draws too — the
/// two windows must agree about where an album sits, or somebody who ticked
/// *Trips › 2019 › Iceland* in one finds it filed somewhere else in the other.
/// This name stays because the picker is written in terms of it throughout, and
/// because *picker node* is what the thing is called in conversation.
typealias PickerNode = FolderNode<SourceService.Library.Collection>

extension PickerNode {
    /// **A folder is not an album and can never be ticked.** Photos folders hold
    /// albums rather than photographs, so a folder row is a twisty and a label
    /// and nothing else.
    var isAlbum: Bool { isLeaf }

    /// Every album at or beneath this node, so a closed folder can still say how
    /// much is inside it and how much of that is chosen.
    var albums: [SourceService.Library.Collection] { items }
}
