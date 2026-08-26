import Foundation
import PhotoGoRoundAgentAPI

/// Runs a fetch against a time limit and reports whether it answered.
///
/// **Lifted out of `CacheQueue` on 2026-08-26 rather than written fresh.** The
/// reasoning below was paid for by a night when an iCloud Drive folder of 436
/// album covers stopped answering at all — `bird` idle at 0% CPU, metadata
/// served, content never delivered — while it was 98% of the library. Every
/// sentence here is a fault that stopped pictures reaching a screen.
///
/// **The abandoned work is neither cancelled nor awaited, and both halves of
/// that are deliberate.** A read blocked inside `bird` waiting for a file to
/// materialise does not answer cancellation, and a structured child would be
/// waited for at scope exit — which is precisely the wait this exists to
/// escape. So the fetch goes into an unstructured task that is simply let go of.
///
/// What that buys is the only thing that matters: the lane comes back. Observed
/// 2026-08-25, one undownloaded file held a lane indefinitely and the queue sat
/// one card short for as long as the agent ran.
///
/// **There is no cap on abandoned work, and that is the point.** There was one
/// for a few hours, counting every fetch from start to return. It was right
/// while a blocked `copyItem` sat on a cooperative thread — eleven of them
/// stopped the runtime — and it became wrong the moment `BlockingWork` gave
/// that copy a thread of its own, because work that never returns then held
/// every slot for ever: nothing fetched, nothing cached, every walk answering
/// `204`. What bounds it instead is `SourceBench`, which stops the work at its
/// origin.
public enum FetchDeadline {

    /// Runs `work` and answers false if `limit` passes first.
    ///
    /// `whenAbandoned` fires only when the work returns *after* it was given
    /// up on, which is how a caller learns a lane it had written off has
    /// finally come back.
    public static func run(
        within limit: Duration,
        work: @escaping @Sendable () async -> Void,
        whenAbandoned: @escaping @Sendable () -> Void = {}
    ) async -> Bool {
        let race = Race()
        let running = Task.detached {
            await work()
            // Nobody may be waiting any more — that is what abandonment means
            // — so this reports whether it won or was let go of.
            if !race.finish(true) { whenAbandoned() }
        }
        let timer = Task.detached {
            try? await Task.sleep(for: limit)
            _ = race.finish(false)
        }
        let answered = await race.outcome()
        timer.cancel()
        // `running` is deliberately not cancelled: see above. Naming it says so.
        _ = running
        return answered
    }

    /// Whichever of the two finishes first, once.
    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: CheckedContinuation<Bool, Never>?
        private var settled: Bool?

        func outcome() async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let settled {
                    lock.unlock()
                    continuation.resume(returning: settled)
                } else {
                    pending = continuation
                    lock.unlock()
                }
            }
        }

        /// True if this call settled the race, false if it had already been
        /// lost — which is how an abandoned fetch learns that it was abandoned.
        @discardableResult
        func finish(_ answered: Bool) -> Bool {
            lock.lock()
            guard settled == nil else {
                lock.unlock()
                return false
            }
            settled = answered
            let continuation = pending
            pending = nil
            lock.unlock()
            continuation?.resume(returning: answered)
            return true
        }
    }
}
