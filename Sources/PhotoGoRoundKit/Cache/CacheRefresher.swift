import Foundation
import PhotoGoRoundAgentAPI

/// Keeps the cache stocked, on its own initiative and at its own pace.
///
/// **The cache refreshes itself. Nothing asks it for a particular photograph.**
/// It picks a remote asset uniformly at random, does nothing if it already
/// holds it, and fetches it if it does not. That is the entire selection rule,
/// and the three pieces of the deck's shuffle it does *not* use are worth
/// naming, because their absence is a decision rather than an oversight:
///
/// - **No pass.** A pass exists so everyone gets a turn before anyone repeats.
///   A downloaded photograph is resident, and resident photographs are what
///   this draws from the complement of — so it cannot come round again while
///   others are still waiting. The guarantee is structural.
/// - **No repeat window.** The deck needs one because showing a photograph
///   leaves it in the pool. Downloading does not. To be worth downloading again
///   a photograph has to be evicted first, and eviction takes the longest
///   unseen — so it arrives as the newest thing in the cache and waits out a
///   whole turnover before it qualifies. A window would count that wait twice.
/// - **No shuffle key.** The random offset defeats a failure that needs a
///   persistent per-photograph quantity to exist: `ORDER BY key LIMIT 1` takes
///   the minimum, only the winner's key is re-rolled, so a high key loses,
///   keeps its high key *because* it never won, and loses again. A fresh
///   uniform draw has no memory to be unlucky in.
///
/// **This holds no database connection**, for the same reason `QueueFiller`
/// does not: a `Database` belongs to one isolation domain, so everything this
/// needs arrives as a closure the host implements with its own. What is left is
/// the credit arithmetic, which is the part worth asserting with no disk.
public final class CacheRefresher: @unchecked Sendable {

    /// What one draw did.
    public enum Draw: Sendable, Equatable {
        /// Bytes landed. **The only outcome that spends a credit.**
        case fetched
        /// Drawn and already held. Costs nothing and the refresher draws again
        /// — the budget buys photographs, not attempts.
        case alreadyHeld
        /// The provider could not deliver. No credit spent: the photograph was
        /// not obtained, so the allowance was not used.
        case failed
        /// The disk says stop, whatever the credits say.
        case blocked
        /// Nothing remote is left un-held.
        case exhausted
        /// Drawn from a source that is resting. Costs nothing and is not a
        /// failure — the source has already shown what it has to give, and
        /// spending the round's failure budget on it would let one dead share
        /// stop the healthy ones being fetched.
        case benched
    }

    public struct Round: Sendable, Equatable {
        public let fetched: Int
        public let skipped: Int
        public let failed: Int
        public let stopped: Stop

        public enum Stop: Sendable, Equatable {
            /// The allowance ran out. The ordinary ending.
            case spent
            case exhausted
            case blocked
            /// A round was already in progress and this call was dropped.
            case alreadyRunning
        }

        public static let alreadyRunning = Round(
            fetched: 0, skipped: 0, failed: 0, stopped: .alreadyRunning)
    }

    /// How many fetches run at once.
    ///
    /// **The lanes are the reason a slow source cannot stop a fast one.** A
    /// single-lane refresher spends its whole round waiting on whichever
    /// provider it happened to draw, and a library that spans a local folder
    /// and a network share then fetches at the speed of the share.
    private let concurrency: Int
    /// Twice the deck's maximum size. Read rather than stored, so changing the
    /// deck size at a terminal takes effect at the next round.
    private let budget: @Sendable () -> Int
    /// One draw. **It must always return**: a lane that never comes back holds
    /// the round open for ever, and the guard that drops overlapping rounds
    /// then drops every round after it. The agent satisfies this by running the
    /// fetch against `FetchDeadline`, which lets go of work that will not
    /// answer rather than waiting for it.
    private let attempt: @Sendable () async -> Draw
    /// How many remote assets are not held. Consulted when a round begins and
    /// occasionally during a long run of misses — never per draw.
    private let unheldCount: @Sendable () -> Int
    private let log: @Sendable (String) -> Void

