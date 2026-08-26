import Foundation
import PhotoGoRoundAgentAPI
import Observation
import os

/// What the photo library holds, which of it is in play, and what a person has
/// typed to find it.
///
/// **The checkboxes are the source list, not a shopping basket.** A ticked
/// collection is one that is already a source or is about to become one; an
/// unticked one that used to be ticked is a source about to be removed. That is
/// what makes this a picker for *which collections are in play* rather than an
/// adder — there is one Photos library and it does not get added to twice.
@MainActor
@Observable
final class CollectionsModel {
    private let service: SourceService

    private(set) var library: SourceService.Library?
    /// The Photos sources that already exist, so a tick can start out true and
    /// an untick can find the source it has to remove.
    ///
    /// **Asked for here rather than handed in.** A `Window` scene takes no
    /// parameters, and the picker asking the agent for itself is the same
    /// arrangement as every other surface in this app.
    private(set) var existing: [SourceService.Source] = []
    /// What went wrong with the last thing asked, in words meant to be read.
    private(set) var trouble: String?
    private(set) var isWorking = false

    /// Identifiers currently ticked. Seeded from the sources that already
    /// exist, so opening the picker shows what is true rather than nothing.
    var chosen: Set<String> = []
    /// What the agent actually has, refreshed on every read. Compared against
    /// `chosen` to decide both whether there is anything to apply and what.
    private var wasChosen: Set<String> = []
    /// Whether the ticks have been seeded from reality yet.
    ///
    /// **Once per window, not once per read.** Seeding again would undo a tick
    /// somebody made while a poll was in flight; not seeding at all would open
    /// the picker showing nothing chosen when several are.
    private var seeded = false

    /// Sections the user has twisted shut, by section name.
    ///
    /// **Shut is the exception, so the set holds the closed ones.** A picker
    /// that opened with everything collapsed would hide the thing somebody came
    /// for behind four clicks.
    ///
    /// **This is what a search field would have been for.** Three hundred and
    /// fifty-three albums is not browsable as one list, and collapsing the
    /// three sections you are not looking in solves that with a control that is
    /// already there for its own reasons.
    private var collapsed: Set<String> = []

    private var poll: Task<Void, Never>?

    /// While the agent is still counting, ask again shortly. Listing is
    /// instant and counting a real library takes about forty seconds, so the
    /// numbers arrive during the time somebody spends reading the names.
    static let whileCounting = Duration.seconds(3)
    /// Once it has finished there is nothing left to arrive, and a picker is
    /// not a status display.
    static let whenSettled = Duration.seconds(30)

    init(service: SourceService) {
        self.service = service
    }

    convenience init() {
        self.init(
            service: SourceService(
                preferences: MacHostEnvironment(deployment: .development).preferences))
    }

    // MARK: - Reading

    func load() async {
        await reload()
    }

    /// Re-reads both halves: what the agent has, and what the library holds.
    ///
    /// **`existing` is re-read every time, and that is the fix for a real
    /// bug.** It used to be fetched once, guarded on `library == nil` — but a
    /// `Window` scene's model outlives the window closing, so the second time
    /// the picker opened it still held the sources from the first. Unticking
    /// something added since then found no source to name and skipped it, with
    /// no request and nothing in any log. Seen 2026-08-26.
    private func reload() async {
        do {
            existing = try await service.list().filter(\.isPhotosCollection)
            wasChosen = Set(existing.map(\.locator))
            if !seeded {
                chosen = wasChosen
                seeded = true
            }
            library = try await service.collections()
            trouble = nil
        } catch {
            trouble = SourcesModel.explain(error)
        }
    }

