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
    ///
    /// **An hour, and Syd kept it deliberately on 2026-09-07** when the cost
    /// was put to him: benches only began firing that day — until then nothing
    /// reported a failed fetch, so the doubling was unreachable — and a long
    /// outage now climbs 60, 120, 240, 480 and leaves a source unfetched for
    /// that long *after* the network is fine again. A success cannot shorten
    /// it, because nothing is fetched from a benched source for a success to
    /// happen in; the bench has to expire first, and only then does one good
    /// fetch reset the doubling.
    ///
    /// What makes that acceptable is that a bench stops *fetching* and not
    /// serving: the cards already held keep going out, and the other sources
    /// keep filling the queue. Do not lower this without a reason better than
    /// the recovery latency, which was weighed and accepted.
    public static let longestPause = Duration.seconds(3600)

    private let lock = NSLock()
    /// How far each source is into the bench. A bucket: `failed` fills it,
    /// `succeeded` drains it one at a time, and it never goes below empty.
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

    /// One fetch that produced bytes. **Pays off one failure rather than the
    /// whole account.**
    ///
    /// It used to set the count to zero, on the reasoning that an occasional
    /// timeout on a working source is weather. That reasoning holds and this
    /// still expresses it — a source that succeeds nine times for every failure
    /// keeps its account at nothing — but zeroing made the bench unreachable for
    /// the one source that most needed it. **A Photos album that is half
    /// downloaded is not a working source having weather.** Some of its
    /// photographs are on the disk and answer in milliseconds; the rest are in
    /// iCloud and, with no network, answer never. Every local one that
    /// succeeded wiped the account of every remote one that had failed, so the
    /// four-in-a-row the bench asks for was never reached.
    ///
    /// Measured 2026-09-07 against Favorites: 689 successes, 66 timeouts, four
    /// benches in four hours, where the runs of failures had earned sixteen.
    ///
    /// **The count is a bucket and not a total**: it fills on failure, drains on
    /// success, and cannot go below empty. Refusing to go negative is what stops
    /// a source that has been fine all day from banking a thousand successes
    /// against the moment it goes wrong.
    public func succeeded(_ source: Int64) {
        lock.lock()
        failures[source] = max(0, (failures[source] ?? 0) - 1)
        benchLength[source] = nil
        lock.unlock()
    }
}
