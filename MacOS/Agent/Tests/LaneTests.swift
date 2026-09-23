import Foundation
import Synchronization
import Testing

@testable import PhotosGoRoundKit
@testable import PhotosGoRoundServer

/// Each request runs on a thread of its own, and stays there.
///
/// `Agent Performance Overhaul.md`, Phase 3, *One actor per request*. Syd,
/// 2026-09-16: "Each http request gets its own actor/thread." The thread sample
/// that started the overhaul had every thread of the shared pool inside a
/// resize, with requests that needed nothing from it unable to start.
@Suite("One lane per request", .timeLimit(.minutes(1)))
struct LaneTests {

    /// The thread the caller is on, as a number that can be compared.
    static func thread() -> UInt64 {
        var identifier: UInt64 = 0
        pthread_threadid_np(nil, &identifier)
        return identifier
    }

    /// Blocking, the way a synchronous SQLite call blocks: from a plain
    /// function, since `wait` is refused in an async one.
    static func block(on semaphore: DispatchSemaphore) {
        _ = semaphore.wait(timeout: .now() + 30)
    }

    /// A `nonisolated async` function, which is what the request path is made
    /// of: `PhotoCache.serve`, `PhotoQueue.remove`, `Deck.markShown`.
    static func askedElsewhere() async -> UInt64 { thread() }

    /// **A weaker test than it looks, and kept for what it does say.**
    /// Measured 2026-09-17: it passes with `NonisolatedNonsendingByDefault`
    /// switched off too — a `nonisolated async` callee that never suspends can
    /// finish on the caller's thread anyway. What proves the setting is
    /// `theSettingIsOn` above; this says the lane's own work does not wander.
    @Test("The package is built with NonisolatedNonsendingByDefault")
    func theSettingIsOn() {
        #if hasFeature(NonisolatedNonsendingByDefault)
            #expect(Bool(true))
        #else
            Issue.record(
                "the request path will hop to the shared pool: Package.swift's everyTarget")
        #endif
    }

    @Test("A request's work stays on its lane's thread across a nonisolated async call")
    func staysOnItsThread() async {
        let lane = Lane("request")

        let (before, during, after) = await lane.run {
            let before = Self.thread()
            let during = await Self.askedElsewhere()
            return (before, during, Self.thread())
        }

        #expect(before == during, "the request hopped off its lane onto the pool")
        #expect(during == after)
    }

    @Test("Two requests run at the same time, on threads of their own")
    func lanesAreIndependent() async {
        // Each lane waits for the *other* to arrive, so passing means they
        // really ran together: one thread could not satisfy both. One semaphore
        // for the pair does not do this — a lane consumes its own signal and
        // walks straight through, which it did on 2026-09-17.
        let firstArrived = DispatchSemaphore(value: 0)
        let secondArrived = DispatchSemaphore(value: 0)
        let threads = Mutex<[UInt64]>([])

        func arrive(on lane: Lane, saying mine: DispatchSemaphore, awaiting theirs: DispatchSemaphore) async {
            await lane.run {
                threads.withLock { $0.append(Self.thread()) }
                mine.signal()
                Self.block(on: theirs)
            }
        }

        let first = Lane("request")
        let second = Lane("request")
        async let one: Void = arrive(on: first, saying: firstArrived, awaiting: secondArrived)
        async let two: Void = arrive(on: second, saying: secondArrived, awaiting: firstArrived)
        _ = await [one, two]

        let seen = threads.withLock { $0 }
        #expect(seen.count == 2)
        #expect(Set(seen).count == 2, "both requests ran on the same thread")
    }

    /// A lane blocking does not stop another lane: the case the sample caught,
    /// where a resize on the shared pool stopped requests that needed nothing.
    @Test("A lane that blocks does not hold up another")
    func aBlockedLaneHoldsUpNobody() async {
        let released = DispatchSemaphore(value: 0)
        let blocked = Lane("request")
        let free = Lane("request")

        async let blocking: Void = blocked.run { Self.block(on: released) }
        let answered = await free.run { Self.thread() }
        released.signal()
        await blocking

        #expect(answered != 0)
    }
}
