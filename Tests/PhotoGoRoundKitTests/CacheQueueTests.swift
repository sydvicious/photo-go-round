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
        try await eventually("the first fetch") { fetches.all.count == 1 }
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
