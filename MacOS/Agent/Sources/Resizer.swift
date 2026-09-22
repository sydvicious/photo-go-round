import Foundation
import Synchronization

/// Where every resize in the agent happens, one at a time, on a thread of its
/// own.
///
/// **Why a queue at all.** On 2026-09-16 the agent went silent for minutes at a
/// time. Its `TIMING:` lines had single resizes taking up to 741 seconds, and a
/// thread sample at 16:40 had six threads of Swift's shared pool inside
/// `PhotoRenderer.render` at once, with the system's media threads in kernel
/// calls to the video hardware. With the pool full, requests that had nothing
/// to do with resizing could not start. `Agent Performance Overhaul.md`.
///
/// **Why one at a time.** Measured the same afternoon on Syd's originals,
/// resizing to fit 2560×1440 and encoding HEIC: a HEIC resize took 0.24 s alone,
/// 0.22 s two at a time, 0.32 s four at a time and 0.58 s eight at a time, and
/// eight together finished barely sooner than four. The encoder is shared
/// hardware, and running more at once mostly makes each one slower. Serial
/// gives each resize the hardware to itself and puts a hard ceiling on what
/// resizing can take from the machine. Nothing needed the main thread.
///
/// **Its own queue, not the pool.** The actor's executor is a serial dispatch
/// queue, the same construction as `SystemPhotoLibrary.Album`. A request that
/// needs a resize suspends while it waits its turn and gives its pool thread
/// back; the blocking decode and encode happen here, where they hold up nobody
/// but the next resize.
actor Resizer {
    /// The agent's one resizer. Every endpoint that resizes shares it, which is
    /// what makes "one at a time" true for the process.
    static let shared = Resizer()

    private let queue = DispatchSerialQueue(
        label: "com.sydpolk.photogoround.resizer", qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Runs one resize on the resizer's thread, and says when it started, so a
    /// caller can tell the wait for its turn from the resize itself.
    ///
    /// A resize whose `ticket` was given up before its turn came is skipped
    /// and throws `Skipped`: nobody is waiting for it, and running it would
    /// only hold up the resizes behind it. One already running cannot be
    /// stopped — it is inside ImageIO — and finishes.
    func run<T: Sendable>(
        _ ticket: Ticket? = nil,
        _ work: @Sendable () throws -> T
    ) throws -> (result: T, started: ContinuousClock.Instant) {
        if ticket?.isAbandoned == true { throw Skipped() }
        let started = ContinuousClock.now
        return (try work(), started)
    }

    /// Whether anybody is still waiting for one resize. The request gives it up
    /// when `ServiceTiming.resizeBudget` runs out.
    final class Ticket: Sendable {
        private let abandoned = Mutex(false)

        func abandon() { abandoned.withLock { $0 = true } }
        var isAbandoned: Bool { abandoned.withLock { $0 } }
    }

    /// A resize skipped because its request had already given up on it.
    struct Skipped: Error {}
}
