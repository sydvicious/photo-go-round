import Foundation
import PhotoGoRoundAgentAPI

/// Fetches the bytes of every card the queue holds and does not yet have, head
/// first.
///
/// **The queue fetches its own cards.** A card is dealt whether or not its
/// bytes are here — see the plan's *Deal over everything, and the queue fetches
/// its own cards* — so something has to go and get them before the card's turn
/// comes. This is that thing, and it is started by filling: every deal that
/// puts a cold card on the queue kicks it.
///
/// It replaces `CacheRefresher`, which drew a remote asset at random and spent
/// a credit on it. The difference is the whole of the 2026-09-05 change: what
/// gets fetched is decided by the deal, not by a second draw, so a source added
/// to a running agent is fetched in proportion to its share of the deck rather
/// than trickling in one download per picture served. There is no credit
/// counter, because at a queue of twenty the depth bounds the work on its own.
///
/// **Head first**, because the card at the head is the one whose turn comes
/// next, and a queue of twenty at ten seconds a picture gives the tail two
/// hundred seconds of warning.
///
/// **Lanes**, so a slow source cannot stop a fast one — the same reason the
/// refresher had them. Each lane walks the queue for itself; the claim the host
/// takes when it hands a card over is what stops two lanes fetching the same
/// photograph.
///
/// **This holds no database connection**, for the same reason `QueueFiller`
/// does not: a `Database` belongs to one isolation domain, so both facts this
/// needs — what to fetch next, and fetch it — arrive as closures the host
/// implements with its own. What is left is pure policy, which is what makes
/// every rule above assertable with two mocks and no disk.
public actor QueueFetcher {

    /// What the host found when asked for the next card to fetch.
    public enum Next: Sendable {
        /// A card without bytes, claimed for this lane. `rank` is where it sits
        /// in the queue's order, so the lane can ask for the one after it;
        /// `within` is how long the fetch is allowed.
        case card(DeckCard, rank: Int64, within: Duration)
        /// A card from a source that is resting. Left where it is; the lane
        /// moves past it and it is looked at again on the next kick.
        case benched(rank: Int64)
        /// The disk says stop, and the round stops with it.
        case blocked
        /// Nothing queued is left to fetch.
        case drained
    }

    /// What one fetch did.
    public enum Outcome: Sendable, Equatable {
        case fetched
        case failed
        /// The provider never answered and the lane was taken back. The host
        /// has already told the bench.
        case timedOut
    }

    public struct Round: Sendable, Equatable {
        public let fetched: Int
        public let failed: Int
        /// Cards passed over because their source is benched.
        public let skipped: Int
        public let stopped: Stop

        public enum Stop: Sendable, Equatable {
            /// Every card that could be fetched has been. The ordinary ending.
            case drained
            case blocked
            /// A round was already in progress; this kick was noted and the
            /// running round will look again before it ends.
            case alreadyRunning
        }

        public init(fetched: Int, failed: Int, skipped: Int, stopped: Stop) {
            self.fetched = fetched
            self.failed = failed
            self.skipped = skipped
            self.stopped = stopped
        }

        public static let alreadyRunning = Round(
            fetched: 0, failed: 0, skipped: 0, stopped: .alreadyRunning)
    }

    private let concurrency: Int
    /// The next card to fetch after this rank in the queue, or nil for the head.
    /// **It must claim the card it answers with**, or two lanes will fetch it.
    private let next: @Sendable (Int64?) async -> Next
    /// One fetch, against the deadline given. **It must always return**: a lane
    /// that never comes back holds the round open for ever, and the guard that
    /// drops overlapping rounds then drops every round after it. The agent
    /// satisfies this with `FetchDeadline`.
    private let fetch: @Sendable (DeckCard, Duration) async -> Outcome
    private let log: @Sendable (String) -> Void

    /// **An actor, not a lock.** Syd, 2026-09-17: "I flatout don't want
    /// NSLocks", and, asked whether that held even where it makes synchronous
    /// code async: "I don't mind everything being async; I prefer it."
    /// `Agent Performance Overhaul.md`, Phase 5.
    private var running = false
    private var kickedWhileRunning = false
    /// This round's counters, which the lanes report into.
    private var tally = Tally()

    public init(
        concurrency: Int = CacheSettings.defaultConcurrency,
        next: @escaping @Sendable (Int64?) async -> Next,
        fetch: @escaping @Sendable (DeckCard, Duration) async -> Outcome,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.concurrency = max(1, concurrency)
        self.next = next
        self.fetch = fetch
        self.log = log
    }

    /// Something was dealt: fetch whatever is queued and not held.
    ///
    /// **Overlapping kicks are absorbed rather than stacked**, as `QueueFiller`
    /// does and for the same reason: a fill deals in bursts and would start a
    /// round per card. A kick that lands mid-round is remembered, and the round
    /// walks the queue once more from the head before it ends — so a card
    /// dealt after a lane saw *drained* is not left cold until the next deal.
    @discardableResult
    public func kick() async -> Round {
        guard claimRound() else { return .alreadyRunning }
        defer { releaseRound() }

        tally = Tally()
        repeat {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<concurrency {
                    group.addTask { await self.lane() }
                }
            }
        } while !tally.blocked && takePendingKick()
        return tally.round
    }

    /// One lane: walk the queue from the head, fetching what is cold and
    /// stepping past what is benched, until nothing is left or the disk says
    /// stop.
    /// **`@concurrent`, so the lanes are lanes.** A `nonisolated async`
    /// function runs on its caller's executor under
    /// `NonisolatedNonsendingByDefault`, and the caller here is this actor — so
    /// without it every lane would queue behind the last and `concurrency`
    /// would mean one. The fetching happens off the actor; what the lanes
    /// *count* goes back through it.
    @concurrent
    nonisolated private func lane() async {
        var after: Int64? = nil
        while await !isBlocked {
            switch await next(after) {
            case .card(let card, let rank, let limit):
                after = rank
                switch await fetch(card, limit) {
                case .fetched: await record(.fetched)
                case .failed, .timedOut: await record(.failed)
                }
            case .benched(let rank):
                after = rank
                await record(.skipped)
            case .blocked:
                log("fetching stopped: the disk says so")
                await record(.blocked)
                return
            case .drained:
                return
            }
        }
    }

    /// What the lanes did between them, and why they stopped. Plain state on
    /// the actor now: the lanes report into it rather than sharing a lock.
    private struct Tally {
        var fetchedCount = 0
        var failedCount = 0
        var skippedCount = 0
        var blocked = false

        var round: Round {
            Round(
                fetched: fetchedCount, failed: failedCount, skipped: skippedCount,
                stopped: blocked ? .blocked : .drained)
        }
    }

    private enum LaneOutcome { case fetched, failed, skipped, blocked }

    /// One lane's result, added to this round's.
    private func record(_ outcome: LaneOutcome) {
        switch outcome {
        case .fetched: tally.fetchedCount += 1
        case .failed: tally.failedCount += 1
        case .skipped: tally.skippedCount += 1
        case .blocked: tally.blocked = true
        }
    }

    /// Whether a lane has said the disk is full, which stops the others.
    private var isBlocked: Bool { tally.blocked }

    // MARK: - The round guard

    private func claimRound() -> Bool {
        guard !running else {
            kickedWhileRunning = true
            return false
        }
        running = true
        return true
    }

    private func releaseRound() {
        running = false
        kickedWhileRunning = false
    }

    /// Whether a kick landed while the round ran, cleared in the same breath.
    private func takePendingKick() -> Bool {
        let pending = kickedWhileRunning
        kickedWhileRunning = false
        return pending
    }
}
