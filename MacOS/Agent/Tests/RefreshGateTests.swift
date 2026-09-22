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
    func secondAskForTheSameSourceIsDropped() async {
        let gate = RefreshGate()
        #expect(await gate.tryEnter(source: 7))
        #expect(await !gate.tryEnter(source: 7))
        await gate.leave(source: 7)
        #expect(await gate.tryEnter(source: 7))
    }

    /// **The reason it is per source and not per pass.**
    ///
    /// A folder on a slow share must not hold up a local one queued behind it.
    /// A pass-wide gate would do exactly that, which is the opposite of why the
    /// walks run concurrently at all.
    @Test("A slow source does not gate any other source")
    func oneSourceDoesNotBlockAnother() async {
        let gate = RefreshGate()
        #expect(await gate.tryEnter(source: 1))
        #expect(await gate.tryEnter(source: 2))
        #expect(await gate.tryEnter(source: 3))
        #expect(await gate.count == 3)
        // The slow one is still walking; the others finish and are askable again.
        await gate.leave(source: 2)
        #expect(await gate.tryEnter(source: 2))
        #expect(await gate.isWalking(source: 1))
    }

    @Test("Leaving a source that was never entered is harmless")
    func leavingWithoutEnteringIsHarmless() async {
        let gate = RefreshGate()
        await gate.leave(source: 42)
        #expect(await gate.count == 0)
        #expect(await gate.tryEnter(source: 42))
    }

    /// Concurrent asks for one source admit exactly one of them.
    @Test("Exactly one of many simultaneous asks wins")
    func onlyOneConcurrentAskWins() async {
        let gate = RefreshGate()
        let admitted = Mutex(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    if await gate.tryEnter(source: 9) { admitted.withLock { $0 += 1 } }
                }
            }
        }
        #expect(admitted.withLock { $0 } == 1)
    }
}
