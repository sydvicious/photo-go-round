import Dispatch
import Foundation

/// A thread of its own, for as long as the work lasts.
///
/// **One per request, one per cache walk, one per source being refreshed.**
/// `Agent Performance Overhaul.md`, Phases 3, 5 and 6. Syd, 2026-09-16: "Each
/// http request gets its own actor/thread", and "the agent should run the
/// refresh and downloads in separate actors (not using NSLock)". A thread
/// sample that afternoon had every thread of Swift's shared pool inside a
/// resize or waiting on the write lock, and work that needed neither could not
/// start. On a lane, a synchronous SQLite call or a busy-retry sleep blocks that
/// lane's own thread and nobody else's.
///
/// **The actor is not enough on its own.** A `nonisolated async` function hops
/// to the pool unless it runs on its caller's executor, and this package
/// enables `NonisolatedNonsendingByDefault` for exactly that reason; see
/// *Staying on the request's thread*. The other side of the same coin is
/// `@concurrent`, which is how `QueueFetcher`'s lanes get off their actor.
///
/// **Dispatch decides how many threads exist**, not this: a serial queue with
/// work gets a thread when one is free.
actor Lane {
    private let queue: DispatchSerialQueue

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// `qos` says who is waiting: `userInitiated` for a request, `utility` for
    /// the background work nobody is watching.
    init(_ label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchSerialQueue(label: "com.sydpolk.photosgoround.\(label)", qos: qos)
    }

    /// Runs `work` on this lane's thread, and answers what it answered.
    func run<T: Sendable>(_ work: () async -> T) async -> T {
        await work()
    }
}
