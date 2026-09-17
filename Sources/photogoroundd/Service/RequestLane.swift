import Dispatch
import Foundation

/// One request's thread, for as long as the request lasts.
///
/// **A lane per request, not a task on the shared pool.** `Agent Performance
/// Overhaul.md`, Phase 3. Syd, 2026-09-16: "Each http request gets its own
/// actor/thread." A thread sample that afternoon had every thread of Swift's
/// shared pool inside `PhotoRenderer.render` or waiting on the write lock, and
/// requests that needed neither could not start at all. On a lane, a
/// synchronous SQLite call or a busy-retry sleep blocks that request's own
/// thread and nobody else's.
///
/// **The actor is not enough on its own.** A `nonisolated async` function hops
/// to the pool unless it runs on its caller's executor, and the request path is
/// made of them. The package enables `NonisolatedNonsendingByDefault` for that;
/// see *Staying on the request's thread*.
///
/// **Dispatch decides how many threads exist**, not this: a serial queue with
/// work gets a thread when one is free. A request that is abandoned but still
/// running holds its thread until it finishes, which is accepted — Syd,
/// 2026-09-16: "we are not doing that", of cancelling work for a client that
/// has hung up.
actor RequestLane {
    private let queue: DispatchSerialQueue

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(label: String = "com.sydpolk.photogoround.request") {
        queue = DispatchSerialQueue(label: label, qos: .userInitiated)
    }

    /// Runs `work` on this lane's thread, and answers what it answered.
    func run<T: Sendable>(_ work: () async -> T) async -> T {
        await work()
    }
}
