import Foundation
import PhotoGoRoundAgentAPI

/// The queue of pictures to cache.
///
/// Serving puts a photograph on here when its bytes are not local, and does not
/// wait. Whatever drains it fetches them and puts the photograph back on the
/// serve queue, so it is shown soon rather than waiting to be dealt again.
///
/// **The check that it is still worth doing happens when a request comes off**,
/// not when it goes on — that is what stops two requests fetching the same
/// photograph twice, and it is the only dedup the design needs: a request for
/// something already cached costs a skip.
///
/// **It holds no database connection.** Like `QueueFiller`, what it needs is
/// injected as a closure the host implements with its own, so what is left here
/// is the queue and nothing else.
public actor CacheQueue {
    /// In the order asked for, because that is the order the deck wanted them.
    private var waiting: [Int64] = []
    /// What is already waiting or in flight. Not the dedup that matters — the
    /// one at the fetch itself is — but it keeps a request that walks a
    /// thousand uncached cards from leaving a thousand duplicates behind it.
    private var known: Set<Int64> = []
    private var running = 0
    /// Photographs a lane has taken and not finished — the download itself,
    /// which is the long phase. Counted so `pending` covers a photograph from
    /// request to landing: the gauge treats a card out for fetching as still
    /// the queue's, and one that vanished from the count mid-download would be
    /// dealt a cold replacement.
    private var executing = 0

    /// How many fetches run at once when nothing says otherwise.
    ///
    private let concurrency: Int
    private let fetch: @Sendable (Int64) async -> Bool
    private let log: @Sendable (QueueEvent) -> Void
    /// What to call a photograph in the log, and which source it came from. The
    /// queue carries row ids; a person reading a console wants the name and the
    /// source beside it.
    private let describe: @Sendable (Int64) -> (photo: String, source: Int64?)

    public init(
        concurrency: Int = CacheSettings.defaultConcurrency,
        fetch: @escaping @Sendable (Int64) async -> Bool,
        describe: @escaping @Sendable (Int64) -> (photo: String, source: Int64?) = {
            ("photo \($0)", nil)
        },
        log: @escaping @Sendable (QueueEvent) -> Void = { $0.report() },
        // Handed in rather than made here, so the fetch closure — which is
        // built before this queue exists — can read the same counter.
        pending: Pending = Pending()
    ) {
        self.pending = pending
        self.concurrency = max(1, concurrency)
        self.fetch = fetch
        self.describe = describe
        self.log = log
    }

    /// How many are waiting to be fetched, for a status line to report.
    public var depth: Int { waiting.count }

    /// Photographs asked for and not yet landed — waiting for a lane *plus*
    /// mid-download — readable without awaiting.
    ///
    /// Wider than `depth` on purpose: the gauge reads this, and a card counts
    /// as the queue's until its fetch finishes, not merely until a lane takes
    /// it. It is a bare counter because the lines written while a photograph
    /// is being fetched come from `PhotoCache`, which is not an actor and
    /// cannot await one.
    /// Two numbers, because two different questions are asked of them and
    /// answering both with one produced a line that read as a stuck fetch.
    public final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private var queued = 0

        public init() {}

        /// Waiting **plus in flight**. What the gauge wants: a card out being
        /// fetched still counts as the queue's when deciding whether to deal,
        /// or one that vanished mid-download would be dealt a cold replacement.
        public var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        /// Waiting only — **what "waiting" means in a log line**.
        ///
        /// The completion messages are emitted from inside the fetch closure,
        /// which runs before the queue retires the item, so reading `count`
        /// there counts the finishing download as though it were still queued
        /// behind itself. The last fetch of a burst then prints "1 waiting" and,
        /// with nothing following it, sits at the bottom of the console looking
        /// exactly like a fetch that never returned. Observed 2026-08-25.
        public var backlog: Int {
            lock.lock()
            defer { lock.unlock() }
            return queued
        }

        func set(waiting: Int, executing: Int) {
            lock.lock()
            queued = waiting
            value = waiting + executing
            lock.unlock()
        }
    }

    public nonisolated let pending: Pending

    /// How long the backlog of pictures to fetch may get.
    ///
    /// **A lead, not a work list.** Serving asks for the cards ahead of the one
    /// it showed, every time it shows one, so left unbounded the requests
    /// accumulate until they name the entire library — thousands of fetches
    /// queued behind four lanes, most of them for cards that will be served
    /// hours from now or never. What is actually wanted is enough depth that the
    /// next few cards are ready when their turn comes.
    ///
    /// Fifty against a look-ahead of twenty: two rounds of lead plus room for
    /// what a walk skipped past, and small enough that the backlog turns over
    /// fast rather than going stale.
    public static let maximumWaiting = 50

    /// Asks for a photograph's bytes. Returns at once, whatever happens next.
    public func request(_ photoID: Int64) {
        // **Checked before it is remembered.** Marking a refused photograph as
        // known would retire it: `known` is what stops two requests fetching the
        // same picture twice, and an id that goes in without ever coming out
        // could never be asked for again.
        guard waiting.count < Self.maximumWaiting else {
            let it = describe(photoID)
            log(.cacheRefused(photo: it.photo, source: it.source, pending: waiting.count))
            return
        }
        guard known.insert(photoID).inserted else { return }
        waiting.append(photoID)
        pending.set(waiting: waiting.count, executing: executing)
        let it = describe(photoID)
        log(.cacheRequested(photo: it.photo, source: it.source, pending: waiting.count))
        start()
    }

    /// Fills the lanes that are free. Each lane keeps taking work until the
    /// queue is empty, so fetches run at whatever rate the providers manage
    /// rather than at whatever rate requests happen to arrive.
    private func start() {
        while running < concurrency, !waiting.isEmpty {
            running += 1
            Task { await self.drain() }
        }
    }

    private func drain() async {
        while let photoID = next() {
            let it = describe(photoID)
            log(.caching(photo: it.photo, source: it.source, pending: pending.backlog))
            _ = await fetch(photoID)
            finished(photoID)
        }
        running -= 1
    }

    private func next() -> Int64? {
        guard !waiting.isEmpty else { return nil }
        let photoID = waiting.removeFirst()
        executing += 1
        pending.set(waiting: waiting.count, executing: executing)
        return photoID
    }

    private func finished(_ photoID: Int64) {
        known.remove(photoID)
        executing -= 1
        pending.set(waiting: waiting.count, executing: executing)
    }

    /// Anything queued, taken, or running. For tests that need to wait for the
    /// lanes to settle without sleeping.
    var isBusy: Bool { running > 0 || executing > 0 || !waiting.isEmpty }
}
