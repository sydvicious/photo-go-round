import Foundation
import Synchronization
import Testing

@testable import photogoroundd

/// One walk per source at a time.
///
/// A refresh holds the database's single writer in bursts for as long as the
/// walk takes — six minutes for seven network folders on 2026-08-25 — so two
/// walks of the same source would double that contention while finding exactly
/// the same photographs.
@Suite("Refresh gate")
struct RefreshGateTests {

    @Test("A source being walked turns away a second ask for it")
    func secondAskForTheSameSourceIsDropped() {
        let gate = RefreshGate()
        #expect(gate.tryEnter(source: 7))
        #expect(!gate.tryEnter(source: 7))
        gate.leave(source: 7)
        #expect(gate.tryEnter(source: 7))
    }

    /// **The reason it is per source and not per pass.**
    ///
    /// A folder on a slow share must not hold up a local one queued behind it.
    /// A pass-wide gate would do exactly that, which is the opposite of why the
    /// walks run concurrently at all.
    @Test("A slow source does not gate any other source")
    func oneSourceDoesNotBlockAnother() {
        let gate = RefreshGate()
        #expect(gate.tryEnter(source: 1))
        #expect(gate.tryEnter(source: 2))
        #expect(gate.tryEnter(source: 3))
        #expect(gate.count == 3)
        // The slow one is still walking; the others finish and are askable again.
        gate.leave(source: 2)
        #expect(gate.tryEnter(source: 2))
        #expect(gate.isWalking(source: 1))
    }

    @Test("Leaving a source that was never entered is harmless")
    func leavingWithoutEnteringIsHarmless() {
        let gate = RefreshGate()
        gate.leave(source: 42)
        #expect(gate.count == 0)
        #expect(gate.tryEnter(source: 42))
    }

    /// Concurrent asks for one source admit exactly one of them.
    @Test("Exactly one of many simultaneous asks wins")
    func onlyOneConcurrentAskWins() async {
        let gate = RefreshGate()
        let admitted = Mutex(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    if gate.tryEnter(source: 9) { admitted.withLock { $0 += 1 } }
                }
            }
        }
        #expect(admitted.withLock { $0 } == 1)
    }
}
