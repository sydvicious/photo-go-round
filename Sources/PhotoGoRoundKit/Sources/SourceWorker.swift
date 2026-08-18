import Foundation

/// One source's producer of pictures, which **ignores a request once it already
/// has as many in flight as it is willing to run**.
///
/// That single rule removes the need for anything else to keep track of what is
/// in flight. The queue fires requests at every source whenever it runs short,
/// without knowing or caring which are busy — a source at its limit drops the
/// request on the floor, and one with room picks it up. There is no
/// in-flight set to maintain, nothing to reconcile when a source is removed
/// mid-flight, and no way for bookkeeping to disagree with reality, because
/// there is no bookkeeping.
///
/// **Several at once, because one at a time wastes most of the wait.** Fetching
/// a picture is nearly all latency — a network round trip, an iCloud download,
/// a disk seek — so a single in-flight request leaves a provider idle for the
/// duration of its own I/O. Four is the number every package manager settled on
/// for the same reason. It is per source rather than global, so a slow provider
/// saturates its own connection without crowding out a fast one.
///
/// It also keeps the overshoot bounded, just less tightly: a nominal queue of
/// 1000 becomes at most 1000 plus `sources × concurrency`.
///
/// Requests are fire-and-forget by construction: `request` returns immediately,
/// and whether it started anything is deliberately not interesting to the caller.
public final class SourceWorker: @unchecked Sendable {
    public let sourceID: Int64
    /// How many fetches this source will run at once.
    public let concurrency: Int

    private let lock = NSLock()
    private var inFlight = 0

    public init(sourceID: Int64, concurrency: Int = SourceWorker.defaultConcurrency) {
        self.sourceID = sourceID
        self.concurrency = max(1, concurrency)
    }

    /// Enough to keep a provider's latency covered without turning a rescan into
    /// a thundering herd against one disk.
    public static let defaultConcurrency = 4

    /// Asks for a picture. Does nothing if this source already has its fill.
    ///
    /// The work runs in its own task, so a provider that takes thirty seconds
    /// delays nothing but its own next request.
    public func request(_ work: @escaping @Sendable () async -> Void) {
        lock.lock()
        guard inFlight < concurrency else {
            lock.unlock()
            Log.sources.debug(
                "source \(self.sourceID, privacy: .public) is at its limit; ignoring the request"
            )
            return
        }
        inFlight += 1
        lock.unlock()

        Task {
            await work()
            self.finish()
        }
    }

    private func finish() {
        lock.lock()
        inFlight -= 1
        lock.unlock()
    }

    /// How many fetches this source has running. Diagnostics only — a caller
    /// branching on it would be rebuilding the bookkeeping this exists to avoid.
    public var inFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    public var isBusy: Bool { inFlightCount > 0 }
}

/// The workers for the sources currently enabled, created on demand.
///
/// A source that goes away simply stops being asked; a worker for it is dropped
/// on the next refresh, and if it was mid-flight its result is discarded when it
/// finds its source gone.
public final class SourceWorkers: @unchecked Sendable {
    private let lock = NSLock()
    private var workers: [Int64: SourceWorker] = [:]

    public init(concurrency: Int = SourceWorker.defaultConcurrency) {
        self.concurrency = concurrency
    }

    private var concurrency: Int

    /// Applies a changed preference.
    ///
    /// Existing workers are dropped rather than mutated, so a fetch already in
    /// flight finishes on the old worker and the new one starts clean. That can
    /// briefly exceed the new limit by whatever was already running, which is
    /// bounded and self-correcting.
    public func setConcurrency(_ value: Int) {
        let clamped = max(1, value)
        lock.lock()
        defer { lock.unlock() }
        guard clamped != concurrency else { return }
        Log.sources.notice(
            "download concurrency \(self.concurrency, privacy: .public) -> \(clamped, privacy: .public)"
        )
        concurrency = clamped
        workers.removeAll()
    }

    public func worker(for sourceID: Int64) -> SourceWorker {
        lock.lock()
        defer { lock.unlock() }
        if let existing = workers[sourceID] { return existing }
        let worker = SourceWorker(sourceID: sourceID, concurrency: concurrency)
        workers[sourceID] = worker
        return worker
    }

    /// Forgets workers for sources that no longer exist or are disabled.
    public func retain(_ sourceIDs: some Sequence<Int64>) {
        let keep = Set(sourceIDs)
        lock.lock()
        defer { lock.unlock() }
        workers = workers.filter { keep.contains($0.key) }
    }

    public var busyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return workers.values.count(where: { $0.isBusy })
    }
}
