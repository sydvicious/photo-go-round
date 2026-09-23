import Foundation
import PhotosGoRoundAgentAPI
import PhotosGoRoundKit

/// What the agent has done since it launched: pictures handed over, by
/// consumer, the last one handed over, what serving and dealing found in the
/// cache, and what eviction took from it.
///
/// **In memory, and gone at exit, on purpose.** The dashboard asks "since
/// launch", and a count that survived a restart would answer a different
/// question. `photo.times_delivered` is the durable per-photograph record; this
/// is the per-surface one, and nothing reads it but the dashboard.
actor LaunchTally {

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

    /// What a reporter hands over, and what the drain applies.
    ///
    /// **An `AsyncStream`, not a lock and not an `await`.** Syd, 2026-09-17:
    /// "AsyncStream for both". Every writer is a synchronous `@Sendable`
    /// closure the endpoints call — `evicted`, `lookedUp`, `dealLookedUp`, the
    /// fetch reporter — on whatever thread reached it, and none can `await`.
    /// `Continuation.yield` is safe from any thread, never suspends, and keeps
    /// the order the reports were made in.
    private enum Report: Sendable {
        case served(consumer: String, card: DeckCard?, source: Source?, at: Date)
        case serveLookup(CacheLookup)
        case dealLookup(DealLookup)
        case fetch(FetchOutcome)
        case eviction(PhotoCache.EvictionResult, at: Date)
        /// A caller waiting for everything ahead of it to have been applied.
        case barrier(CheckedContinuation<Void, Never>)
    }

    private nonisolated let inbox: AsyncStream<Report>
    private nonisolated let post: AsyncStream<Report>.Continuation

    private var servedCounts: [String: Int] = [:]
    private var last: LastServed?
    private var serveCounts = ServeLookups()
    private var fetchCounts = FetchLookups()
    private var evictionCounts = Evictions()
    /// When counting began, which is when the agent built this.
    let since: Date

    init(since: Date = Date()) {
        self.since = since
        (inbox, post) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        Task { await self.drain() }
    }

    private func drain() async {
        for await report in inbox {
            switch report {
            case .served(let consumer, let card, let source, let at):
                keepServed(consumer: consumer, card: card, source: source, at: at)
            case .serveLookup(let lookup): keep(lookup)
            case .dealLookup(let lookup): keep(lookup)
            case .fetch(let outcome): keep(fetch: outcome)
            case .eviction(let eviction, let now): keep(eviction, at: now)
            case .barrier(let continuation): continuation.resume()
            }
        }
    }

    /// Waits until everything reported before this call has been counted.
    ///
    /// The reports go through a queue, so a caller that records and then reads
    /// would otherwise be racing the drain. This puts itself in the same queue
    /// and waits its turn.
    nonisolated func settle() async {
        await withCheckedContinuation { continuation in post.yield(.barrier(continuation)) }
    }

    /// Keyed on the `consumer` the request named rather than on
    /// `ConsumerKind`'s constants, so a surface nobody listed — `cli`,
    /// `anonymous`, a widget — is counted instead of disappearing from a total
    /// that then disagrees with the console.
    ///
    /// Only a `200` is recorded. A `204` is a request that reached nobody.
    nonisolated func recordServed(
        consumer: String, card: DeckCard? = nil, source: Source? = nil, at: Date = Date()
    ) {
        post.yield(.served(consumer: consumer, card: card, source: source, at: at))
    }

    private func keepServed(consumer: String, card: DeckCard?, source: Source?, at: Date) {
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
    nonisolated func record(_ lookup: CacheLookup) { post.yield(.serveLookup(lookup)) }

    private func keep(_ lookup: CacheLookup) {
        switch lookup {
        case .hit: serveCounts.hits += 1
        case .miss(.landed): serveCounts.landed += 1
        case .miss(.timedOut): serveCounts.timedOut += 1
        case .miss(.leftDuringWait): serveCounts.leftDuringWait += 1
        case .miss(.droppedWithoutWaiting): serveCounts.droppedWithoutWaiting += 1
        }
    }

    /// One fetch-side lookup, as a card is dealt.
    nonisolated func record(_ lookup: DealLookup) { post.yield(.dealLookup(lookup)) }

    private func keep(_ lookup: DealLookup) {
        switch lookup {
        case .hit: fetchCounts.hits += 1
        case .miss: fetchCounts.misses += 1
        }
    }

    /// What became of one fetch.
    nonisolated func record(fetch outcome: FetchOutcome) { post.yield(.fetch(outcome)) }

    private func keep(fetch outcome: FetchOutcome) {
        switch outcome {
        case .fetched: fetchCounts.fetched += 1
        case .failed: fetchCounts.failed += 1
        case .timedOut: fetchCounts.timedOut += 1
        }
    }

    /// One eviction pass. A pass that evicted nothing is not counted.
    nonisolated func record(_ eviction: PhotoCache.EvictionResult, at now: Date = Date()) {
        post.yield(.eviction(eviction, at: now))
    }

    private func keep(_ eviction: PhotoCache.EvictionResult, at now: Date) {
        guard eviction.evicted > 0 else { return }
        evictionCounts.photos += eviction.evicted
        evictionCounts.bytesFreed += eviction.bytesFreed
        evictionCounts.passes += 1
        evictionCounts.lastAt = now
        evictionCounts.lastCeilingHalved = eviction.ceilingHalved
    }

    var evictions: Evictions {
        evictionCounts
    }

    var served: [String: Int] {
        servedCounts
    }

    var lastServed: LastServed? {
        last
    }

    var serveLookups: ServeLookups {
        serveCounts
    }

    var fetchLookups: FetchLookups {
        fetchCounts
    }
}
