import Foundation

/// Keeps the queue topped up.
///
/// **This is policy, not scheduling, and it lives in the kit for that reason.**
/// "Keep asking while the queue is short and this source still has something" is
/// a rule about the queue; which thread runs it and when the heartbeat fires are
/// the host's business.
///
/// Two things stop it, and neither is a timer:
///
/// - **The queue reaching nominal.** Checked before every ask, so a queue that
///   fills mid-round stops the round.
/// - **A source that answers *nothing*.** Remembered for the rest of the round,
///   which is what keeps an exhausted library from spinning, and is the only
///   stopping condition needed.
///
/// **It holds no database connection**, and that is deliberate rather than
/// incidental. A `Database` belongs to one isolation domain, and this runs
/// several lanes at once — so both facts it needs are injected as closures the
/// host implements with its own connections. What is left is pure policy, which
/// is what makes every rule above assertable with two mocks and no disk.
public final class QueueFiller: @unchecked Sendable {
    /// How many pictures one source is asked for at once, when a round does not
    /// say otherwise. Fetching is nearly all latency, so a single request in
    /// flight leaves a provider idle for the duration of its own I/O — and it is
    /// per round rather than per instance so that changing the preference takes
    /// effect at the next fill rather than at the next launch.
    public let concurrency: Int

    private let isShort: @Sendable () -> Bool
    private let produce: @Sendable (Int64) async -> Bool
    private let lock = NSLock()
    private var running = false

    /// Enough to keep a provider's latency covered without turning a rescan into
    /// a thundering herd against one disk. Four is the number every package
    /// manager settled on, for the same reason: fetching is nearly all latency.
    public static let defaultConcurrency = 4

    public init(
        concurrency: Int = QueueFiller.defaultConcurrency,
        isShort: @escaping @Sendable () -> Bool,
        produce: @escaping @Sendable (Int64) async -> Bool
    ) {
        self.concurrency = max(1, concurrency)
        self.isShort = isShort
        self.produce = produce
    }

    /// What a round did, for the caller that wants to say so.
    public struct Round: Sendable, Equatable {
        /// Pictures added to the queue.
        public let produced: Int
        /// Sources that answered *nothing* and were dropped for the round.
        public let exhausted: Int
        /// True when the round did not run because something else was already
        /// filling.
        public let skipped: Bool

        public static let alreadyRunning = Round(produced: 0, exhausted: 0, skipped: true)
    }

    /// Fills until the queue reaches nominal or every source has nothing left.
    ///
    /// **Overlapping calls are dropped rather than stacked.** Serving is what
    /// notices the queue has run short, so this is called once per picture handed
    /// over; without the guard, a fast consumer would start a round per request
    /// and they would multiply against each other.
    @discardableResult
    public func fill(sources: [Int64], concurrency: Int? = nil) async -> Round {
        guard beginRound() else { return .alreadyRunning }
        defer { endRound() }

        guard !sources.isEmpty, isShort() else {
            return Round(produced: 0, exhausted: 0, skipped: false)
        }

        let tally = Tally()
        await withTaskGroup(of: Void.self) { group in
            for sourceID in sources {
                // One lane per concurrent fetch this source is willing to run.
                // Each lane keeps asking until the source or the queue says stop,
                // which is what makes filling proceed at the rate the providers
                // manage rather than at the rate a clock happens to have.
                for _ in 0..<max(1, concurrency ?? self.concurrency) {
                    group.addTask { [self] in
                        while !tally.isExhausted(sourceID), isShort() {
                            if await produce(sourceID) {
                                tally.produced()
                            } else {
                                tally.exhaust(sourceID)
                            }
                        }
                    }
                }
            }
        }
        return tally.round()
    }

    /// Claiming the round, in a non-async method because `NSLock` is unavailable
    /// from an async context — holding one across a suspension is exactly the bug
    /// that restriction exists to prevent.
    private func beginRound() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    private func endRound() {
        lock.lock()
        running = false
        lock.unlock()
    }

    /// Tallying lives in its own type for the same reason: every mutation is a
    /// non-async method, so no lock is ever held across a suspension.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var exhausted: Set<Int64> = []
        private var count = 0

        func isExhausted(_ sourceID: Int64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return exhausted.contains(sourceID)
        }

        func exhaust(_ sourceID: Int64) {
            lock.lock()
            exhausted.insert(sourceID)
            lock.unlock()
        }

        func produced() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func round() -> Round {
            lock.lock()
            defer { lock.unlock() }
            return Round(produced: count, exhausted: exhausted.count, skipped: false)
        }
    }
}
