import Foundation
import Testing

@testable import PhotoGoRoundKit

/// The queue of pictures to cache.
///
/// Serving puts photographs on it and does not wait; this is what happens to
/// them afterwards. Every test here uses a fetch closure that records rather
/// than downloads, so what is asserted is the queue's behaviour and not a
/// provider's.
@Suite("The queue of pictures to cache")
struct CacheQueueTests {

    /// A fetch that records what it was asked for, and can be held open so a
    /// test can look at the queue mid-flight.
    private final class Fetches: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Int64] = []
        private var live = 0
        private var peak = 0
        /// When set, every fetch waits on this before finishing.
        private var gate: (() async -> Void)?

        init(waitingOn gate: (() async -> Void)? = nil) { self.gate = gate }

        var work: @Sendable (Int64) async -> Bool {
            { [self] id in
                // Every mutation is its own non-async call, so the lock is never
                // held across the suspension below — which is exactly the bug
                // that restriction exists to prevent.
                let gate = began(id)
                await gate?()
                ended()
                return true
            }
        }

        private func began(_ id: Int64) -> (() async -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            seen.append(id)
            live += 1
            peak = max(peak, live)
            return gate
        }

        private func ended() {
            lock.lock()
            live -= 1
            lock.unlock()
        }

        var all: [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
        var highWater: Int {
            lock.lock()
            defer { lock.unlock() }
            return peak
        }
    }

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        var log: @Sendable (QueueEvent) -> Void {
            { [self] event in
                lock.lock()
                lines.append(event.line)
                lock.unlock()
            }
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    /// Waits for a condition rather than for a duration. **Bounded** — a queue
    /// that never drains is a failed test, not a hung suite.
    ///
    /// **Ten seconds rather than two, and the difference is a flake that took
    /// two evenings to attribute.** The bound is there to fail fast when the
    /// queue is genuinely broken, and two seconds did that — while also
    /// failing when nothing was broken at all. Roughly one full-suite run in
    /// eight reported five issues here and nowhere else, which is the tell:
    /// five *different* tests timing out in the same run is not five slow
    /// queues, it is the whole target's tasks being starved of a core while
    /// four test targets run in parallel. Reproduced on demand by loading
    /// every core and running this suite; never once reproducible on an idle
    /// machine. A hang still fails rather than wedging the suite, ten seconds
    /// later instead of two.
    private func eventually(
        _ description: String, within: Duration = .seconds(10), _ condition: () async -> Bool
    ) async throws {
        let giveUp = ContinuousClock.now + within
        while ContinuousClock.now < giveUp {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(description)")
    }

    // MARK: - Draining

    @Test("Everything asked for is fetched")
    func itDrains() async throws {
        let fetches = Fetches()
        let queue = CacheQueue(concurrency: 2, fetch: fetches.work, log: { _ in })

        for id in Int64(1)...Int64(20) { await queue.request(id) }

        try await eventually("all twenty to be fetched") { fetches.all.count == 20 }
        #expect(Set(fetches.all) == Set(Int64(1)...Int64(20)))
        try await eventually("the queue to empty") { await queue.depth == 0 }
    }

    @Test("Asking twice for the same photograph fetches it once")
    func itDedupesWhileWaiting() async throws {
        // Held open, so everything piles up behind the first fetch and the
        // duplicates are still waiting when the second request arrives.
        let release = Gate()
        let fetches = Fetches(waitingOn: { await release.wait() })
        let queue = CacheQueue(concurrency: 1, fetch: fetches.work, log: { _ in })

        await queue.request(7)
        await queue.request(7)
        await queue.request(8)
        await queue.request(7)

        await release.open()
        try await eventually("both to be fetched") { fetches.all.count == 2 }
        #expect(fetches.all.sorted() == [7, 8])
    }

    @Test("A photograph asked for again after its fetch finished is fetched again")
    func itForgetsWhatItFinished() async throws {
        // The dedup is about what is *waiting*, not a memory of everything ever
        // fetched — deciding whether a fetch is still needed is the fetch's own
        // job, and it is the one that can see the cache.
        let fetches = Fetches()
        let queue = CacheQueue(concurrency: 1, fetch: fetches.work, log: { _ in })

        await queue.request(3)
        // **Idle, not merely fetched-once.** The dedup is released by
        // `finished`, which runs after the fetch returns — so observing the
        // fetch itself is a moment too early and asking again there is refused
        // as a duplicate. The window was small enough to get away with until
        // the fetch began running against a deadline, which widened it.
        try await eventually("the first fetch to be retired") { await !queue.isBusy }
        #expect(fetches.all == [3])
        await queue.request(3)
        try await eventually("the second fetch") { fetches.all.count == 2 }
        #expect(fetches.all == [3, 3])
    }

    // MARK: - How much backlog

    @Test("The queue is bounded, so a warm-up cannot enqueue the whole library")
    func itIsBounded() async throws {
        // Held open, so nothing drains and the backlog is whatever `request`
        // allowed.
        let release = Gate()
        let fetches = Fetches(waitingOn: { await release.wait() })
        let queue = CacheQueue(concurrency: 1, fetch: fetches.work, log: { _ in })

        for id in Int64(1)...Int64(500) { await queue.request(id) }

        // **Not five hundred.** Serving asks for the cards ahead of the one it
        // showed, every time it shows one, so over a night the requests add up
        // to the entire library. What is wanted is a short lead — enough that
        // the next few cards are ready — and not a work list that grows without
        // limit and pins the fetch lanes to a queue nobody is waiting on.
        #expect(await queue.depth == CacheQueue.maximumWaiting)

        await release.open()
        try await eventually("the backlog to drain") { await queue.depth == 0 }
        // One in flight plus the cap: everything else was refused, not stored.
        #expect(fetches.all.count == CacheQueue.maximumWaiting + 1)
    }

    @Test("A refused photograph can be asked for again once there is room")
    func refusingDoesNotBlacklist() async throws {
        let release = Gate()
        let fetches = Fetches(waitingOn: { await release.wait() })
        let queue = CacheQueue(concurrency: 1, fetch: fetches.work, log: { _ in })

        for id in Int64(1)...Int64(500) { await queue.request(id) }
        // 999 was refused. If refusal left it remembered as "already waiting",
        // it could never be asked for again — a photograph the cap happened to
        // turn away once would be turned away for the life of the process.
        await release.open()
        try await eventually("the backlog to drain") { await queue.depth == 0 }

        await queue.request(999)
        try await eventually("the late arrival to be fetched") { fetches.all.contains(999) }
    }

    // MARK: - How many at once

    @Test("No more than the concurrency runs at once, however many are asked for")
    func itBoundsConcurrency() async throws {
        let release = Gate()
        let fetches = Fetches(waitingOn: { await release.wait() })
        let queue = CacheQueue(concurrency: 3, fetch: fetches.work, log: { _ in })

        for id in Int64(1)...Int64(30) { await queue.request(id) }
        // Three are in flight and the rest are waiting. **This is the only bound
        // on fetches in flight in the whole design**, so it is worth pinning.
        try await eventually("three in flight") { fetches.all.count == 3 }
        #expect(fetches.highWater <= 3)

        await release.open()
        try await eventually("the rest to follow") { fetches.all.count == 30 }
        #expect(fetches.highWater <= 3, "more ran at once than the queue was told to allow")
    }

    @Test("Work arriving while it is draining is picked up by the lanes already running")
    func itAcceptsWorkWhileDraining() async throws {
        let fetches = Fetches()
        let queue = CacheQueue(concurrency: 2, fetch: fetches.work, log: { _ in })

        await queue.request(1)
        await queue.request(2)
        try await eventually("the first two") { fetches.all.count == 2 }

        for id in Int64(3)...Int64(10) { await queue.request(id) }
        try await eventually("the rest") { fetches.all.count == 10 }
        #expect(Set(fetches.all) == Set(Int64(1)...Int64(10)))
    }

    @Test("A photograph being fetched still counts as pending")
    func inFlightFetchesCountAsPending() async throws {
        // `Pending` is the gauge's window onto this queue, and the gauge treats
        // a card out for fetching as still the queue's — deal to cover the dip
        // and the fetch lands on a card nobody held a place for, which is the
        // churn pacing-by-serving exists to remove. The long phase of a fetch
        // is the download itself, so the count must cover a photograph from
        // the moment it is asked for until its fetch finishes, not merely
        // while it waits for a lane.
        let release = Gate()
        let fetches = Fetches(waitingOn: { await release.wait() })
        let queue = CacheQueue(concurrency: 1, fetch: fetches.work, log: { _ in })

        await queue.request(5)
        try await eventually("the fetch to start") { fetches.all.count == 1 }
        #expect(await queue.depth == 0, "the lane took it, so it is no longer waiting")
        #expect(queue.pending.count == 1, "a photograph mid-download vanished from the gauge")

        await release.open()
        try await eventually("the fetch to finish and the count to fall") {
            queue.pending.count == 0
        }
    }

    // MARK: - What it says

    @Test("It says what it was asked for and what it is fetching, under CACHE:")
    func itSaysWhatItIsDoing() async throws {
        let fetches = Fetches()
        let heard = Heard()
        let queue = CacheQueue(
            concurrency: 1, fetch: fetches.work,
            describe: { ("photo-\($0).heic", 6) }, log: heard.log)

        await queue.request(4)
        try await eventually("the fetch") { fetches.all.count == 1 }

        #expect(heard.all.contains("CACHE: asked for photo-4.heic (source 6) — 1 waiting"))
        #expect(heard.all.contains { $0.hasPrefix("CACHE: fetching photo-4.heic (source 6) — ") })
        // Every line names its queue, so two interleaved on one console stay
        // readable.
        #expect(heard.all.allSatisfy { $0.hasPrefix("CACHE: ") })
    }
}

/// A latch a test can hold fetches behind, so "three are in flight" is a fact
/// rather than a race.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

/// What a completion line is entitled to say about the backlog.
///
/// Observed live on 2026-08-25: the agent's console ended on `CACHE: … fetched,
/// 450103 bytes, back on the queue — 1 waiting` and stayed there. Nothing was
/// waiting. The count is read from inside the fetch closure, which runs *before*
/// `CacheQueue` retires the item, so the last fetch of a burst reports its own
/// download as though it were still queued behind itself.
@Suite("What a finished fetch reports")
struct FinishedFetchReportingTests {

    /// A box the fetch closure writes to, standing in for the log line
    /// `PhotoCache` emits at exactly this moment.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func record(_ value: Int) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }
        var all: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    @Test("The only fetch in flight reports an empty backlog, not itself")
    func theLastFetchReportsNothingWaiting() async throws {
        let pending = CacheQueue.Pending()
        let seen = Seen()
        let queue = CacheQueue(
            concurrency: 4,
            // Exactly where `PhotoCache` logs `.cached`: inside the fetch, an
            // instant before the queue lets the item go.
            fetch: { _ in
                seen.record(pending.backlog)
                return true
            },
            log: { _ in },
            pending: pending
        )

        await queue.request(1)
        while await queue.isBusy { await Task.yield() }

        #expect(seen.all == [0], "a completion line would have printed \(seen.all) waiting")
        #expect(pending.count == 0)
        #expect(pending.backlog == 0)
    }

    /// Holds the lanes still so the backlog can be built up behind a running
    /// fetch. Without it the first request's lane can drain before the second
    /// arrives, and what the first fetch sees is a scheduling accident.
    private actor Gate {
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !open else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            open = true
            for continuation in waiting { continuation.resume() }
            waiting.removeAll()
        }
    }

    @Test("A backlog behind the running fetch is reported, and shrinks to nothing")
    func aRealBacklogIsStillCounted() async throws {
        // The fix must not simply report zero: a fetch with work stacked behind
        // it should say so, which is the whole reason the number is printed.
        let pending = CacheQueue.Pending()
        let seen = Seen()
        let gate = Gate()
        let queue = CacheQueue(
            concurrency: 1,
            fetch: { _ in
                seen.record(pending.backlog)
                await gate.wait()
                return true
            },
            log: { _ in },
            pending: pending
        )

        for id in Int64(1)...3 { await queue.request(id) }
        await gate.release()
        while await queue.isBusy { await Task.yield() }

        // The first lane's reading depends on how much of the batch had landed
        // when it started, which is not something to pin. The two behind it are
        // exact: one still queued, then none — and never counting itself.
        #expect(seen.all.count == 3)
        #expect(Array(seen.all.suffix(2)) == [1, 0], "reported \(seen.all)")
    }
}

