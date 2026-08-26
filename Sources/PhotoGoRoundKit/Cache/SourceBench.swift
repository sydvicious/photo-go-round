import Foundation
import PhotoGoRoundAgentAPI

/// Leaves a source alone for a while when it stops answering.
///
/// **This is what bounds abandoned work**, and it is why `FetchDeadline` needs
/// no cap of its own: rationing lanes among cards that were never going to
/// arrive treats the symptom, while benching stops the work at its origin.
///
/// Lifted out of `CacheQueue` unchanged in substance. A source that produces
/// nothing but timeouts is benched; each subsequent bench doubles, up to a
/// ceiling. **The ceiling matters**: doubling without one reaches "not in this
/// lifetime" after about a dozen rounds, and a network share that came back
/// would never be noticed.
public final class SourceBench: @unchecked Sendable {

    /// Timeouts in a row before a source is left alone for a while.
    ///
    /// **Four, lowered from ten on 2026-08-26.** Ten is a lot of slots and a
    /// lot of minutes to spend proving what the first few already showed, and
    /// every one of them is a slot the healthy sources do not get.
    private let pauseAfter: Int
    /// The first bench. Each subsequent one doubles, up to `longestPause`.
    private let firstPause: Duration
    /// **A ceiling, so a source that is simply gone is still retried hourly
    /// rather than never.**
    public static let longestPause = Duration.seconds(3600)

    private let lock = NSLock()
    /// How many fetches from each source have timed out since it last produced.
    private var failures: [Int64: Int] = [:]
    /// When each benched source may be asked again.
    private var benchedUntil: [Int64: ContinuousClock.Instant] = [:]
    /// How long its last bench was, so the next one can be longer.
    private var benchLength: [Int64: Duration] = [:]

    public init(pauseAfter: Int = 4, firstPause: Duration = .seconds(60)) {
        self.pauseAfter = max(1, pauseAfter)
        self.firstPause = firstPause
    }

    /// Whether this source is resting right now.
    public func isBenched(_ source: Int64, now: ContinuousClock.Instant = .now) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = benchedUntil[source] else { return false }
        guard now < until else {
            // The bench is over. `benchLength` is deliberately kept, so a
            // source that goes straight back to timing out waits longer this
            // time rather than starting again from a minute.
            benchedUntil[source] = nil
            return false
        }
        return true
    }

    /// One more fetch from this source that never answered. Answers the bench
    /// it earned, if this was the one that tipped it over.
    @discardableResult
    public func failed(_ source: Int64, now: ContinuousClock.Instant = .now) -> Duration? {
        lock.lock()
        defer { lock.unlock() }
        let count = (failures[source] ?? 0) + 1
        failures[source] = count
        guard count >= pauseAfter else { return nil }

        let length = benchLength[source].map { min($0 * 2, Self.longestPause) } ?? firstPause
        benchLength[source] = length
        benchedUntil[source] = now + length
        failures[source] = 0
        return length
    }

    /// Anything at all from a source clears its account. An occasional timeout
    /// on a working source is weather, not a reason to stop asking.
    public func succeeded(_ source: Int64) {
        lock.lock()
        failures[source] = 0
        benchLength[source] = nil
        lock.unlock()
    }
}