    private let lock = NSLock()
    private var credits = 0
    private var running = false

    public init(
        budget: @escaping @Sendable () -> Int,
        unheldCount: @escaping @Sendable () -> Int,
        attempt: @escaping @Sendable () async -> Draw,
        concurrency: Int = 1,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.concurrency = max(1, concurrency)
        self.budget = budget
        self.unheldCount = unheldCount
        self.attempt = attempt
        self.log = log
    }

    /// How many misses in a row before the population is counted again.
    ///
    /// A nearly-full cache misses often and legitimately — at nine in ten held,
    /// ten draws buy one photograph — so a miss is not evidence of anything on
    /// its own. What this bounds is the one case that would otherwise spin
    /// forever: a library entirely resident, where every draw is a miss and no
    /// draw will ever not be. A `COUNT` every few hundred draws is nothing
    /// beside a fetch measured in seconds.
    static let missesBeforeRecount = 256

    /// How many fetches may fail in a row before the round gives up.
    ///
    /// A failure is free — it spends no credit — which is right, because the
    /// photograph was not obtained. It also means failures alone can never end
    /// a round, so an unreachable source would spin one for ever. Small,
    /// because a source that has refused this many times in a row is not about
    /// to answer the next one, and the allowance is still there for when it
    /// comes back.
    static let failuresBeforeGivingUp = 8

    // MARK: - Credits

    /// What the counter holds. For a status line, and for tests.
    public var available: Int {
        lock.lock()
        defer { lock.unlock() }
        return credits
    }

    /// Returns credits without starting anything.
    ///
    /// **Banked, deliberately.** A refresh that finds five hundred photographs
    /// gone would otherwise hand back five hundred credits and set an
    /// unattended agent downloading, which is exactly what the allowance exists
    /// to prevent. Only launch and a card being drawn start a round.
    public func bank(_ count: Int = 1) {
        guard count > 0 else { return }
        let cap = max(0, budget())
        lock.lock()
        credits = min(cap, credits + count)
        lock.unlock()
    }

    // MARK: - Starting a round

    /// Launch: a full allowance, then fetch until it is spent.
    ///
    /// The cache does not wait for anybody. This is what makes the cold start
    /// deadlock structurally impossible rather than bridged — with nothing
    /// dealt nothing can be served, and with nothing served nothing would be
    /// dealt, so something has to move without being asked.
    @discardableResult
    public func begin() async -> Round {
        grantFullAllowance()
        return await run()
    }

    /// In a non-async method for the same reason `QueueFiller.beginRound` is:
    /// `NSLock` is unavailable from an async context, because holding one
    /// across a suspension is exactly the bug that restriction exists to
    /// prevent.
    private func grantFullAllowance() {
        let cap = max(0, budget())
        lock.lock()
        credits = cap
        lock.unlock()
    }

    /// A card was drawn from the deck: one credit back, and go.
    ///
    /// In the steady state this is exactly one download per picture shown.
    @discardableResult
    public func cardDrawn() async -> Round {
        bank()
        return await run()
    }

