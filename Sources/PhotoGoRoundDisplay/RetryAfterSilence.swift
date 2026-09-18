import Foundation

/// How long a surface waits before asking again, once an ask has found no
/// agent.
///
/// **Why this exists.** Measured on 2026-09-18, across two reboots: the
/// wallpaper extension woke 5 to 51 seconds *before* the agent was listening,
/// was refused, and then slept for its whole rotation interval. At the ten
/// minutes it was set to, the desktop kept yesterday's picture for ten minutes
/// after every restart; at `twelveHours`, which is on the menu, it would keep it
/// for half a day. The agent is never ready in the first second of a boot, so
/// the first ask after a restart fails nearly every time.
///
/// **Ten seconds, doubling, and never longer than the rotation itself.** A
/// restart is answered within ten seconds; an agent that is genuinely off backs
/// off to the interval rather than asking six times a minute for ever. The cap
/// matters: without it a long silence and a short interval would leave the
/// retry slower than the ordinary rotation, which is the wrong way round.
public struct RetryAfterSilence: Sendable, Equatable {

    /// The first wait after an ask finds nothing. The same ten seconds the
    /// rotation already wakes on, so it costs no extra sleep.
    public static let first = Duration.seconds(10)

    /// Nil while the agent is answering. A value is how long the next ask is
    /// being held back, and that it is being held back at all.
    public private(set) var waiting: Duration?

    public init() {}

    /// Whether the agent had been silent — which is the transition worth a log
    /// line, rather than every ask.
    @discardableResult
    public mutating func answered() -> Bool {
        defer { waiting = nil }
        return waiting != nil
    }

    /// Another ask that found nobody. Answers whether this was the first, which
    /// is again the transition worth saying.
    @discardableResult
    public mutating func wentQuiet(cap: Duration) -> Bool {
        let firstSilence = waiting == nil
        waiting = min(waiting.map { $0 * 2 } ?? Self.first, cap)
        return firstSilence
    }

    /// How long to wait before the next ask: the rotation interval when the
    /// agent is answering, and the backoff when it is not — never longer than
    /// the interval either way.
    public func wait(interval: Duration) -> Duration {
        min(waiting ?? interval, interval)
    }
}
