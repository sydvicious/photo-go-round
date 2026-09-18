import Dispatch
import Foundation
import Synchronization

/// A bound on how long a client will wait for an answer.
///
/// **An agent that refuses the connection is the easy case.** It answers at
/// once, `URLError` says so, and every surface already has words for it. The
/// hard case is the agent that accepts the connection and then says nothing —
/// which is what a wedged `photolibraryd` does to it, since a PhotoKit call
/// parked on a cooperative thread costs the runtime a thread and enough of them
/// stop the agent answering anything at all. From the client's side those two
/// look identical for as long as the silence lasts, and the second one lasts
/// until something gives up.
///
/// This is the thing that gives up.
///
/// **The work is cancelled and then let go of, and both halves matter.**
/// Cancelling is what releases the socket when the transport cooperates —
/// `URLSession` does. Not waiting for it is what makes this useful when the
/// transport does not: a structured child would be awaited at scope exit, which
/// is precisely the wait being escaped. So the work goes into an unstructured
/// task, is asked to stop, and is not watched.
///
/// **`FetchDeadline` in the kit is the same idea and deliberately not this.**
/// That one bounds a cache lane: the work returns nothing, must never be
/// cancelled — a read blocked inside `bird` does not answer cancellation and
/// the lane is what needs releasing — and its caller wants to hear about work
/// that comes back late. This one bounds a request: it has a value to return,
/// the transport does answer cancellation, and nobody cares about a reply that
/// arrives after the client stopped listening. The kit is also a module the app
/// does not link, on purpose, which settles where this had to live.
// **No `NSLock` is left in the agent or the kit**, as of 2026-09-17. Syd: "I
// flatout don't want NSLocks", and, asked whether that held even where it makes
// synchronous code async, "I don't mind everything being async; I prefer it".
// Phase 5 of `Plans/Agent Performance Overhaul.md` is the whole of it.
//
// Most were mechanical — state guarded by a lock and touched from one place,
// which is an actor with the lock deleted. Three kinds were not:
//
// - **`AgentErrors`, `LaunchTally`, `LibraryChanges`** take their reports
//   through an `AsyncStream`, because every writer is a synchronous `@Sendable`
//   closure on whatever thread reached it — `Console.alert`'s recorder, the
//   endpoints' reporters, a refresh page — and none can `await`. `yield` is
//   safe from any thread, never suspends, and keeps the order; `settle()` is
//   how a reader waits for what was reported before it.
// - **`DarwinNotification.Observation`** is an `Atomic`: its job is cancelling
//   a token exactly once, usually from `deinit`, which cannot `await`.
// - **`SystemPhotoLibrary`'s `ChunkSink`, `RequestHandle` and `ResumeOnce`** are
//   `Mutex`es. PhotoKit calls their handlers synchronously on a dispatch queue
//   of its own, and this file records what happened when Swift inferred actor
//   isolation into them. A `Task` per chunk would also queue up the megabytes
//   `ChunkSink` exists not to accumulate.
//
// The remaining `NSLock`s are in test doubles and in the wallpaper extension's
// `PaneHandler`, none of which is the agent.
//
// `FirstAnswer` below is the worked example, and `FetchDeadline` is the same
// shape — a continuation raced against a timer, where the loser is deliberately
// never awaited. That letting-go is the mechanism rather than an oversight: a
// structured child is awaited at scope exit by design, which is the wait these
// exist to escape.

public enum Deadline {

    /// The limit passed and nothing had answered.
    ///
    /// A distinct type rather than a `URLError`, because it is a distinct fact:
    /// `URLError` means the network said something, and this means nothing was
    /// said at all.
    public struct Expired: Error, Equatable, Sendable, CustomStringConvertible {
        public let limit: Duration

        public init(limit: Duration) {
            self.limit = limit
        }

        public var description: String { "no answer within \(limit.spokenSeconds)" }
    }

    /// Where the clock runs: a queue of its own, so the deadline does not
    /// depend on the thing it is bounding.
    ///
    /// **Measured 2026-09-18.** The resize budget is one second. The agent's
    /// own `TIMING:` lines had `resize gave up 5472ms`, `3722ms`, `3061ms` —
    /// the deadline firing up to five and a half times late — and with the
    /// response past `pictureReadLimit` the app showed nothing while the agent
    /// logged a `200`. The timer had been `Task.sleep`, which waits on the
    /// cooperative pool; the busier the agent got, the later its own timeouts
    /// fired, which is exactly backwards. A `DispatchSourceTimer` gets a thread
    /// from Dispatch and fires on time regardless.
    private static let clock = DispatchQueue(
        label: "com.sydpolk.photogoround.deadline", qos: .userInitiated)