/// A fetch that takes too long, and what the queue owes everyone else when it
/// does.
///
/// Two failures a day apart, both invisible while they were happening.
///
/// **2026-08-25**: an iCloud Drive file that was not downloaded locally. The
/// read handed off to `bird` and did not return. Its lane was never released,
/// `executing` stayed at 1, and `FillerBox.Gauge.isShort` — which counts a card
/// in flight as the queue's — therefore read a 19-card queue as full against a
/// target of 20. One file pinned the queue a card short for as long as the agent
/// ran, saying nothing.
///
/// **2026-08-26**: the deadline added to fix that released the lane but could
/// not stop the work, so a freed lane started another copy while the abandoned
/// one kept running. Eleven accumulated and took every thread in the
/// cooperative pool. Not a deadlock — nothing left to run on.
///
/// So the deadline governs the *lane*, and a separate cap governs the *work*.
@Suite("A fetch that overruns")
struct OverrunningFetchTests {

    /// Waits for what is being waited for, rather than for a duration. Four
    /// test targets run in parallel here, so a fetch given two hundred
    /// milliseconds gets them only if a core is free.
    private func settles(
        _ what: String, within: Duration = .seconds(20), _ condition: () async -> Bool
    ) async throws {
        let giveUp = ContinuousClock.now + within
        while ContinuousClock.now < giveUp {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(what)")
    }

    /// A counter the fetch closures can write to from any thread.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int64] = []

        func add(_ value: Int64) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var all: [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }

        var count: Int { all.count }
    }

