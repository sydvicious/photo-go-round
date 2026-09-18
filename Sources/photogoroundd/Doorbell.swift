import Foundation

/// A ring from outside the agent — `defaults write`, another terminal adding a
/// source — carried to the loop that acts on it.
///
/// **An `AsyncStream`, not a flag behind a lock.** Syd, 2026-09-17: "I flatout
/// don't want NSLocks", and, of this one: "AsyncStream for the doorbell". The
/// notification arrives on a Dispatch queue with no `await` available, and
/// `AsyncStream.Continuation.yield` is the one thing that crosses that boundary
/// without a lock and without a `Task` hop: it is safe to call from any thread
/// and never suspends.
///
/// **Rings collapse.** The loop asks *has it rung since I last looked*, which is
/// what the flag meant too — three `defaults write`s between two ticks are one
/// re-read, not three. `bufferingNewest(1)` says that in the stream's own terms.
final class Doorbell: Sendable {
    private let rings: AsyncStream<Void>
    private let ring_: AsyncStream<Void>.Continuation

    init() {
        (rings, ring_) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// From the notification callback, on whatever queue it arrived on.
    func ring() {
        ring_.yield()
    }

    /// Every ring, in order, collapsed. The loop iterates this in a task of its
    /// own and records that it rang; see `RunCommand`.
    var pulls: AsyncStream<Void> { rings }

    func finish() {
        ring_.finish()
    }
}

/// What the loop reads at the top of a tick: whether the doorbell rang since the
/// last one.
actor Rang {
    private var rang = false

    func heard() { rang = true }

    /// Reads and clears, as the flag it replaced did.
    func take() -> Bool {
        let was = rang
        rang = false
        return was
    }
}
