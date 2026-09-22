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
    /// What went wrong with the last thing a person **asked for**, in words
    /// meant to be read: applying a set of ticks, or granting access.
    private(set) var trouble: String?

    /// Why the last read did not work, when it did not.
    ///
    /// **Separate from `trouble`, and quieter**, exactly as in `SourcesModel`.
    /// This picker polls every few seconds while counts are arriving, and a
    /// poll that failed is not something anybody clicked. Reporting it beside
    /// the Done button puts a failure notice under a list that is still
    /// perfectly good, every few seconds, for as long as the library is unwell.
    ///
    /// **Shown only when there is nothing else to show** — which here means
    /// `library == nil`, the picker having never managed to read one. A picker
    /// that has three hundred albums on screen keeps them and says nothing.
    ///
    /// `SourcesModel` spells that condition `hasRead`, because an empty source
    /// list is ambiguous — nothing found and nothing asked look identical. Here
    /// it is not: `library` is nil until an answer lands, so the state already
    /// exists and a second flag beside it could only ever disagree with it.
    private(set) var readFailure: String?
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

    /// **The window opened**, which is not the same as a poll.
    ///
    /// A `Window` scene's model outlives its window — the same fact that made
    /// `existing` stale on a second open — so a fresh visit inherits everything
    /// the last one left behind, including the reason the last one failed.
    /// Reopening the picker after the agent went quiet would show that
    /// sentence again immediately, beside an attempt that may be about to
    /// succeed: a picker saying *the agent is not answering* about an agent
    /// that is.
    ///
    /// So a visit forgets what the last one concluded and asks again. The ticks
    /// go with it: they described the source list as it stood when the last
    /// window opened, and anything could have changed it since — including this
    /// same picker, earlier.
    ///
    /// **`library` is deliberately not cleared.** Three hundred albums from five
    /// minutes ago is a better thing to be looking at while the question is
    /// asked than a blank panel, and the answer replaces them either way.
    func load() async {
        trouble = nil
        readFailure = nil
        seeded = false
        await refresh()
    }

    /// Re-reads both halves: what the agent has, and what the library holds,
    /// **leaving the ticks as they are**.
    ///
    /// This is the poll. `load` is the other entry point, and the difference
    /// between them is exactly the seeding: a poll must never undo a tick
    /// somebody made while it was in flight, and a visit must never inherit the
    /// last one's.
    ///
    /// **`existing` is re-read every time, and that is the fix for a real
    /// bug.** It used to be fetched once, guarded on `library == nil` — but a
    /// `Window` scene's model outlives the window closing, so the second time
    /// the picker opened it still held the sources from the first. Unticking
    /// something added since then found no source to name and skipped it, with
    /// no request and nothing in any log. Seen 2026-08-26.
    func refresh() async {
        do {
            existing = try await service.list().filter(\.isPhotosCollection)
            wasChosen = Set(existing.map(\.locator))
            if !seeded {
                chosen = wasChosen
                seeded = true
            }
            library = try await service.collections()
            readFailure = nil
        } catch {
            // Recorded and logged, not put beside the controls: a poll that
            // failed is not something this window did. See `readFailure`.
            readFailure = SourcesModel.explain(error)
            Log.sources.error(
                "picker: read failed — \(self.readFailure ?? "", privacy: .public)")
        }
    }

    func beginPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                let counting = self?.library?.isCounting ?? true
                try? await Task.sleep(for: counting ? Self.whileCounting : Self.whenSettled)
                guard !Task.isCancelled else { return }
                await self?.refresh()
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
                    item: favorites, children: []))
        }

        out += visible.map { section in
            PickerNode(
                id: section.section,
                title: section.title,
                depth: 0,
                item: nil,
                children: PickerNode.tree(
                    // Removed from wherever it would otherwise have sorted, so
                    // it is at the top *instead of* rather than as well as.
                    of: section.collections.filter { $0.kind != Self.favoritesKind },
                    under: section.section, depth: 1))
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
    /// **The rule lives in `FolderNode`**, so the panel draws the same tree
    /// this window does. It was written here first, when the panel had a flat
    /// list; two copies of thirty lines of sorting and recursion agree until
    /// somebody edits one.
    func rows(under section: PickerNode) -> [PickerNode] {
        PickerNode.rows(under: section.children, isCollapsed: isCollapsed)
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
        let albums = node.items
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
        let identifiers = node.items.map(\.identifier)
        if chosen(under: node) == .all {
            chosen.subtract(identifiers)
        } else {
            chosen.formUnion(identifiers)
        }
    }

    /// How many albums are ticked anywhere beneath a node, so anything twisted
    /// shut still says whether something inside it is in play.
    func chosenCount(under node: PickerNode) -> Int {
        node.items.reduce(0) { $0 + (chosen.contains($1.identifier) ? 1 : 0) }
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
            // A read rather than a fresh visit: consent was granted *inside*
            // this visit, and reseeding here would drop a tick made before the
            // button was pressed.
            await refresh()
        } catch {
            trouble = SourcesModel.explain(error)
        }
    }
}
