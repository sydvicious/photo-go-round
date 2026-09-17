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

    func open() throws -> PhotoCache {
        let database = try Database(path: databasePath)
        var cache = PhotoCache(
            database: database, root: cacheRoot, settings: settings,
            sources: SourceStore(database: database, bytes: store), store: store)
        cache.evicted = evicted
        return cache
    }
}
