import Foundation

/// The errors the agent is reporting, one row per kind.
///
/// **For the dashboard, because an installed agent's console goes nowhere.**
/// Every red line and every error-level log record the agent writes is recorded
/// here as well, so the question "what keeps going wrong" has an answer one URL
/// away rather than in `log show`.
///
/// **Grouped by kind, not by text.** Most of the agent's error lines carry a
/// detail that changes every time — the photograph, the queue depth, the
/// latency — so identical text almost never repeats, and a record keyed on it
/// would be a scrolling log. A kind is a short fixed name for the trouble,
/// `cache.timed-out.source-6`; the row counts it and keeps the most recent
/// full message, so the detail is still there to read. A report with no kind is
/// grouped by its exact text, which is how an unclassified line is still kept.
///
/// **A row lasts as long as its trouble.** Syd, 2026-09-13: "if an error clears
/// after a minute, remove it from that panel" — and then, of a source that is
/// unavailable or empty, "keep standing conditions until they clear". So most
/// rows are events, and leave a minute after they last happened; a standing
/// condition stays until the site that reported it clears it, or until the time
/// it was reported to end. Until then, every row stayed for the whole run.
///
/// **Nothing is recorded until `startRecording`**, and only the agent calls it.
/// The kit and this module log the same errors from `pgr_ctl`, the app, and the
/// screensaver, none of which has a dashboard to show them on.
///
/// In memory and gone at exit.
public final class AgentErrors: @unchecked Sendable {

    /// One kind of trouble, as it has stood so far.
    public struct Entry: Sendable, Equatable, Codable {
        /// Nil for a report that named no kind, which is grouped by `message`.
        public let kind: String?
        /// The most recent report's words.
        public let message: String
        public let count: Int
        public let firstSeen: Date
        public let lastSeen: Date
        /// A condition that is still true, kept until it is cleared rather than
        /// for a minute after `lastSeen`.
        public let standing: Bool
        /// When a standing condition ends by itself — a paused source's pause.
        /// Absent for one that has to be cleared, and for an event.
        public let until: Date?
    }

    /// How long a report keeps its row.
    public enum Lifetime: Sendable, Equatable {
        /// An event: gone `transientLifetime` after it last happened.
        case transient
        /// A condition: kept until `clear` or `clearStanding` says it is over.
        case standing
        /// A condition that ends at a known time, or sooner if cleared.
        case standingUntil(Date)
    }

    /// The agent's record. A process that never starts recording leaves it empty.
    public static let shared = AgentErrors()

    /// Kinds kept at once. A new kind past this pushes out the event seen
    /// longest ago — a standing condition only when there is no event left to
    /// push — so a flood of unclassified lines costs the oldest rows and not
    /// memory without bound.
    public static let defaultCapacity = 100

    /// How long an event stays after it last happened, in seconds.
    public static let transientLifetime: TimeInterval = 60

    private let lock = NSLock()
    private let capacity: Int
    private var recording: Bool
    private var rows: [String: Entry] = [:]

    public init(capacity: Int = AgentErrors.defaultCapacity, recording: Bool = false) {
        self.capacity = max(1, capacity)
        self.recording = recording
    }

    public func startRecording() {
        lock.lock()
        recording = true
        lock.unlock()
    }

    /// `kind` nil groups the report by its exact text. A kind reported again
    /// takes the lifetime of the latest report, so a pause that is extended
    /// ends at the new time.
    public func record(
        kind: String?, _ message: String, lasting lifetime: Lifetime = .transient,
        at now: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }
        prune(at: now)

        let standing: Bool
        let until: Date?
        switch lifetime {
        case .transient: (standing, until) = (false, nil)
        case .standing: (standing, until) = (true, nil)
        case .standingUntil(let end): (standing, until) = (true, end)
        }

        let key = kind ?? message
        if let existing = rows[key] {
            rows[key] = Entry(
                kind: kind, message: message, count: existing.count + 1,
                firstSeen: existing.firstSeen, lastSeen: now, standing: standing, until: until)
            return
        }
        if rows.count >= capacity,
            let stalest = rows.min(by: {
                // Events before conditions, then the one seen longest ago.
                $0.value.standing != $1.value.standing
                    ? !$0.value.standing : $0.value.lastSeen < $1.value.lastSeen
            })
        {
            rows.removeValue(forKey: stalest.key)
        }
        rows[key] = Entry(
            kind: kind, message: message, count: 1, firstSeen: now, lastSeen: now,
            standing: standing, until: until)
    }

    /// A condition that is over. Nothing happens for a kind with no row.
    public func clear(kind: String) {
        lock.lock()
        rows.removeValue(forKey: kind)
        lock.unlock()
    }

    /// Every standing condition about one source, for a source that has been
    /// removed: nothing will ever report it available, or not empty, again.
    /// Its events are left to leave on their own.
    public func clearStanding(source: Int64) {
        let suffix = ".source-\(source)"
        lock.lock()
        rows = rows.filter { !($0.value.standing && ($0.value.kind?.hasSuffix(suffix) ?? false)) }
        lock.unlock()
    }

    /// Most recently seen first.
    public var entries: [Entry] { entries(at: Date()) }

    /// Most recently seen first, as they stand at `now`.
    public func entries(at now: Date) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        prune(at: now)
        return rows.values.sorted {
            $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : ($0.kind ?? $0.message) < ($1.kind ?? $1.message)
        }
    }

    /// Drops what has run its course. Called with the lock held.
    private func prune(at now: Date) {
        rows = rows.filter { _, entry in
            if let until = entry.until { return now < until }
            if entry.standing { return true }
            return now.timeIntervalSince(entry.lastSeen) < Self.transientLifetime
        }
    }

    /// A kind that names the source it happened to, when there is one:
    /// `cache.timed-out.source-6`. One row per source, because a source that
    /// keeps failing is the thing a person is looking for.
    public static func kind(_ base: String, source: Int64?) -> String {
        source.map { "\(base).source-\($0)" } ?? base
    }
}
