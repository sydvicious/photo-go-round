import Foundation
import PhotosGoRoundAgentAPI

/// Where one refresh batch's time went: the `REFRESH:` line.
///
/// **A probe for `Agent Performance Overhaul.md`, Phase 4**, added 2026-09-16
/// before that phase was designed. The `LOCK:` lines had a refresh upsert
/// holding the writer for 117 ms to 9 s per 500-row batch, and the plan's
/// staging design assumed the time was index lookups made with the lock held.
/// Nothing had measured that. Syd: "yes, add the timing probe first."
///
/// **Since Phase 4 was built, the same night,** a page is 100 rows, and its
/// reads come before the lock:
///
/// - `lookups`: the reads that decide what the page must write, with no lock.
/// - `locked`: false when the lookups found nothing to write, and then nothing
///   below it happened.
/// - `waited`: from asking for the writer to holding it — `BEGIN IMMEDIATE`,
///   and any busy retries.
/// - `held`: from holding it to `COMMIT` returning. Inside it, an upsert's
///   `inserts` and `updates`, a removal's `deletes`, and both kinds' `commit`.
/// - `callbacks`: an upsert's per-photograph `onAdded`, after the commit.
public struct RefreshBatchTiming: Sendable, Equatable {
    public enum Work: String, Sendable { case upsert, remove }

    public var work: Work
    public var rows: Int
    /// The source an upsert writes to. A removal can span sources.
    public var source: Int64?
    public var lookups: Duration = .zero
    public var locked = false
    public var waited: Duration = .zero
    public var held: Duration = .zero
    public var inserts: Duration = .zero
    public var updates: Duration = .zero
    public var callbacks: Duration = .zero
    public var deletes: Duration = .zero
    public var commit: Duration = .zero
    public var added = 0
    public var changed = 0

    public init(work: Work, rows: Int, source: Int64?) {
        self.work = work
        self.rows = rows
        self.source = source
    }

    public var text: String {
        let ms = StageTimes.milliseconds
        switch work {
        case .upsert:
            let into = source.map { " into source \($0)" } ?? ""
            let head = "REFRESH: upsert \(rows)\(into) · lookups \(ms(lookups))"
            let counts = "\(added) added · \(changed) changed"
            guard locked else { return "\(head) · no lock · \(counts)" }
            return "\(head) · waited \(ms(waited)) · held \(ms(held))"
                + " · inserts \(ms(inserts)) · updates \(ms(updates)) · commit \(ms(commit))"
                + " · callbacks \(ms(callbacks)) · \(counts)"
        case .remove:
            let head = "REFRESH: remove \(rows) · lookups \(ms(lookups))"
            guard locked else { return "\(head) · no lock" }
            return "\(head) · waited \(ms(waited)) · held \(ms(held))"
                + " · deletes \(ms(deletes)) · commit \(ms(commit))"
        }
    }

    /// Recording what a batch saw in `walk_seen`, which is a temporary table and
    /// takes no lock on the library.
    public static func walkSeen(rows: Int, source: Int64, took: Duration) -> String {
        "REFRESH: walk_seen \(rows) for source \(source) · \(StageTimes.milliseconds(took))"
    }

    /// The unlocked read that finds what a walk did not see.
    public static func departedQuery(source: Int64, found: Int, took: Duration) -> String {
        "REFRESH: departed query for source \(source) · \(StageTimes.milliseconds(took)) · \(found) found"
    }

    /// In the unified log, category `sources`. Filter on the prefix.
    public func report() {
        Log.sources.info("\(text, privacy: .public)")
    }
}
