import Foundation

/// The errors the agent has reported since it launched, one row per kind.
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
/// **Nothing is recorded until `startRecording`**, and only the agent calls it.
/// The kit and this module log the same errors from `pgr_ctl`, the app, and the
/// screensaver, none of which has a dashboard to show them on.
///
/// In memory and gone at exit, like everything else "since launch".
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
    }

    /// The agent's record. A process that never starts recording leaves it empty.
    public static let shared = AgentErrors()

    /// Kinds kept at once. A new kind past this pushes out the one seen longest
    /// ago, so a flood of unclassified lines costs the oldest rows and not
    /// memory without bound.
    public static let defaultCapacity = 100

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

    /// `kind` nil groups the report by its exact text.
    public func record(kind: String?, _ message: String, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }

        let key = kind ?? message
        if let existing = rows[key] {
            rows[key] = Entry(
                kind: kind, message: message, count: existing.count + 1,
                firstSeen: existing.firstSeen, lastSeen: now)
            return
        }
        if rows.count >= capacity, let stalest = rows.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
            rows.removeValue(forKey: stalest.key)
        }
        rows[key] = Entry(kind: kind, message: message, count: 1, firstSeen: now, lastSeen: now)
    }

    /// Most recently seen first.
    public var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return rows.values.sorted {
            $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : ($0.kind ?? $0.message) < ($1.kind ?? $1.message)
        }
    }

    /// A kind that names the source it happened to, when there is one:
    /// `cache.timed-out.source-6`. One row per source, because a source that
    /// keeps failing is the thing a person is looking for.
    public static func kind(_ base: String, source: Int64?) -> String {
        source.map { "\(base).source-\($0)" } ?? base
    }
}