    /// Runs `work` and throws `Expired` if `limit` passes first.
    public static func run<T: Sendable>(
        within limit: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let first = FirstAnswer<T>()
        let running = Task {
            do {
                first.finish(.success(try await work()))
            } catch {
                first.finish(.failure(error))
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: clock)
        timer.schedule(deadline: .now() + seconds(of: limit), leeway: .milliseconds(10))
        // Synchronous, from the timer's own thread: a hop back onto the pool to
        // deliver the expiry would put the wait back where it was.
        timer.setEventHandler { first.finish(.failure(Expired(limit: limit))) }
        timer.resume()
        // Asked to stop, never awaited. On the winning path both of these are
        // already finished and the calls do nothing.
        defer {
            timer.cancel()
            running.cancel()
        }
        let started = ContinuousClock.now
        defer { report(limit: limit, took: started.duration(to: ContinuousClock.now)) }
        return try await first.outcome().result.get()
    }

    /// **Says when the clock itself was late**, because a deadline nobody can
    /// check is a number in a comment.
    ///
    /// The field measurement this exists for, 2026-09-18: `resize gave up
    /// 5472ms` against a one-second budget, in a `TIMING:` lap that covers this
    /// call and little else. Whether the timer fired late or the lap was
    /// measuring something wider could not be told apart from the outside — so
    /// now the deadline reports its own elapsed time when it overruns, and the
    /// next occurrence says which.
    ///
    /// Only when it overruns by half again, so an ordinary expiry is silent and
    /// a `grep DEADLINE:` is all signal.
    private static func report(limit: Duration, took: Duration) {
        guard took > limit + limit / 2 else { return }
        let line =
            "DEADLINE: \(milliseconds(took)) for a \(milliseconds(limit)) limit — the clock was late"
        Log.deck.error(kind: "deadline.late", line)
    }

    /// Whichever of the two settles first, once.
    ///
    /// **A `Mutex` rather than an actor**, and that is the point of it: one of
    /// the two callers is a `DispatchSourceTimer` handler, which cannot `await`
    /// its turn. It was an actor until 2026-09-18, and reaching it cost a hop
    /// onto the cooperative pool — the same pool whose saturation made the
    /// deadline late in the first place. The same reasoning as
    /// `SystemPhotoLibrary`'s `ResumeOnce`; see `PhotoGoRoundKit`.
    private final class FirstAnswer<T: Sendable>: Sendable {
        private struct State {
            var pending: CheckedContinuation<Void, Never>?
            var settled: Outcome<T>?
        }

        private let state = Mutex(State())

        func outcome() async -> Outcome<T> {
            await withCheckedContinuation { continuation in
                // Resumed outside the lock, always: resuming inside it would
                // run the waiting task while this thread still holds it.
                let alreadySettled = state.withLock { state -> Bool in
                    guard state.settled == nil else { return true }
                    state.pending = continuation
                    return false
                }
                if alreadySettled { continuation.resume() }
            }
            // Set by whichever side won before this resumed, and never cleared.
            return state.withLock { $0.settled! }
        }

        func finish(_ outcome: Outcome<T>) {
            let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard state.settled == nil else { return nil }
                state.settled = outcome
                defer { state.pending = nil }
                return state.pending
            }
            waiting?.resume()
        }
    }

    /// `StageTimes` lives in the kit, which this module is below, so the two
    /// digits are spelled here rather than reached for.
    static func milliseconds(_ duration: Duration) -> String {
        "\(Int((seconds(of: duration) * 1000).rounded()))ms"
    }

    /// `Duration` as seconds, for Dispatch, which does not take one.
    static func seconds(of limit: Duration) -> Double {
        let parts = limit.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Success or the error that came instead.
    ///
    /// Not `Result`, because `Result<T, any Error>` is not `Sendable` — `Error`
    /// does not imply it — and this has to cross into the actor above. The
    /// unchecked conformance covers exactly one thing: an arbitrary error value
    /// being handed between two tasks in this process. Every error that reaches
    /// it was thrown by a `@Sendable` closure, and nothing here reads it except
    /// to rethrow.
    private struct Outcome<T: Sendable>: @unchecked Sendable {
        let result: Result<T, any Error>

        static func success(_ value: T) -> Outcome { Outcome(result: .success(value)) }
        static func failure(_ error: any Error) -> Outcome { Outcome(result: .failure(error)) }
    }
}
