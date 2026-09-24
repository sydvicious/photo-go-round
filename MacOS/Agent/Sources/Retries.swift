import Foundation
import PhotosGoRoundKit

/// Sources that went unanswered, and when each is worth asking again.
///
/// **Because the next scan is too long to wait.** On 2026-09-23, forty seconds
/// after a reboot, both Photos albums failed their first walk on a cold
/// `photolibraryd`, and nothing asked again until the scheduled refresh five
/// minutes later — five minutes in which 8,632 of 9,184 photographs were out of
/// the deal. Photos answered in well under a second by then.
///
/// **Only a source that went unanswered is retried.** A folder on an unplugged
/// drive is unavailable too, and it is not coming back in thirty seconds;
/// asking it again early is churn. See `SourceReachability.unanswered`.
///
/// **The wait doubles, and stops at the scan interval.** Thirty seconds, then a
/// minute, two, four — and once the next wait would be as long as the scan
/// interval the source is forgotten here, because the ordinary refresh will
/// reach it as soon. A library that stays silent costs a handful of extra walks
/// and then nothing.
///
/// It holds no clock of its own. The caller supplies `now`, as with
/// `Heartbeat`, which is what lets a test cover the backoff in no time at all.
actor Retries {

    /// The wait before the first retry.
    static let first = Duration.seconds(30)

    private struct Entry {
        /// Walks in a row that went unanswered.
        var failures: Int
        /// When the last of them ended.
        var failedAt: Date
        /// Handed out by `take`, and not yet heard back from.
        var inFlight = false
    }

    private var entries: [Int64: Entry] = [:]

    /// How long to wait after `failures` unanswered walks in a row.
    static func delay(afterFailures failures: Int) -> Duration {
        first * (1 << min(max(failures - 1, 0), 20))
    }

    /// Hears one walk's result, from a full refresh or a retry alike.
    ///
    /// **Every walk reports here, not only the retries.** A scheduled pass that
    /// reaches a source first settles it just as well, and one that finds it
    /// silent again moves it along the backoff.
    func heard(_ result: ScanResult, at now: Date) {
        guard result.unanswered else {
            entries[result.sourceID] = nil
            return
        }
        let failures = (entries[result.sourceID]?.failures ?? 0) + 1
        entries[result.sourceID] = Entry(failures: failures, failedAt: now)
    }

    /// The sources due another walk now, marked as in flight so the next tick
    /// does not hand them out again while that walk runs.
    ///
    /// **`ceiling` is the scan interval**, read by the caller each tick because
    /// a preference can change it. A source whose next wait would reach it is
    /// dropped: the ordinary refresh gets there as soon.
    func take(at now: Date, ceiling: Duration) -> [Int64] {
        var due: [Int64] = []
        for (id, entry) in entries where !entry.inFlight {
            let wait = Self.delay(afterFailures: entry.failures)
            if wait >= ceiling {
                entries[id] = nil
            } else if now.timeIntervalSince(entry.failedAt) >= wait.totalSeconds {
                entries[id]?.inFlight = true
                due.append(id)
            }
        }
        return due.sorted()
    }

    /// A source handed out that will not be walked — removed or disabled since
    /// it failed. Nothing will report on it, so it would be in flight for ever.
    func forget(_ id: Int64) {
        entries[id] = nil
    }

    /// Whether anything is waiting, for tests.
    var isEmpty: Bool { entries.isEmpty }
}