    func beginPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                let counting = self?.library?.isCounting ?? true
                try? await Task.sleep(for: counting ? Self.whileCounting : Self.whenSettled)
                guard !Task.isCancelled else { return }
                await self?.reload()
            }
        }
    }

    func endPolling() {
        poll?.cancel()
        poll = nil
    }

    // MARK: - What the list shows

    /// The sections, in Photos' own order. Empty until the first read lands.
    var visible: [SourceService.Library.Section] { library?.sections ?? [] }

    /// The four sections, each holding its folder tree.
    ///
    /// **Photos' own shape.** Four sections at the top; inside Albums, folders
    /// nest and albums sit under whichever one contains them. Flattening that
    /// was what made 31 titles indistinguishable, and it is also the structure
    /// somebody organising their library actually built.
    var tree: [PickerNode] {
        var out: [PickerNode] = []

        // **Favorites sits above the headings, on its own.** It is an album by
        // every technical measure and is not one by any other: it is the album
        // a person means when they say "the good ones", and burying it
        // alphabetically among three hundred others is filing it correctly and
        // hiding it. Photos puts it above its sidebar sections too, in a group
        // with no heading, and this is that group with one thing in it.
        if let favorites = Self.favorites(in: visible) {
            out.append(
                PickerNode(
                    id: favorites.identifier, title: favorites.title, depth: 0,
                    collection: favorites, children: []))
        }

        out += visible.map { section in
            PickerNode(
                id: section.section,
                title: section.title,
                depth: 0,
                collection: nil,
                children: Self.nodes(
                    // Removed from wherever it would otherwise have sorted, so
                    // it is at the top *instead of* rather than as well as.
                    in: section.collections.filter { $0.kind != Self.favoritesKind },
                    below: [], under: section.section, depth: 1))
        }
        return out
    }

    /// What the agent calls it — `LibraryCollectionKind.favorites`, over the
    /// wire as its raw value.
    private static let favoritesKind = "favorites"

    private static func favorites(
        in sections: [SourceService.Library.Section]
    ) -> SourceService.Library.Collection? {
        sections.lazy.flatMap(\.collections).first { $0.kind == favoritesKind }
    }

    /// The rows to draw beneath one section right now, in order, flattened.
    ///
    /// **Flattened here rather than recursed in the view.** A SwiftUI function
    /// returning `some View` cannot call itself — the opaque type would be
    /// defined in terms of itself — and nesting stacks inside a `LazyVStack`
    /// would cost the laziness anyway. A shut folder contributes its own row
    /// and nothing under it, so a closed tree builds nothing it does not draw.
    func rows(under section: PickerNode) -> [PickerNode] {
        var out: [PickerNode] = []
        func walk(_ nodes: [PickerNode]) {
            for node in nodes {
                out.append(node)
                guard !node.isAlbum, !isCollapsed(node.id) else { continue }
                walk(node.children)
            }
        }
        walk(section.children)
        return out
    }

    /// Splits one level: the collections that stop here, and the folders that
    /// go deeper.
    ///
    /// **Folders before albums, each sorted by name**, which is what Photos
    /// does and what somebody scanning for a name expects.
    private static func nodes(
        in collections: [SourceService.Library.Collection],
        below path: [String],
        under prefix: String,
        depth: Int
    ) -> [PickerNode] {
        let here = collections.filter { $0.folders.count == path.count }
        let deeper = collections.filter { $0.folders.count > path.count }

        var folders: [PickerNode] = []
        for name in Set(deeper.map { $0.folders[path.count] })
            .sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        {
            let mine = deeper.filter { $0.folders[path.count] == name }
            let id = "\(prefix)/\(name)"
            folders.append(
                PickerNode(
                    id: id, title: name, depth: depth, collection: nil,
                    children: nodes(in: mine, below: path + [name], under: id, depth: depth + 1)))
        }

        let albums =
            here
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map {
                PickerNode(
                    id: $0.identifier, title: $0.title, depth: depth, collection: $0,
                    children: [])
            }
        return folders + albums
    }

    func isCollapsed(_ section: String) -> Bool { collapsed.contains(section) }

    func toggle(_ section: String) {
        if collapsed.contains(section) {
            collapsed.remove(section)
        } else {
            collapsed.insert(section)
        }
    }

    /// Whether everything, something, or nothing beneath a node is ticked.
    ///
    /// **A folder is not a source, so this is a summary rather than a state of
    /// its own.** There is nothing to store: the answer is always derived from
    /// the albums underneath, which means it cannot drift out of step with
    /// them however they were ticked.
    enum Chosen {
        case none
        case some
        case all
    }

    func chosen(under node: PickerNode) -> Chosen {
        let albums = node.albums
        guard !albums.isEmpty else { return .none }
        let ticked = albums.reduce(0) { $0 + (chosen.contains($1.identifier) ? 1 : 0) }
        if ticked == 0 { return .none }
        return ticked == albums.count ? .all : .some
    }

    /// Ticks or unticks everything beneath a node in one act.
    ///
    /// **A mixed folder fills rather than empties.** Clicking a partly-ticked
    /// checkbox on this platform completes the set; somebody who wants it empty
    /// clicks once more and gets that.
    func chooseAll(under node: PickerNode) {
        let identifiers = node.albums.map(\.identifier)
        if chosen(under: node) == .all {
            chosen.subtract(identifiers)
        } else {
            chosen.formUnion(identifiers)
        }
    }

    /// How many albums are ticked anywhere beneath a node, so anything twisted
    /// shut still says whether something inside it is in play.
    func chosenCount(under node: PickerNode) -> Int {
        node.albums.reduce(0) { $0 + (chosen.contains($1.identifier) ? 1 : 0) }
    }

    var chosenCount: Int { chosen.count }

    var hasChanges: Bool { chosen != wasChosen }

    // MARK: - Applying

    /// Adds what was ticked and removes what was unticked, in that order.
    ///
    /// **Adding first**, so a mistake that refuses the batch leaves the library
    /// as it was rather than having already removed things.
    func apply() async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }

        let added = chosen.subtracting(wasChosen)
        let removed = wasChosen.subtracting(chosen)
        do {
            if !added.isEmpty { try await service.add(collections: Array(added)) }
            for locator in removed {
                // **Not skipped silently.** Removing needs the source's `uuid`
                // and this is the only place it can be looked up; a locator
                // with no source behind it means what this model believes has
                // come adrift from what the agent has, which is a fault to
                // surface rather than a row to pass over.
                guard let source = existing.first(where: { $0.locator == locator }) else {
                    trouble = "Could not remove one collection: the agent no longer lists it."
                    Log.sources.error(
                        "picker: no source for locator \(locator, privacy: .public) — not removed")
                    continue
                }
                try await service.remove(source.uuid)
            }
            wasChosen = chosen
            trouble = nil
            // The settings panel is showing the list these belong to, and it
            // polls on a timer measured in minutes.
            SourceChanges.shared.announce()
            return true
        } catch {
            trouble = SourcesModel.explain(error)
            return false
        }
    }

    // MARK: - Authorization

    func requestAccess() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await service.requestPhotoAccess()
            await reload()
        } catch {
            trouble = SourcesModel.explain(error)
        }
    }
}
