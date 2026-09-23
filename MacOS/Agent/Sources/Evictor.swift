import Console
import Dispatch
import Foundation
import PhotosGoRoundAgentAPI
import PhotosGoRoundKit

/// Eviction, off the thread that wrote the file.
///
/// **Why this exists.** Syd, 2026-09-17: "you only need to use `await …` when
/// you need the result, or you need the side effect", and "async code is all
/// about getting stuff out of the way." A fetch that has just adopted an
/// original, and a resize that has just kept its copy, both used to wait for
/// the eviction that followed — and neither reads anything it does. The lane
/// they were holding is worth more than the few hundred milliseconds the
/// eviction takes.
///
/// **A `Task` on its own would not do it.** Eviction reads `resized`, builds
/// the order and writes in a transaction, all on a `Database`, and one
/// connection belongs to one isolation domain. So this owns a connection of its
/// own, on a thread of its own, and the writers only ring.
///
/// **Rings collapse, which is the other half of the point.** Ten cards fetched
/// in a burst ring ten times and get one pass, because `Doorbell` buffers the
/// newest ring alone. Awaiting gave the same *outcome* by a worse route: the
/// second writer's eviction found `PhotoStore.claimEviction()` taken, did
/// nothing, and had made its writer wait to find out.
///
/// `Plans/Agent Performance Overhaul.md`, Phase 5.
actor Evictor {

    /// A thread of its own, `utility`: nobody is waiting for this, and it is
    /// the one thing in the agent that is allowed to be behind.
    private let queue = DispatchSerialQueue(
        label: "com.sydpolk.photosgoround.evict", qos: .utility)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private let bell: Doorbell
    private let databasePath: String
    private let root: URL
    private let settings: CacheSettings
    private let store: PhotoStore
    private let report: @Sendable (PhotoCache.EvictionResult) -> Void

    /// Opened on the first ring and kept, rather than per pass: a connection
    /// costs a file open and a `PRAGMA` round, and this one is used for as long
    /// as the agent runs.
    private var cache: PhotoCache?

    /// How many passes this has made since launch — every ring it answered,
    /// including the ones that found nothing to take.
    ///
    /// **Rings are not passes, and the difference is the whole point.** A burst
    /// of writes rings many times and is answered once, because `Doorbell`
    /// buffers the newest ring alone. Counted rather than inferred, because
    /// what an eviction *took* says nothing about how often it looked.
    private(set) var passes = 0

    /// The bell comes from outside because the store is rung through it and the
    /// store is built first: `PhotoStore` holds the ring, this holds the loop,
    /// and the `Doorbell` is what joins them.
    init(
        bell: Doorbell, databasePath: String, root: URL, settings: CacheSettings,
        store: PhotoStore, report: @escaping @Sendable (PhotoCache.EvictionResult) -> Void
    ) {
        self.bell = bell
        self.databasePath = databasePath
        self.root = root
        self.settings = settings
        self.store = store
        self.report = report
    }

    /// One pass per ring, for as long as the agent runs. Started in a task of
    /// its own by `RunCommand`.
    func run() async {
        for await _ in bell.pulls {
            await evictOnce()
        }
    }

    /// Ends the loop, so the task it runs in finishes rather than being
    /// abandoned.
    nonisolated func stop() {
        bell.finish()
    }

    private func evictOnce() async {
        passes += 1
        do {
            let cache = try opened()
            let result = try await cache.evictIfNeeded()
            if result.evicted > 0 { report(result) }
        } catch {
            Console.alert(
                "eviction after a write failed: \(error)",
                recording: .kind("cache.eviction-failed"))
        }
    }

    private func opened() throws -> PhotoCache {
        if let cache { return cache }
        let database = try Database(path: databasePath)
        var made = PhotoCache(
            database: database, root: root, settings: settings,
            sources: SourceStore(database: database, bytes: store), store: store)
        made.log = RunCommand.speak
        cache = made
        return made
    }
}
