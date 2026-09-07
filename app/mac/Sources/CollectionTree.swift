import Foundation

/// Anything that can be laid out as Photos lays it out: a name, and the folders
/// containing it.
///
/// Two things in this app are — the collections a picker offers, and the
/// collections a panel reports on. They are different types over the same wire
/// and they must draw the same shape, or somebody who ticked *Trips › 2019 ›
/// Iceland* in one window finds it filed somewhere else in the other.
/// `nonisolated` throughout: this target compiles with `MainActor` as its
/// default isolation, and the values being arranged are plain `Sendable`
/// structs decoded off a wire. Sorting names into folders has no actor affinity
/// to give up.
nonisolated protocol Foldered: Identifiable, Equatable {
    /// What the tree keys on. An album's own identifier.
    var treeID: String { get }
    /// What to draw.
    var treeTitle: String { get }
    /// The folders containing it, outermost first. Empty at the top level and
    /// for every smart album, which Photos never puts in a folder.
    var treeFolders: [String] { get }
}

/// One line of a collection tree: a folder, or a collection itself.
///
/// **A folder is not a collection and can never be acted on.** Photos folders
/// hold albums rather than photographs, so a folder row is a label and nothing
/// else — `item` being nil is what says so, rather than a flag that could
/// disagree with it.
nonisolated struct FolderNode<Item: Foldered>: Identifiable, Equatable {
    /// Stable across reads, because the picker's collapsed set remembers it: a
    /// section's name, a folder's path under it, or a collection's identifier.
    let id: String
    let title: String
    /// How far in to indent. Both surfaces render the tree as rows rather than
    /// nested containers, so each row carries its own depth.
    let depth: Int
    /// Nil for a section or a folder.
    let item: Item?
    let children: [FolderNode<Item>]

    var isLeaf: Bool { item != nil }

    /// Every collection at or beneath this node, so a closed folder can still
    /// say how much is inside it and how much of that is chosen.
    var items: [Item] {
        if let item { return [item] }
        return children.flatMap(\.items)
    }
}

nonisolated extension FolderNode {
    /// Splits one level: what stops here, and what goes deeper.
    ///
    /// **Folders before collections, each sorted by name**, which is what Photos
    /// does and what somebody scanning for a name expects.
    ///
    /// **One implementation, used by both windows.** It was written once for the
    /// picker and the panel had a flat list; when the panel grew a tree, copying
    /// thirty lines of sorting and recursion would have been two rules that
    /// agree until somebody edits one.
    static func tree(
        of items: [Item], below path: [String] = [], under prefix: String = "", depth: Int = 0
    ) -> [FolderNode<Item>] {
        let here = items.filter { $0.treeFolders.count == path.count }
        let deeper = items.filter { $0.treeFolders.count > path.count }

        var folders: [FolderNode<Item>] = []
        for name in Set(deeper.map { $0.treeFolders[path.count] })
            .sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        {
            let mine = deeper.filter { $0.treeFolders[path.count] == name }
            let id = "\(prefix)/\(name)"
            folders.append(
                FolderNode(
                    id: id, title: name, depth: depth, item: nil,
                    children: tree(of: mine, below: path + [name], under: id, depth: depth + 1)))
        }

        let leaves =
            here
            .sorted { $0.treeTitle.localizedStandardCompare($1.treeTitle) == .orderedAscending }
            .map {
                FolderNode(id: $0.treeID, title: $0.treeTitle, depth: depth, item: $0, children: [])
            }
        return folders + leaves
    }

    /// The rows to draw beneath one node right now, in order, flattened.
    ///
    /// **Flattened here rather than recursed in the view.** A SwiftUI function
    /// returning `some View` cannot call itself — the opaque type would be
    /// defined in terms of itself — and nesting stacks inside a `LazyVStack`
    /// would cost the laziness anyway. A shut folder contributes its own row and
    /// nothing under it, so a closed tree builds nothing it does not draw.
    static func rows(
        under nodes: [FolderNode<Item>], isCollapsed: (String) -> Bool = { _ in false }
    ) -> [FolderNode<Item>] {
        var out: [FolderNode<Item>] = []
        func walk(_ nodes: [FolderNode<Item>]) {
            for node in nodes {
                out.append(node)
                guard !node.isLeaf, !isCollapsed(node.id) else { continue }
                walk(node.children)
            }
        }
        walk(nodes)
        return out
    }
}

nonisolated extension SourceService.Library.Collection: Foldered {
    var treeID: String { identifier }
    var treeTitle: String { title }
    var treeFolders: [String] { folders }
}

nonisolated extension SourceService.Source: Foldered {
    var treeID: String { uuid }
    var treeTitle: String { name }
    var treeFolders: [String] { folderPath }
}

/// One line of the Settings panel's collection list: a folder, or a source.
///
/// The panel's counterpart to `PickerNode`, over the same builder — which is
/// what makes the two windows agree about where an album sits.
typealias SourceNode = FolderNode<SourceService.Source>
