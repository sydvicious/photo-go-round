import Foundation

/// Keeps the queue topped up.
///
/// **This is policy, not scheduling, and it lives in the kit for that reason.**
/// "Keep dealing while the queue is short and the deck still has something" is a
/// rule about the queue; which thread runs it and when the heartbeat fires are
/// the host's business.
///
/// Two things stop a round, and neither is a timer:
///
/// - **The queue reaching nominal.** Checked before every deal, so a queue that
///   fills mid-round stops the round.
/// - **A deck that answers *nothing*.** An empty library, or every eligible
///   photograph already queued.
///
/// **One card at a time, in one lane.** This used to run several lanes and to
/// take a list of sources, because producing a card meant fetching its bytes and
/// a source could cover its own latency with parallelism. Dealing no longer
/// fetches anything — it reads a row and writes a row — and the deck it deals
/// from is a single shuffle over the whole library rather than one per source.
/// Parallelism bought nothing and the source list decided nothing.
///
/// **It holds no database connection**, and that is deliberate rather than
/// incidental. A `Database` belongs to one isolation domain, so both facts this
/// needs are injected as closures the host implements with its own. What is left
/// is pure policy, which is what makes every rule above assertable with two mocks
/// and no disk.
public final class QueueFiller: @unchecked Sendable {
    private let isShort: @Sendable () -> Bool
    private let produce: @Sendable () async -> Bool
    private let lock = NSLock()
    private var running = false

    public init(
        isShort: @escaping @Sendable () -> Bool,
        produce: @escaping @Sendable () async -> Bool
    ) {
        self.isShort = isShort
        self.produce = produce
    }

    /// What a round did, for the caller that wants to say so.
    public struct Round: Sendable, Equatable {
        /// Cards added to the queue.
        public let produced: Int
        /// True when the deck ran dry before the queue filled.
        public let exhausted: Bool
        /// True when the round did not run because something else was already
        /// filling.
        public let skipped: Bool

        public static let alreadyRunning = Round(
            produced: 0, exhausted: false, skipped: true)
    }

    /// Fills until the queue reaches nominal or the deck has nothing left.
    ///
    /// **Overlapping calls are dropped rather than stacked.** Serving is what
    /// notices the queue has run short, so this is called once per picture handed
    /// over; without the guard, a fast consumer would start a round per request
    /// and they would multiply against each other.
    @discardableResult
    public func fill() async -> Round {
        guard beginRound() else { return .alreadyRunning }
        defer { endRound() }

        var produced = 0
        while isShort() {
            guard await produce() else {
                return Round(produced: produced, exhausted: true, skipped: false)
            }
            produced += 1
        }
        return Round(produced: produced, exhausted: false, skipped: false)
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
}
