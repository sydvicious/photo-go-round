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
    /// How many times each photograph has run out of time in this run. The
    /// same file doing it repeatedly is worth knowing about; a single slow
    /// afternoon is not.
    private var timeouts: [Int64: Int] = [:]
    /// **There is no cap on abandoned work, and that is the point of moving it
    /// off the cooperative pool.**
    ///
    /// There was one for a few hours on 2026-08-26, counting every fetch from
    /// start to return. It was right while a blocked `copyItem` sat on a
    /// cooperative thread — eleven of them stopped the runtime — and it became
    /// wrong the moment `BlockingWork` gave that copy a thread of its own,
    /// because work that never returns then held every slot for ever: nothing
    /// was fetched, nothing was cached, and every walk answered `204`.
    ///
    /// What bounds it now is `pauseAfter`. A source that produces nothing but
    /// timeouts is benched, which stops the work at its origin instead of
    /// rationing slots among cards that were never going to arrive.

    /// How many fetches from each source have run out of time since it last
    /// produced anything.
    private var failures: [Int64: Int] = [:]
    /// When each benched source may be asked again.
    private var benchedUntil: [Int64: ContinuousClock.Instant] = [:]
    /// How long its last bench was, so the next one can be longer.
    private var benchLength: [Int64: Duration] = [:]

    /// Timeouts in a row before a source is left alone for a while.
    ///
    /// **Four, lowered from ten on 2026-08-26.** Ten is a lot of slots and a lot
    /// of minutes to spend proving what the first few already showed, and every
    /// one of them is a slot the healthy sources do not get.
    private let pauseAfter: Int
    /// The first bench. Each subsequent one doubles, up to `longestPause`.
    private let firstPause: Duration
    /// **A ceiling, so a source that is simply gone is still retried daily
    /// rather than never.** Doubling without one reaches "not in this lifetime"
    /// after about a dozen rounds, and a network share that comes back would
    /// never be noticed.
    static let longestPause = Duration.seconds(3600)

    /// How many fetches run at once when nothing says otherwise.
    ///
    private let concurrency: Int
    private let fetch: @Sendable (Int64) async -> Bool
    /// How long this photograph's provider may take before its lane is taken
    /// back. Per photograph because the providers differ by an order of
    /// magnitude: a file on disk has no excuse, and a Photos original was
    /// measured stalling for a fixed 300 seconds before transferring normally.
    private let deadline: @Sendable (Int64) -> Duration
    /// A fetch that ran out of time. The card is put back rather than retried
    /// on the spot: whatever was not ready a moment ago is still not ready.
    private let abandoned: @Sendable (Int64) -> Void
    private let log: @Sendable (QueueEvent) -> Void
    /// What to call a photograph in the log, and which source it came from. The
    /// queue carries row ids; a person reading a console wants the name and the
    /// source beside it.
    private let describe: @Sendable (Int64) -> (photo: String, source: Int64?)

    public init(
        concurrency: Int = CacheSettings.defaultConcurrency,
        fetch: @escaping @Sendable (Int64) async -> Bool,
        deadline: @escaping @Sendable (Int64) -> Duration = { _ in .seconds(60) },
        abandoned: @escaping @Sendable (Int64) -> Void = { _ in },
        pauseAfter: Int = 4,
        firstPause: Duration = .seconds(60),
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
        self.deadline = deadline
        self.abandoned = abandoned
        self.pauseAfter = max(1, pauseAfter)
        self.firstPause = firstPause
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

            // **A benched source is not asked at all.** Its cards go back the
            // way a timed-out one does, so they take another turn later rather
            // than spending a slot on a provider that has already shown it has
            // nothing to give.
            if let source = it.source, isBenched(source) {
                abandoned(photoID)
                known.remove(photoID)
                finished(photoID)
                continue
            }

            log(.caching(photo: it.photo, source: it.source, pending: pending.backlog))
            if await !attempt(photoID) {
                // **Said out loud, and in red.** A fetch that never returns
                // is otherwise perfectly silent: no error, no failure, just a
                // lane that never comes back and a queue one card shorter than
                // it should be for as long as the agent runs. That is exactly
                // how this went unnoticed for a day.
                timeouts[photoID, default: 0] += 1
                if let source = it.source { failed(source) }
                log(
                    .cacheTimedOut(
                        photo: it.photo, source: it.source, after: deadline(photoID),
                        occurrence: timeouts[photoID] ?? 1, pending: pending.backlog))
                abandoned(photoID)
            } else if let source = it.source {
                // Anything at all from a source clears its account. An
                // occasional timeout on a working source is weather, not a
                // reason to stop asking.
                failures[source] = 0
                benchLength[source] = nil
            }
            finished(photoID)
        }
        running -= 1
    }

    /// Runs the fetch against its deadline and reports whether it answered.
    ///
    /// **The abandoned work is neither cancelled nor awaited, and both halves
    /// of that are deliberate.** A read blocked inside `bird` waiting for an
    /// iCloud Drive file to materialise does not answer cancellation, and a
    /// structured child would be waited for at scope exit — which is precisely
    /// the wait this exists to escape. So the fetch goes into an unstructured
    /// task that is simply let go of.
    ///
    /// What that buys is the only thing that matters here: the lane comes back.
    /// Observed 2026-08-25, one undownloaded iCloud Drive file held a lane
    /// indefinitely, `executing` stayed at 1, and the gauge — which counts a
    /// card in flight as the queue's — reported a 19-card queue as full against
    /// a target of 20. The queue sat one card short for as long as the agent ran.
    private func attempt(_ photoID: Int64) async -> Bool {
        let race = Race()
        let limit = deadline(photoID)
        let work = Task.detached { [fetch, weak self] in
            _ = await fetch(photoID)
            // Nobody may be waiting any more — that is what abandonment means
            // — but a lane that was released while this ran has nothing to
            // wake it, so the queue is nudged either way.
            race.finish(true)
            await self?.workReturned(photoID)
        }
        let timer = Task.detached {
            try? await Task.sleep(for: limit)
            _ = race.finish(false)
        }
        let answered = await race.outcome()
        timer.cancel()
        // `work` is deliberately not cancelled: see above. Naming it says so.
        _ = work
        return answered
    }

    private func isBenched(_ source: Int64) -> Bool {
        guard let until = benchedUntil[source] else { return false }
        guard ContinuousClock.now < until else {
            // The bench is over. `benchLength` is deliberately kept, so a
            // source that goes straight back to timing out waits longer this
            // time rather than starting again from a minute.
            benchedUntil[source] = nil
            return false
        }
        return true
    }

    /// One more fetch from this source that never answered.
    private func failed(_ source: Int64) {
        let count = (failures[source] ?? 0) + 1
        failures[source] = count
        guard count >= pauseAfter else { return }

        let length = benchLength[source].map { min($0 * 2, Self.longestPause) } ?? firstPause
        benchLength[source] = length
        benchedUntil[source] = ContinuousClock.now + length
        failures[source] = 0
        log(.sourcePaused(source: source, after: count, until: length))
    }

    /// A fetch returned, promptly or long after anybody was waiting.
    private func workReturned(_ photoID: Int64) {
        // Only now may this photograph be asked for again — see `finished`.
        known.remove(photoID)
        // If its lane was given back while it ran, nothing has asked since, so
        // the lanes need a nudge.
        start()
    }

    /// Whichever of the two finishes first, once.
    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: CheckedContinuation<Bool, Never>?
        private var settled: Bool?

        func outcome() async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let settled {
                    lock.unlock()
                    continuation.resume(returning: settled)
                } else {
                    pending = continuation
                    lock.unlock()
                }
            }
        }

        /// True if this call settled the race, false if it had already been
        /// lost — which is how an abandoned fetch learns that it was abandoned.
        @discardableResult
        func finish(_ answered: Bool) -> Bool {
            lock.lock()
            guard settled == nil else {
                lock.unlock()
                return false
            }
            settled = answered
            let continuation = pending
            pending = nil
            lock.unlock()
            continuation?.resume(returning: answered)
            return true
        }
    }

    private func next() -> Int64? {
        guard !waiting.isEmpty else { return nil }
        let photoID = waiting.removeFirst()
        executing += 1
        pending.set(waiting: waiting.count, executing: executing)
        return photoID
    }

    /// The **lane** is free. The work may or may not be.
    ///
    /// `known` is deliberately not cleared here. It is the dedup that stops two
    /// fetches of one photograph, and an abandoned fetch is still fetching: on
    /// 2026-08-26 a timed-out copy was still writing when its card came round
    /// again, and the second attempt failed with *“couldn't be copied to
    /// .staging because an item with the same name already exists”* — two
    /// fetches of one photograph racing on one path. The dedup lasts as long as
    /// the work, which is `workReturned`.
    private func finished(_ photoID: Int64) {
        executing -= 1
        pending.set(waiting: waiting.count, executing: executing)
    }

    /// Anything queued, taken, or running. For tests that need to wait for the
    /// lanes to settle without sleeping.
    var isBusy: Bool { running > 0 || executing > 0 || !waiting.isEmpty }
}
