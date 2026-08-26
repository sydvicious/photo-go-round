import Foundation

/// Somewhere to put work that blocks.
///
/// **Swift's cooperative pool has about as many threads as the machine has
/// cores, and a thread parked in a synchronous system call is one the runtime
/// cannot use for anything else.** Enough of them and nothing runs at all —
/// which is not a deadlock and does not look like one: no lock is held, no
/// cycle exists, the process simply stops.
///
/// This project has hit that twice.
///
/// **2026-08-25**, from `FileAccess`: a walk of a network folder writing into
/// batched transactions synchronously from an async task, where four concurrent
/// walks were enough to stop the agent answering picture requests. Fixed there
/// by giving the sink an async form.
///
/// **2026-08-26**: `FileManager.copyItem` against an iCloud Drive file that was
/// not downloaded. The read hands off to `bird` and does not return — not
/// slowly, at all — and once a fetch could be abandoned on a deadline while its
/// copy kept running, eleven of them took every thread in the pool.
///
/// A blocked thread here costs a thread here. Dispatch grows this queue as work
/// arrives and the runtime goes on running, so abandoning a fetch becomes a
/// real thing to do rather than a promise the abandoned work refuses to keep.
///
/// **It is not a place to put work that merely takes a while.** Anything that
/// suspends properly — a network request, a database write behind an async
/// transaction — belongs on the cooperative pool where it can yield. This is
/// for calls that will not yield because they cannot.
enum BlockingWork {

    /// Concurrent, and deliberately unbounded by us: Dispatch's own thread
    /// ceiling is the backstop. A width of our own choosing would be a second
    /// cap to keep in step with `CacheQueue`'s, and the two would disagree.
    private static let queue = DispatchQueue(
        label: "com.sydpolk.photogoround.blocking",
        qos: .utility,
        attributes: .concurrent
    )

    /// Runs `body` on a thread that is allowed to block, and suspends the
    /// caller until it answers.
    ///
    /// The caller's cooperative thread is released across the call, which is
    /// the whole point: whatever `body` does to its own thread, the rest of the
    /// agent keeps running.
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
