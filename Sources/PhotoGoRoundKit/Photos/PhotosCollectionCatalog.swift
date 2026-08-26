import Foundation
import PhotoGoRoundAgentAPI

/// What the library holds, listed on demand and counted in the background.
///
/// **Because listing is cheap and counting is not.** Phase 1 measured 439
/// collections at 34 seconds to count — a flat ~78 ms round trip per album,
/// whatever its size — while fetching the collections themselves is
/// milliseconds. `estimatedAssetCount`, the documented way out, is `NSNotFound`
/// for every smart album, which is to say for Favorites and Live Photos and
/// everything else anybody actually asks for.
///
/// So a picker cannot be handed a counted list at a speed anybody would wait
/// for. It is handed the names at once and the numbers as they arrive: the
/// panel already re-reads on a timer, so a count appearing thirty seconds later
/// costs nothing and needs no push.
///
/// **Counts survive relisting and do not expire.** A collection is counted once
/// per agent lifetime; the count of an album somebody adds photographs to
/// afterwards goes stale, and that is accepted. It is a number beside a name in
/// a chooser, not anything the deck reads — and the alternative is re-paying 34
/// seconds of round trips on a schedule to keep a cosmetic figure current.
public actor PhotosCollectionCatalog {
    private let library: any PhotoLibrary

    /// The last listing, uncounted. Cheap enough to refresh on every ask, which
    /// is how a newly created album turns up without an invalidation rule.
    private var listed: [LibraryCollection] = []
    /// Identifier to image count, for everything counted so far.
    private var counts: [String: Int] = [:]
    /// Identifier to the folders containing it. Fetched once and kept: the
    /// walk is a handful of fetches, and a folder somebody creates mid-session
    /// is found at the next launch like anything else about the tree.
    private var folders: [String: [String]]?
    private var counting: Task<Void, Never>?

    public init(library: any PhotoLibrary) {
        self.library = library
    }

    /// Everything the library holds, grouped into Photos' four sections and
    /// sorted by name, carrying whatever counts are known so far.
    ///
    /// Starts the background count if it is not already running, so the first
    /// person to open a picker is what pays for it — an agent nobody opens a
    /// picker against never spends the 34 seconds at all.
    public func sections() async -> [LibrarySectionGroup] {
        let fresh = await library.collections()
        if folders == nil { folders = await library.folderPaths() }
        apply(fresh)
        startCounting()
        return LibrarySectionGroup.grouped(withKnownCounts())
    }

    /// Counts everything not yet counted, one at a time, and returns when there
    /// is nothing left.
    ///
    /// **Serial on purpose.** These are round trips to `photosd`, and the
    /// measurement that produced 78 ms apiece was serial; nothing suggests the
    /// daemon would answer several at once any faster, and a picker filling in
    /// slowly is not a problem worth risking the agent's responsiveness over.
    public func countEverything() async {
        let started = Date()
        var done = 0
        while let next = nextUncounted() {
            // Nil means the collection stopped resolving between the listing
            // and now. Zero is recorded rather than left absent, so it is not
            // retried on every pass forever.
            let count = await library.imageCount(ofCollection: next) ?? 0
            record(count, for: next)
            done += 1
        }
        guard done > 0 else { return }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Log.photos.notice(
            "counted \(done, privacy: .public) collections in \(elapsed, privacy: .public) ms"
        )
    }

    /// How far the background count has got, for anything that wants to say so.
    public func progress() -> (counted: Int, total: Int) {
        (counts.count, listed.count)
    }

    // MARK: - Keeping the two halves in step

    private func apply(_ fresh: [LibraryCollection]) {
        listed = fresh
        // A collection that has gone takes its count with it, so the dictionary
        // cannot grow across a session of somebody reorganising their library.
        let present = Set(fresh.map(\.identifier))
        counts = counts.filter { present.contains($0.key) }
    }

    private func withKnownCounts() -> [LibraryCollection] {
        listed.map { collection in
            let counted = counts[collection.identifier].map(collection.counted) ?? collection
            guard let path = folders?[collection.identifier], !path.isEmpty else { return counted }
            return counted.inside(path)
        }
    }

    private func nextUncounted() -> String? {
        listed.first { counts[$0.identifier] == nil }?.identifier
    }

    private func record(_ count: Int, for identifier: String) {
        counts[identifier] = count
    }

    /// **One counting task at a time.** Two pickers opening at once, or a panel
    /// polling while one is open, must not start two passes over the same 439
    /// round trips.
    private func startCounting() {
        guard counting == nil, nextUncounted() != nil else { return }
        counting = Task { [weak self] in
            await self?.countEverything()
            await self?.countingStopped()
        }
    }

    private func countingStopped() {
        counting = nil
    }
}
