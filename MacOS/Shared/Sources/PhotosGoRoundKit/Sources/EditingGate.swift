import Foundation

/// One editor of the source list at a time, across suspensions.
///
/// **An async gate, not a lock.** Syd, 2026-09-17: "I flatout don't want
/// NSLocks". `SourceStore.editing` was an `NSRecursiveLock` held across the
/// write *and* the reconcile that projects it, because apart they are two acts:
/// a reconcile already under way with the old list puts a source straight back
/// after somebody removed it. Since `PhotoStore` became an actor the reconcile
/// suspends, and a lock may not be held across a suspension.
///
/// **An actor on its own would not do**, either: actors are re-entrant, so a
/// second editor would be let in while the first is awaiting — which is exactly
/// the overlap this exists to prevent. So the gate keeps a queue of waiters and
/// hands the turn on explicitly.
///
/// **Not recursive.** The lock it replaced was, and the nesting is gone with it:
/// the public entries take the gate and call the unguarded projection, rather
/// than re-entering through the public one.
public actor EditingGate {
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Waits for the turn. The caller must `release()` it, whatever happens —
    /// `SourceStore.editing(_:)` is the wrapper that guarantees it. Taking the
    /// two halves rather than a closure is deliberate: the work captures a
    /// `SourceStore`, which is not `Sendable` and must not be sent here.
    public func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    /// How many editors are waiting for the turn.
    ///
    /// For diagnostics and for the tests, which need to know a waiter is in the
    /// queue before the next one asks — the order the turn passes in cannot be
    /// asserted otherwise.
    public var waitingCount: Int { waiting.count }

    public func release() {
        guard !waiting.isEmpty else {
            held = false
            return
        }
        // The turn passes straight to the next in line rather than being
        // dropped and re-taken, so a queue of editors cannot be overtaken.
        waiting.removeFirst().resume()
    }
}