    /// Fetches until the allowance is spent, the disk says stop, or there is
    /// nothing left to fetch.
    ///
    /// **Overlapping rounds are dropped rather than stacked**, as `QueueFiller`
    /// does and for the same reason: a fast consumer draws faster than fetches
    /// land, and without the guard the rounds would multiply against each other.
    /// The credits are not lost — the round already running spends them.
    private func run() async -> Round {
        guard claimRound() else { return .alreadyRunning }
        defer { releaseRound() }

        guard unheldCount() > 0 else {
            return Round(fetched: 0, skipped: 0, failed: 0, stopped: .exhausted)
        }

        // **Lanes share one credit counter and one stop.** Each draws for
        // itself, so there is no work list to hand between them — which is the
        // whole reason the backlog, its dedup set and its two pending counters
        // are gone. The counter is the only shared state and it is guarded.
        let tally = Tally()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask { await self.lane(tally) }
            }
        }
        return tally.round()
    }

    /// One lane: draw, act on the answer, repeat until the round is over.
    private func lane(_ tally: Tally) async {
        // **Claimed before the attempt, not spent after it.** Four lanes each
        // asking "are there credits left?" and then each spending one takes
        // four from a counter that held one — the round overshoots its
        // allowance by up to `concurrency - 1`, every time. The claim is one
        // locked operation, and anything that is not a landed photograph gives
        // it straight back.
        while claimCredit(), !tally.isFinished {
            switch await attempt() {
            case .fetched:
                tally.fetched()

            case .alreadyHeld, .benched:
                refund()
                if tally.skipped() >= Self.missesBeforeRecount {
                    guard unheldCount() > 0 else {
                        log("cache is complete; nothing remote left to fetch")
                        tally.finish(.exhausted)
                        return
                    }
                    tally.resetSkips()
                }

            case .failed:
                // **A failure spends no credit, so a source that fails every
                // time would loop for ever.** Nothing else ends the round: the
                // budget is untouched, the population still has un-held assets
                // in it, and the disk is fine.
                //
                // `SourceBench` is the real answer and works per source; this
                // is the backstop for the case it cannot see, where every
                // source is failing at once.
                refund()
                if tally.failed() >= Self.failuresBeforeGivingUp {
                    log("giving up this round after \(Self.failuresBeforeGivingUp) failures in a row")
                    tally.finish(.blocked)
                    return
                }

            case .blocked:
                refund()
                tally.finish(.blocked)
                return

            case .exhausted:
                refund()
                tally.finish(.exhausted)
                return
            }
        }
    }

    /// What the lanes did between them, and why they stopped.
    ///
    /// A class rather than counters on the stack, because the lanes share it.
    /// The consecutive-run counters are shared too, deliberately: eight
    /// failures in a row across four lanes is the same evidence as eight in one.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var fetchedCount = 0
        private var skippedCount = 0
        private var failedCount = 0
        private var skipRun = 0
        private var failRun = 0
        private var stop: Round.Stop?

        func fetched() {
            lock.lock()
            fetchedCount += 1
            skipRun = 0
            failRun = 0
            lock.unlock()
        }

        /// Answers the current run of skips.
        func skipped() -> Int {
            lock.lock()
            defer { lock.unlock() }
            skippedCount += 1
            skipRun += 1
            return skipRun
        }

        func resetSkips() {
            lock.lock()
            skipRun = 0
            lock.unlock()
        }

        /// Answers the current run of failures.
        func failed() -> Int {
            lock.lock()
            defer { lock.unlock() }
            failedCount += 1
            failRun += 1
            skipRun = 0
            return failRun
        }

        func finish(_ reason: Round.Stop) {
            lock.lock()
            if stop == nil { stop = reason }
            lock.unlock()
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stop != nil
        }

        func round() -> Round {
            lock.lock()
            defer { lock.unlock() }
            return Round(
                fetched: fetchedCount, skipped: skippedCount, failed: failedCount,
                stopped: stop ?? .spent)
        }
    }

    // MARK: - The counter, and the round guard

    /// Takes a credit if there is one. **One locked operation**, so lanes
    /// cannot each see the last credit and each spend it.
    ///
    /// In a non-async method because `NSLock` is unavailable from an async
    /// context — holding one across a suspension is the bug that restriction
    /// exists to prevent.
    private func claimCredit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard credits > 0 else { return false }
        credits -= 1
        return true
    }

    /// Gives a claimed credit back. The allowance buys photographs, so anything
    /// that is not a landed photograph costs nothing.
    private func refund() {
        lock.lock()
        credits += 1
        lock.unlock()
    }

    private func claimRound() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    private func releaseRound() {
        lock.lock()
        running = false
        lock.unlock()
    }
}
