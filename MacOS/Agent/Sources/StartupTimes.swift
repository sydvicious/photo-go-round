import Console
import Foundation
import PhotosGoRoundAgentAPI
import PhotosGoRoundKit

/// How long each step of a launch took: the `STARTUP:` lines.
///
/// **Added 2026-09-17, after a restart.** The agent's process started at
/// 13:49:52 and answered its first request at 13:50:31 — 39 seconds, about 33
/// of them between the last line before the cache index was rebuilt and the
/// line after it. Whether that is the walk itself or a volume still busy from
/// the boot, nothing said. Syd: "the agent's own 39 seconds first". `TODO.md`,
/// *The agent takes about two minutes from launch to listening after a
/// restart*.
///
/// **A line as each step finishes, and a summary at the end**, because a launch
/// that never finishes is exactly the case worth reading: the last line names
/// the step it is stuck in.
struct StartupTimes {
    private(set) var steps: [(name: String, took: Duration)] = []
    private var mark = ContinuousClock.now

    /// Charges everything since the last step to `step`, and answers its line.
    /// `took` is for a test, which has no clock to spend.
    @discardableResult
    mutating func lap(_ step: String, took: Duration? = nil, now: ContinuousClock.Instant = .now)
        -> String
    {
        let duration = took ?? now - mark
        mark = now
        steps.append((step, duration))
        let line = "STARTUP: \(step) \(StageTimes.milliseconds(duration))"
        Log.deck.notice("\(line, privacy: .public)")
        return line
    }

    /// `STARTUP: listening after storage 120ms · migrate 30ms · total 150ms`
    func summary(as reached: String) -> String {
        let named = steps.map { "\($0.name) \(StageTimes.milliseconds($0.took))" }
            .joined(separator: " · ")
        let total = steps.reduce(Duration.zero) { $0 + $1.took }
        return "STARTUP: \(reached) after \(named) · total \(StageTimes.milliseconds(total))"
    }

    /// The summary, on the console where a person is watching and in the log.
    func report(as reached: String) {
        let line = summary(as: reached)
        Console.event(line)
        Log.deck.notice("\(line, privacy: .public)")
    }
}