    /// The console lines a run produced, from any thread.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [String] = []

        func record(_ line: String) {
            lock.lock()
            said.append(line)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return said
        }
    }

    private static let deadline = Duration.milliseconds(200)

    /// A fetch that never returns at all.
    private static let neverAnswers: @Sendable (Int64) async -> Bool = { _ in
        try? await Task.sleep(for: .seconds(3600))
        return false
    }

    // MARK: - The lane

    @Test("An overrunning fetch gives its lane back")
    func theLaneComesBack() async throws {
        // The whole point: whatever the provider is doing, the queue's own
        // bookkeeping recovers, so the gauge stops reading a short queue as full.
        let pending = CacheQueue.Pending()
        let queue = CacheQueue(
            concurrency: 2, fetch: Self.neverAnswers,
            deadline: { _ in Self.deadline }, log: { _ in }, pending: pending)

        await queue.request(1)
        try await settles("the lane to be released") { pending.count == 0 }

        #expect(pending.count == 0)
        #expect(pending.backlog == 0)
    }

    @Test("The card is put back in the pool rather than retried on the spot")
    func theCardGoesBack() async throws {
        // Whatever was not ready a moment ago is still not ready, and a card
        // left queued would be asked for again at the next look-ahead and hang
        // the next lane the same way.
        let putBack = Tally()
        let queue = CacheQueue(
            concurrency: 2, fetch: Self.neverAnswers,
            deadline: { _ in Self.deadline },
            abandoned: { putBack.add($0) }, log: { _ in })

        await queue.request(5)
        try await settles("the card to be put back") { putBack.all == [5] }

        #expect(putBack.all == [5])
    }

    @Test("A fetch that answers in time is left alone")
    func aPromptFetchIsNotDisturbed() async throws {
        let putBack = Tally()
        let queue = CacheQueue(
            concurrency: 1, fetch: { _ in true },
            deadline: { _ in .seconds(30) },
            abandoned: { putBack.add($0) }, log: { _ in })

        await queue.request(7)
        try await settles("the lane to settle") { await !queue.isBusy }

        #expect(putBack.all.isEmpty)
    }

    // MARK: - Saying so

    @Test("A timeout is announced, and a repeat offender counts itself")
    func timeoutsAreAnnounced() async throws {
        // A provider that fails says so; one that simply never returns says
        // nothing at all, and the only trace was a queue permanently a card
        // short. A single slow afternoon and one file that never works are also
        // different problems, and the console has to tell them apart.
        let said = Lines()
        let returned = Tally()
        let queue = CacheQueue(
            concurrency: 1,
            // Overruns and then returns. The wait below is on the *return*,
            // because the dedup lasts as long as the work — asking again while
            // the previous attempt is still running is refused, correctly.
            fetch: { photoID in
                try? await Task.sleep(for: .milliseconds(300))
                returned.add(photoID)
                return false
            },
            deadline: { _ in Self.deadline },
            log: { event in
                if case .cacheTimedOut = event { said.record(event.line) }
            })

        for round in 1...3 {
            await queue.request(11)
            try await settles("timeout \(round)") { said.all.count == round }
            try await settles("attempt \(round) to return") { returned.all.count == round }
        }

        let lines = said.all
        try #require(lines.count == 3)
        #expect(lines[0].contains("did not answer"))
        // The first time is a timeout; the third is a pattern.
        #expect(!lines[0].contains("times now for this file"))
        #expect(lines[2].contains("3 times now for this file"))
    }

    // MARK: - The work

    @Test("Abandoned work does not hold a slot, because it is not on the pool")
    func abandonedWorkDoesNotHoldASlot() async throws {
        // **This asserted the opposite for a few hours on 2026-08-26, and was
        // right to.** While a blocked `copyItem` sat on a cooperative thread,
        // letting a freed lane start another was how eleven of them stopped the
        // runtime. `BlockingWork` gives that copy a thread of its own, so the
        // lane can be reused — and what stops a source that never answers is
        // the bench, not a rationed slot.
        let started = Tally()
        let queue = CacheQueue(
            concurrency: 2,
            fetch: { photoID in
                started.add(photoID)
                try? await Task.sleep(for: .seconds(3600))
                return false
            },
            deadline: { _ in Self.deadline },
            // High enough that the bench does not fire during this test; the
            // bench has a suite of its own.
            pauseAfter: 1_000,
            log: { _ in })

        for id in Int64(1)...6 { await queue.request(id) }
        try await settles("every card to be attempted") { started.count == 6 }

        #expect(started.count == 6, "lanes were held by work nobody is waiting for")
    }

    @Test("A slot comes back when its abandoned work finally returns")
    func aReturningOrphanFreesItsSlot() async throws {
        let started = Tally()
        let queue = CacheQueue(
            concurrency: 1,
            fetch: { photoID in
                started.add(photoID)
                // The first overruns and then finishes; the second must be let
                // in once it has.
                if photoID == 1 { try? await Task.sleep(for: .milliseconds(500)) }
                return true
            },
            deadline: { _ in Self.deadline }, log: { _ in })

        await queue.request(1)
        await queue.request(2)
        try await settles("the freed slot to take the second card") { started.count == 2 }

        #expect(started.all.sorted() == [1, 2])
    }

    @Test("A photograph still being fetched is not fetched a second time")
    func anAbandonedFetchIsStillAFetch() async throws {
        // **The dedup lasts as long as the work, not as long as the lane.**
        // Observed 2026-08-26: a timed-out copy was still writing when its card
        // came round again, and the second attempt failed with "couldn't be
        // copied to .staging because an item with the same name already
        // exists". Two fetches of one photograph, racing on one path.
        let started = Tally()
        let queue = CacheQueue(
            concurrency: 4,
            fetch: { photoID in
                started.add(photoID)
                try? await Task.sleep(for: .seconds(3600))
                return false
            },
            deadline: { _ in Self.deadline }, log: { _ in })

        await queue.request(9)
        try await settles("the lane to be released") { await !queue.isBusy }
        // The card has come back round, as a put-back card does.
        await queue.request(9)
        try await Task.sleep(for: .milliseconds(300))

        #expect(started.all == [9], "the same photograph was fetched twice at once")
    }

    @Test("A wedged fetch does not stop the other lanes")
    func neighboursKeepWorking() async throws {
        // A wedged fetch keeps its own slot. What must go on working is every
        // other slot — the property that makes the cap survivable rather than
        // merely safe.
        let done = Tally()
        let queue = CacheQueue(
            concurrency: 3,
            fetch: { photoID in
                if photoID == 1 { try? await Task.sleep(for: .seconds(3600)) }
                done.add(photoID)
                return true
            },
            deadline: { _ in Self.deadline }, log: { _ in })

        for id in Int64(1)...3 { await queue.request(id) }
        try await settles("the other two to finish") { done.all.sorted() == [2, 3] }

        #expect(done.all.sorted() == [2, 3], "a wedged card blocked its neighbours")
    }
}

