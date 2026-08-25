import Foundation

/// When the agent's periodic work is next due.
///
/// **Extracted from the loop so the scheduling can be asserted.** It is a few
/// timestamps and a comparison, which is exactly the kind of thing that looks
/// too simple to test and then goes wrong in a way nothing notices for months —
/// the re-arm bug below lived in four lines of arithmetic and cost a library
/// every picture it had for the length of a scan.
///
/// It holds no clock of its own. The caller supplies `now`, which is what lets a
/// test cover a six-minute refresh in no time at all.
struct Heartbeat: Sendable {

    /// The periodic jobs, each on its own clock because they answer to different
    /// pressures.
    enum Work: String, CaseIterable, Sendable {
        /// Re-read preferences and reconcile the source list.
        case preferences
        /// Walk every source looking for photographs that arrived or left.
        case refresh
        /// Seed the queue if it is empty.
        case queue
        /// Evict cached bytes over the ceiling.
        case maintenance
    }

    /// When each job last *finished*. Absent means never, which is due now.
    private var finishedAt: [Work: Date] = [:]

    /// Whether `work` should run on this tick.
    ///
    /// `forced` is the doorbell: somebody changed the source list and the answer
    /// is yes regardless of the clock.
    func isDue(_ work: Work, every interval: Duration, at now: Date, forced: Bool = false)
        -> Bool
    {
        if forced { return true }
        guard let last = finishedAt[work] else { return true }
        return now.timeIntervalSince(last) >= interval.totalSeconds
    }

    /// **Stamped when the work ended, and this is the whole point of the type.**
    ///
    /// The loop used to record the timestamp it read at the *top* of the tick.
    /// A job that takes longer than its own interval therefore satisfies its
    /// next deadline the instant it finishes, so the following tick starts it
    /// again — passes back to back, with no gap, and every other job in the loop
    /// waiting behind them. Seven network folders took six minutes against a
    /// five-minute scan interval on 2026-08-25 and the agent served nothing for
    /// the duration.
    mutating func finished(_ work: Work, at now: Date = Date()) {
        finishedAt[work] = now
    }

    /// When `work` last finished, or nil if it never has. For a status line, and
    /// for tests.
    func lastFinished(_ work: Work) -> Date? { finishedAt[work] }

    /// The order a tick does its work in, which differs on the first one.
    ///
    /// **At launch the queue is seeded before anything is refreshed.** The pool
    /// from the last run is already in the database and the cache index is
    /// already rebuilt from disk, so there are usually photographs that can be
    /// dealt and served immediately — while a refresh of a network source is
    /// minutes during which the loop is inside it. Refreshing first means a
    /// restart shows nothing for as long as the slowest share takes to walk,
    /// which is the opposite of the rule this agent exists to keep: **serve a
    /// picture whenever one can possibly be served.**
    ///
    /// After the first tick the order goes back to refresh-then-queue, so that
    /// a queue seeded on a tick reflects whatever the refresh just found.
    static func order(launching: Bool) -> [Work] {
        launching
            ? [.preferences, .queue, .refresh, .maintenance]
            : [.preferences, .refresh, .queue, .maintenance]
    }
}
