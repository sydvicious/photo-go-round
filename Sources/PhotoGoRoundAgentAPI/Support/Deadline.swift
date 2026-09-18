import Foundation

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

    /// Runs `work` and throws `Expired` if `limit` passes first.
    public static func run<T: Sendable>(
        within limit: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let first = FirstAnswer<T>()
        let running = Task {
            do {
                await first.finish(.success(try await work()))
            } catch {
                await first.finish(.failure(error))
            }
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            await first.finish(.failure(Expired(limit: limit)))
        }
        // Asked to stop, never awaited. On the winning path both of these are
        // already finished and the calls do nothing.
        defer {
            timer.cancel()
            running.cancel()
        }
        return try await first.outcome().result.get()
    }

    /// Whichever of the two settles first, once.
    ///
    /// **An actor rather than a lock**, so there is no lock/unlock pair for
    /// anybody to get wrong and no `@unchecked Sendable` claiming a safety the
    /// compiler cannot see. `finish` is called from two tasks and the actor is
    /// what makes them take turns.
    ///
    /// Storing the continuation needs no guard of its own: the body of
    /// `withCheckedContinuation` runs synchronously on the actor's executor
    /// before the caller suspends, so `finish` cannot interleave between
    /// finding no answer and being in a position to receive one.
    private actor FirstAnswer<T: Sendable> {
        private var pending: CheckedContinuation<Void, Never>?
        private var settled: Outcome<T>?

        func outcome() async -> Outcome<T> {
            if settled == nil {
                await withCheckedContinuation { pending = $0 }
            }
            // Set by whichever side won before this resumed, and never cleared.
            return settled!
        }

        func finish(_ outcome: Outcome<T>) {
            guard settled == nil else { return }
            settled = outcome
            pending?.resume()
            pending = nil
        }
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
