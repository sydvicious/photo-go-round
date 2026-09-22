import Foundation
import Synchronization
import Testing

@testable import PhotoGoRoundKit

/// One editor of the source list at a time, across suspensions.
///
/// Syd, 2026-09-17: "I flatout don't want NSLocks". The `NSRecursiveLock` this
/// replaced could not survive `PhotoStore` becoming an actor — the reconcile it
/// was held around now suspends — and an actor on its own would not do either,
/// because actors are re-entrant and a second editor would be let in while the
/// first was awaiting. `Plans/Agent Performance Overhaul.md`, Phase 5.
@Suite("The editing gate", .timeLimit(.minutes(1)))
struct EditingGateTests {

    /// The high-water mark of editors inside the gate at once.
    private final class Overlap: Sendable {
        private let state = Mutex((current: 0, peak: 0))
        func enter() { state.withLock { $0.current += 1; $0.peak = max($0.peak, $0.current) } }
        func leave() { state.withLock { $0.current -= 1 } }
        var peak: Int { state.withLock { $0.peak } }
    }

    /// Yields until something is true, with no deadline of its own.
    ///
    /// **A deadline here is a guess about the machine, not about the gate.**
    /// Syd, 2026-09-17: "can you do `await Task { }.run()` instead of a timer?"
    /// An earlier version gave up after ten seconds and recorded an issue:
    /// these three tests take 15 ms alone, and two of them failed that way in a
    /// full parallel run on 2026-09-17, because a waiter had not been given a
    /// thread — nothing to do with the gate. A gate that genuinely never hands
    /// the turn on hangs, and the suite's `.timeLimit` is what says so.
    private static func until(_ reached: @Sendable () async -> Bool) async {
        while await !reached() { await Task.yield() }
    }

    /// **The whole point, and what an actor alone would not give.** Every one
    /// of these suspends while holding the turn, which is where a re-entrant
    /// actor would let the next one in.
    @Test("Editors never overlap, though each one suspends while it holds the turn")
    func oneEditorAtATime() async {
        let gate = EditingGate()
        let overlap = Overlap()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.acquire()
                    overlap.enter()
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(1))
                    overlap.leave()
                    await gate.release()
                }
            }
        }

        #expect(overlap.peak == 1, "two editors were inside the gate at once")
    }

    @Test("A waiter gets the turn when the holder releases it")
    func releaseHandsTheTurnOn() async {
        let gate = EditingGate()
        let through = Mutex(false)
        await gate.acquire()

        Task {
            await gate.acquire()
            through.withLock { $0 = true }
            await gate.release()
        }
        await Self.until { await gate.waitingCount == 1 }
        #expect(through.withLock { $0 } == false, "it went through while the gate was held")

        await gate.release()

        await Self.until { through.withLock { $0 } }
    }

    /// **The turn passes straight to the next in line**, rather than being
    /// dropped for whoever the scheduler wakes first: a queue of editors cannot
    /// be overtaken, so a removal cannot land behind a reconcile that was asked
    /// for after it.
    @Test("The turn passes in the order it was asked for")
    func theQueueIsNotOvertaken() async {
        let gate = EditingGate()
        let order = Mutex<[Int]>([])
        await gate.acquire()

        for index in 0..<4 {
            Task {
                await gate.acquire()
                order.withLock { $0.append(index) }
                await gate.release()
            }
            // Queued before the next one asks, so the order asserted below is
            // the order they asked in and not the order they happened to start.
            await Self.until { await gate.waitingCount == index + 1 }
        }

        await gate.release()
        await Self.until { order.withLock { $0.count } == 4 }

        #expect(order.withLock { $0 } == [0, 1, 2, 3])
    }
}
