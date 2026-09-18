import Foundation
import PhotoGoRoundAgentAPI
import PhotoGoRoundKit

/// What keeping a resized copy needs, carried onto the resizer's thread.
///
/// `/v1/next` and the dashboard's thumbnail both keep their resizes, and both
/// do it on `Resizer`'s thread, which is not the request's. A `PhotoCache` holds
/// a `Database`, which belongs to one isolation domain, so the cache is opened
/// there, from this.
struct CopyPlace: Sendable {
    let databasePath: String
    let cacheRoot: URL
    let settings: CacheSettings
    /// The process's one index, so an eviction after the copy sees every
    /// original held.
    let store: PhotoStore
    /// Told what the eviction after the copy took. See
    /// `PhotoCache.evictAfterWriting()`.
    let evicted: @Sendable (PhotoCache.EvictionResult) -> Void

    /// Handed the task that keeps the copy, for a caller that needs to know
    /// when the copy is on disk.
    ///
    /// **Nobody in the agent needs to know**, which is why the copy is written
    /// in a task of its own in the first place: the picture has gone out and
    /// the copy is for the next request. The tests do need to know, and a
    /// handle to await is the honest way to tell them — Syd, 2026-09-17: "can
    /// you do `await Task { }.run()` instead of a timer?" Polling for the row
    /// to appear asserts how fast this machine is.
    var kept: @Sendable (Task<Void, Never>) -> Void = { _ in }

    /// Keeps a copy in a task of its own, and hands that task to `kept`.
    ///
    /// **Its own task, not the resizer's thread.** Keeping became `async` when
    /// `PhotoStore` became an actor, and the resizer's work is synchronous by
    /// design — one resize at a time. Writing the copy off that thread also
    /// covers the resize nobody is waiting for any more: it still earns its
    /// copy. Syd, 2026-09-16: "save the copy of the file that did not finish
    /// resizing in 1 second. Maybe it will be asked for again."
    ///
    /// A copy that cannot be kept is logged and nothing else happens: the cache
    /// is an optimisation, never a reason to fail a request.
    @discardableResult
    func keeping(
        _ rendered: PhotoRenderer.Rendered, photoID: Int64, photoUUID: String,
        boxWidth: Int, boxHeight: Int, named: String
    ) -> Task<Void, Never> {
        let task = Task { [self] in
            do {
                try await open().keep(
                    rendered, photoID: photoID, photoUUID: photoUUID,
                    boxWidth: boxWidth, boxHeight: boxHeight)
            } catch {
                Log.cache.error(
                    kind: "cache.resized-copy-not-kept", "\(named) was not kept: \(error)")
            }
        }
        kept(task)
        return task
    }

    func open() throws -> PhotoCache {
        let database = try Database(path: databasePath)
        var cache = PhotoCache(
            database: database, root: cacheRoot, settings: settings,
            sources: SourceStore(database: database, bytes: store), store: store)
        cache.evicted = evicted
        return cache
    }
}
