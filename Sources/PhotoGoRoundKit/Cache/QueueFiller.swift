import Foundation
import PhotoGoRoundAgentAPI

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
    private let produce: @Sendable () async throws -> Bool
    private let lock = NSLock()
    private var running = false

    public init(
        isShort: @escaping @Sendable () -> Bool,
        produce: @escaping @Sendable () async throws -> Bool
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
        /// Why the round stopped, when it stopped because the deck could not be
        /// *asked* rather than because it had nothing to give.
        ///
        /// **These are opposite facts and they used to be the same value.**
        /// `produce` answered a plain `Bool` and the dealer reached it through
        /// `try?`, so a database that was merely busy — the ordinary state
        /// during a long refresh — arrived here as `exhausted`, which the whole
        /// system reads as *this library has nothing left*. The round then
        /// ended, silently, with a full pool behind it and no line in any log
        /// saying so. That is the shape of the 2026-08-25 outage.
        public let failure: String?

        public init(produced: Int, exhausted: Bool, skipped: Bool, failure: String? = nil) {
            self.produced = produced
            self.exhausted = exhausted
            self.skipped = skipped
            self.failure = failure
        }

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
            do {
                guard try await produce() else {
                    return Round(produced: produced, exhausted: true, skipped: false)
                }
            } catch {
                // **Not exhausted.** The deck was not asked and answered
                // nothing; it could not be asked at all. Saying so is the whole
                // point — a round that gives up has to leave a reason behind,
                // because a queue that stops filling looks identical from the
                // outside to a library that has run out.
                Log.deck.error(
                    "could not deal: \(String(describing: error), privacy: .public)")
                return Round(
                    produced: produced, exhausted: false, skipped: false,
                    failure: String(describing: error))
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
