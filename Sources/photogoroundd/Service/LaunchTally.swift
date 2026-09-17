import Foundation
import PhotoGoRoundAgentAPI
import PhotoGoRoundKit

/// What the agent has done since it launched: pictures handed over, by
/// consumer, the last one handed over, what serving and dealing found in the
/// cache, and what eviction took from it.
///
/// **In memory, and gone at exit, on purpose.** The dashboard asks "since
/// launch", and a count that survived a restart would answer a different
/// question. `photo.times_delivered` is the durable per-photograph record; this
/// is the per-surface one, and nothing reads it but the dashboard.
final class LaunchTally: @unchecked Sendable {

    /// The serve side of the cache's hit rate, by how each lookup ended. See
    /// `CacheLookup`. Almost always hits.
    struct ServeLookups: Codable, Equatable, Sendable {
        var hits = 0
        var landed = 0
        var timedOut = 0
        var leftDuringWait = 0
        var droppedWithoutWaiting = 0

        var misses: Int { landed + timedOut + leftDuringWait + droppedWithoutWaiting }
    }

    /// The fetch side of the cache's hit rate: what dealing found, and what
    /// became of the fetches. See `DealLookup`. On a large library, mostly
    /// misses.
    ///
    /// **The outcomes are not a breakdown of `misses`.** A miss whose card was
    /// served cold or dropped before its fetch finished has no outcome, and a
    /// fetch for a card dealt before launch has an outcome and no miss — so on a
    /// restart the outcomes can briefly outnumber the misses.
    struct FetchLookups: Codable, Equatable, Sendable {
        var hits = 0
        var misses = 0
        var fetched = 0
        var failed = 0
        var timedOut = 0
    }

    /// What became of one fetch, as the agent's fetch closure reports it.
    enum FetchOutcome: Sendable {
        case fetched
        case failed
        case timedOut
    }

    /// What eviction took from the cache.
    ///
    /// **The agent's own passes only**, which follow every file it writes to
    /// the cache — see `PhotoCache.evictAfterWriting()`. `pgr_ctl cache evict`
    /// and `cache clear` run in another process and are not seen here, and
    /// bytes that left because their photograph or source left the library are
    /// not evictions at all.
    struct Evictions: Codable, Equatable, Sendable {
        var photos = 0
        var bytesFreed: Int64 = 0
        /// Eviction passes that evicted anything.
        var passes = 0
        /// When the most recent of those passes ran. Absent until one has.
        var lastAt: Date? = nil
        /// Whether that pass was aiming at half the ceiling because free space
        /// was below `cacheCriticalFreeBytes` — eviction driven by the disk
        /// rather than by the cache's size.
        var lastCeilingHalved = false
    }

    /// The picture most recently handed over, named as it was at that moment.
    ///
    /// **The source's name is taken now**, not looked up when the dashboard
    /// asks: a source removed since still has the name it was served under.
    struct LastServed: Sendable, Equatable {
        var photo: Int64
        var sourceID: Int64
        /// The original filename when one was recorded, the identifier
        /// otherwise.
        var name: String
        var externalID: String
        var sourceName: String
        var consumer: String
        var at: Date
    }

    private let lock = NSLock()
    private var servedCounts: [String: Int] = [:]
    private var last: LastServed?
    private var serveCounts = ServeLookups()
    private var fetchCounts = FetchLookups()
    private var evictionCounts = Evictions()
    /// When counting began, which is when the agent built this.
    let since: Date

    init(since: Date = Date()) {
        self.since = since
    }

    /// Keyed on the `consumer` the request named rather than on
    /// `ConsumerKind`'s constants, so a surface nobody listed — `cli`,
    /// `anonymous`, a widget — is counted instead of disappearing from a total
    /// that then disagrees with the console.
    ///
    /// Only a `200` is recorded. A `204` is a request that reached nobody.
    func recordServed(
        consumer: String, card: DeckCard? = nil, source: Source? = nil, at: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        servedCounts[consumer, default: 0] += 1
        if let card {
            last = LastServed(
                photo: card.id, sourceID: card.sourceID,
                name: card.originalFilename ?? card.externalID, externalID: card.externalID,
                sourceName: source?.spokenName ?? "source \(card.sourceID)",
                consumer: consumer, at: at)
        }
    }

    /// One serve-side lookup.
    func record(_ lookup: CacheLookup) {
        lock.lock()
        defer { lock.unlock() }
        switch lookup {
        case .hit: serveCounts.hits += 1
        case .miss(.landed): serveCounts.landed += 1
        case .miss(.timedOut): serveCounts.timedOut += 1
        case .miss(.leftDuringWait): serveCounts.leftDuringWait += 1
        case .miss(.droppedWithoutWaiting): serveCounts.droppedWithoutWaiting += 1
        }
    }

    /// One fetch-side lookup, as a card is dealt.
    func record(_ lookup: DealLookup) {
        lock.lock()
        defer { lock.unlock() }
        switch lookup {
        case .hit: fetchCounts.hits += 1
        case .miss: fetchCounts.misses += 1
        }
    }

    /// What became of one fetch.
    func record(fetch outcome: FetchOutcome) {
        lock.lock()
        defer { lock.unlock() }
        switch outcome {
        case .fetched: fetchCounts.fetched += 1
        case .failed: fetchCounts.failed += 1
        case .timedOut: fetchCounts.timedOut += 1
        }
    }

    /// One eviction pass. A pass that evicted nothing is not counted.
    func record(_ eviction: PhotoCache.EvictionResult, at now: Date = Date()) {
        guard eviction.evicted > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        evictionCounts.photos += eviction.evicted
        evictionCounts.bytesFreed += eviction.bytesFreed
        evictionCounts.passes += 1
        evictionCounts.lastAt = now
        evictionCounts.lastCeilingHalved = eviction.ceilingHalved
    }

    var evictions: Evictions {
        lock.lock()
        defer { lock.unlock() }
        return evictionCounts
    }

    var served: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return servedCounts
    }

    var lastServed: LastServed? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    var serveLookups: ServeLookups {
        lock.lock()
        defer { lock.unlock() }
        return serveCounts
    }

    var fetchLookups: FetchLookups {
        lock.lock()
        defer { lock.unlock() }
        return fetchCounts
    }
}