/// A source that keeps timing out gets benched.
///
/// **Timeouts on their own are not a problem; a source that only produces them
/// is.** On 2026-08-26 every one of eight fetch slots was held by an iCloud
/// Drive folder whose files never materialised, and the two other sources —
/// eight photographs between them, all on local disk — were never asked for.
/// Nothing was cached for as long as the agent ran.
///
/// So after enough of them in a row, stop asking that source for a while, and
/// wait longer each time it happens again. One success clears it.
@Suite("A source that keeps timing out")
struct BenchedSourceTests {

    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int64] = []
        func add(_ value: Int64) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }
        var all: [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// The console lines a run produced, from any thread.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [String] = []
        func record(_ line: String) {
            lock.lock()
            said.append(line)
            lock.unlock()
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return said
        }
    }

    private func settles(
        _ what: String, within: Duration = .seconds(20), _ condition: () async -> Bool
    ) async throws {
        let giveUp = ContinuousClock.now + within
        while ContinuousClock.now < giveUp {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(what)")
    }

    /// Odd photo ids belong to source 1, even ones to source 2, so a test can
    /// say which source a card came from without a database.
    private func describing(_ photoID: Int64) -> (photo: String, source: Int64?) {
        ("photo-\(photoID)", photoID % 2 == 0 ? 2 : 1)
    }

    @Test("Four is the shipped threshold")
    func fourByDefault() async throws {
        // Lowered from ten on 2026-08-26: ten is a lot of slots and a lot of
        // minutes to spend proving what the first few already showed.
        let attempted = Tally()
        let queue = CacheQueue(
            concurrency: 1,
            fetch: { photoID in
                attempted.add(photoID)
                try? await Task.sleep(for: .seconds(3600))
                return false
            },
            deadline: { _ in .milliseconds(50) },
            firstPause: .seconds(30),
            describe: describing,
            log: { _ in })

        for card in stride(from: Int64(2), through: 40, by: 2) { await queue.request(card) }
        try await settles("four timeouts") { attempted.all.count >= 4 }
        try await Task.sleep(for: .milliseconds(300))

        #expect(attempted.all.count <= 5, "the default threshold is not four")
    }

    @Test("Ten timeouts bench the source, and the next card is not even attempted")
    func tenTimeoutsBenchIt() async throws {
        let attempted = Tally()
        let queue = CacheQueue(
            concurrency: 4,
            fetch: { photoID in
                attempted.add(photoID)
                try? await Task.sleep(for: .seconds(3600))
                return false
            },
            deadline: { _ in .milliseconds(50) },
            pauseAfter: 10,
            firstPause: .seconds(30),
            describe: describing,
            log: { _ in }
        )

        // Thirty cards from source 2, all of which will time out.
        for card in stride(from: Int64(2), through: 60, by: 2) { await queue.request(card) }
        try await settles("ten timeouts") { attempted.all.count >= 10 }
        try await Task.sleep(for: .milliseconds(400))

        // Cards already in flight when the tenth timeout lands were started
        // before the bench existed, so the ceiling is the threshold plus a
        // lane's worth — not the threshold exactly. What matters is that it
        // stops, well short of the thirty asked for.
        let attempts = attempted.all.count
        #expect(attempts >= 10)
        #expect(attempts <= 14, "the source was still being asked after ten timeouts: \(attempts)")
    }

    @Test("A benched source does not take the healthy one down with it")
    func aHealthySourceKeepsWorking() async throws {
        // The failure this exists for: two sources, one hostile, and the good
        // one never asked because every slot was spent on the bad one.
        let served = Tally()
        let queue = CacheQueue(
            concurrency: 2,
            fetch: { photoID in
                // Even ids are the hostile source and never answer.
                if photoID % 2 == 0 {
                    try? await Task.sleep(for: .seconds(3600))
                    return false
                }
                served.add(photoID)
                return true
            },
            deadline: { _ in .milliseconds(50) },
            pauseAfter: 10,
            firstPause: .seconds(30),
            describe: describing,
            log: { _ in }
        )

        for card in stride(from: Int64(2), through: 40, by: 2) { await queue.request(card) }
        for card in stride(from: Int64(1), through: 9, by: 2) { await queue.request(card) }

        try await settles("the healthy source to be served") { served.all.count == 5 }
        #expect(served.all.sorted() == [1, 3, 5, 7, 9])
    }

    @Test("A success clears the count, so an occasional timeout never benches anything")
    func oneSuccessClearsIt() async throws {
        let attempted = Tally()
        let queue = CacheQueue(
            concurrency: 1,
            fetch: { photoID in
                attempted.add(photoID)
                // Every fourth card answers; the rest overrun and then return.
                if photoID % 8 == 0 { return true }
                try? await Task.sleep(for: .milliseconds(120))
                return false
            },
            deadline: { _ in .milliseconds(40) },
            pauseAfter: 10,
            firstPause: .seconds(30),
            describe: describing,
            log: { _ in }
        )

        for card in stride(from: Int64(2), through: 40, by: 2) { await queue.request(card) }
        try await settles("every card to be attempted") { attempted.all.count == 20 }

        #expect(
            attempted.all.count == 20,
            "a source with successes among its timeouts was benched anyway")
    }

    @Test("The pause is announced, and lengthens each time")
    func thePauseLengthens() async throws {
        let said = Lines()
        let queue = CacheQueue(
            concurrency: 4,
            fetch: { _ in
                try? await Task.sleep(for: .milliseconds(80))
                return false
            },
            deadline: { _ in .milliseconds(20) },
            pauseAfter: 2,
            firstPause: .milliseconds(100),
            describe: describing,
            log: { event in
                if case .sourcePaused = event { said.record(event.line) }
            }
        )

        // Two timeouts bench it; after the short pause elapses, two more bench
        // it again for twice as long.
        for round in 0..<3 {
            for card in stride(from: Int64(2), through: 8, by: 2) {
                await queue.request(card + Int64(round) * 10)
            }
            try await Task.sleep(for: .milliseconds(400))
        }

        let announced = said.all
        try #require(announced.count >= 2)
        #expect(announced[0].contains("paused"))
        // Doubling, so the second pause names a longer interval than the first.
        #expect(announced[0] != announced[1])
    }
}
