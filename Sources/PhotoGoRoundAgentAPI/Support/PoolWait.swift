import Foundation
import Synchronization

/// How long a task waits before it begins running.
///
/// **The measurement Phase 7 is judged by.** Syd, 2026-09-18: "if stage 7 is
/// supposed to solve this… you should be the probe so you can prove it does
/// when we think we are done." So this lands before the fix, not after, and the
/// number it prints today is what the number after Phase 7 has to beat.
///
/// **Why it is the number that matters.** A deadline of one second can only be
/// honoured if the work it bounds gets a thread inside that second. Measured
/// 2026-09-18 across nine hours of the agent serving 2,503 pictures: 149
/// `DEADLINE:` lines, median overrun 2,017 ms against a 1,000 ms limit and a
/// worst of 197,544 ms. The timer had already been moved off the cooperative
/// pool that morning, so what is left is the *resumption* waiting for a thread
/// — which is this.
///
/// **It measures the wait, not the work.** The sampling task does nothing but
/// read the clock, so everything between asking and running is time the pool
/// made it wait.
public enum PoolWait {

    /// How often a sample is taken. A second, because the spikes are what
    /// matter and a five-minute sample would step straight over them.
    public static let sample = Duration.seconds(1)

    /// How often the samples are said out loud. A minute of them is one line
    /// and a night of them is a curve.
    public static let report = Duration.seconds(60)

    /// A minute's worth, reduced to the two numbers worth reading.
    public struct Window: Sendable, Equatable {
        public let samples: Int
        /// The median, which says what an ordinary task pays.
        public let typical: Duration
        /// The worst, which says what a deadline has to survive.
        public let worst: Duration

        public init(samples: Int, typical: Duration, worst: Duration) {
            self.samples = samples
            self.typical = typical
            self.worst = worst
        }
    }

    /// Nil for an empty window, because a line saying nothing happened is worse
    /// than no line.
    public static func summarise(_ waits: [Duration]) -> Window? {
        guard !waits.isEmpty else { return nil }
        let sorted = waits.sorted()
        return Window(
            samples: sorted.count, typical: sorted[sorted.count / 2], worst: sorted[sorted.count - 1])
    }

    /// `POOL: waited 2ms typical · 1842ms worst · 60 samples in the last minute`
    public static func line(_ window: Window) -> String {
        "POOL: waited \(Deadline.milliseconds(window.typical)) typical · "
            + "\(Deadline.milliseconds(window.worst)) worst · \(window.samples) samples"
    }

    private static let started = Atomic(false)

    /// Starts this process's probe, once.
    public static func startLogging(_ say: @escaping @Sendable (String) -> Void) {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else { return }
        Task.detached(priority: .utility) {
            let clock = ContinuousClock()
            var waits: [Duration] = []
            var reported = clock.now
            while !Task.isCancelled {
                // **`await Task { }` and nothing else.** Syd's own fix for a
                // flaky timing test is the measurement here: the task reads the
                // clock and returns, so what comes back is the wait to be run.
                let asked = clock.now
                let began = await Task { ContinuousClock.now }.value
                waits.append(asked.duration(to: began))

                if clock.now - reported >= report {
                    if let window = summarise(waits) { say(line(window)) }
                    waits.removeAll(keepingCapacity: true)
                    reported = clock.now
                }
                do { try await Task.sleep(for: sample) } catch { return }
            }
        }
    }
}
