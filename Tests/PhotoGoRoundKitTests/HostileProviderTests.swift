import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// Surviving a source that will not answer.
///
/// **Written 2026-08-26, the night an iCloud Drive folder of 436 album covers
/// stopped answering at all** — `bird` idle at 0% CPU, metadata served, content
/// never delivered — while it was 98% of the library. Four faults, each of
/// which stopped pictures reaching the screen.
///
/// This suite replaces `CacheQueueTests`. The queue of pictures to cache is
/// gone with the demand-driven path that fed it, but the three mechanisms it
/// carried are not: a deadline that gives the lane back, work that is let go of
/// rather than waited for, and a bench that stops asking a source that has
/// nothing to give. They live in `FetchDeadline` and `SourceBench` now, which
/// is what these test.
@Suite("A source that will not answer")
struct HostileProviderTests {

    // MARK: - The lane comes back

    @Test("A fetch that never returns gives the lane back anyway")
    func aStalledFetchReleasesItsLane() async throws {
        // The original fault: no provider had a timeout, because none had
        // needed one. One undownloaded file left the count at 1 for as long as
        // the agent ran, and a nineteen-card queue read as full against a
        // target of twenty — silently.
        let answered = await FetchDeadline.run(
            within: .milliseconds(50),
            work: { try? await Task.sleep(for: .seconds(60)) })

        #expect(answered == false)
    }

    @Test("Work that finishes in time answers, and is not abandoned")
    func promptWorkAnswers() async throws {
        let abandoned = Flag()
        let answered = await FetchDeadline.run(
            within: .seconds(30),
            work: {},
            whenAbandoned: { abandoned.raise() })

        #expect(answered)
        #expect(!abandoned.value)
    }

    @Test("Abandoned work still reports when it eventually returns")
    func abandonedWorkSaysSoLater() async throws {
        // **Neither cancelled nor awaited**, so it comes back on its own time.
        // Saying so is the difference between a fetch that is slow and a fetch
        // that is never coming — which is exactly what went unnoticed for a day.
        let abandoned = Flag()
        let answered = await FetchDeadline.run(
            within: .milliseconds(20),
            work: { try? await Task.sleep(for: .milliseconds(120)) },
            whenAbandoned: { abandoned.raise() })
        #expect(answered == false)

        try await Task.sleep(for: .milliseconds(400))
        #expect(abandoned.value, "the abandoned fetch returned and nothing noticed")
    }

    // MARK: - The bench

    @Test("A source is left alone after enough timeouts in a row")
    func repeatedTimeoutsBenchASource() {
        let bench = SourceBench(pauseAfter: 4, firstPause: .seconds(60))

        #expect(!bench.isBenched(7))
        for _ in 0..<3 { #expect(bench.failed(7) == nil) }
        #expect(!bench.isBenched(7), "benched before it had earned it")

        #expect(bench.failed(7) == .seconds(60))
        #expect(bench.isBenched(7))
    }

    @Test("Anything at all from a source clears its account")
    func successIsWeatherProof() {
        // An occasional timeout on a working source is weather, not a reason to
        // stop asking.
        let bench = SourceBench(pauseAfter: 4, firstPause: .seconds(60))
        for _ in 0..<3 { _ = bench.failed(7) }
        bench.succeeded(7)

        for _ in 0..<3 { #expect(bench.failed(7) == nil) }
        #expect(!bench.isBenched(7))
    }

    @Test("Each bench is longer than the last")
    func benchesDouble() {
        let bench = SourceBench(pauseAfter: 1, firstPause: .seconds(60))
        let start = ContinuousClock.now

        #expect(bench.failed(7, now: start) == .seconds(60))
        // Past the first bench, and straight back to failing: it waits longer
        // this time rather than starting again from a minute.
        #expect(bench.failed(7, now: start + .seconds(61)) == .seconds(120))
        #expect(bench.failed(7, now: start + .seconds(200)) == .seconds(240))
    }

    @Test("The bench has a ceiling, so a source that is gone is still retried")
    func benchesAreCapped() {
        // **Doubling without a ceiling reaches "not in this lifetime" after
        // about a dozen rounds**, and a network share that came back would
        // never be noticed.
        let bench = SourceBench(pauseAfter: 1, firstPause: .seconds(60))
        var now = ContinuousClock.now
        var last: Duration = .zero
        for _ in 0..<20 {
            last = try! #require(bench.failed(7, now: now))
            now = now + last + .seconds(1)
        }

        #expect(last == SourceBench.longestPause)
        #expect(last == .seconds(3600), "an unreachable source must still be retried hourly")
    }

    @Test("Benching is per source, so one bad share does not stop the others")
    func benchingIsPerSource() {
        // The fault this exists to prevent: a source that is 98% of the library
        // gets 98% of the draws, and without a bench it takes every lane.
        let bench = SourceBench(pauseAfter: 2, firstPause: .seconds(60))
        _ = bench.failed(1)
        _ = bench.failed(1)

        #expect(bench.isBenched(1))
        #expect(!bench.isBenched(2), "a healthy source was benched with the sick one")
    }

    /// A one-bit cross-thread signal.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }
}

/// What the console says while the cache is working.
///
/// **Completions alone are not enough.** A fetch used to be silent from start
/// to finish, so a provider taking seventy-five seconds and a provider doing
/// nothing at all looked identical — and when the completion arrived it carried
/// no indication of how long it had been waited for. The `caching` line existed
/// for this and has changed producer twice; the queue's fetcher is its producer
/// now.
@Suite("What the cache says while it works")
struct CacheNarrationTests {

    @Test("A fetch announces itself before the wait, with its bound")
    func fetchingIsAnnouncedUpFront() {
        let line = QueueEvent.caching(
            photo: "sunset.heic", source: 4, within: .seconds(60)
        ).line

        #expect(line.hasPrefix("CACHE: fetching sunset.heic"))
        #expect(line.contains("source 4"), "the source has to be on the line, as it is everywhere")
        // The bound is what says when to stop expecting an answer.
        #expect(line.contains("60"))
    }

    @Test("Every line the cache emits names its source the same way")
    func sourceNomenclatureIsUniform() {
        // One vocabulary across the whole diagnostic surface: `source <id>`,
        // which `pgr_ctl sources list` turns into a path. Two names for one
        // thing means translating between a log and a deck by hand.
        let events: [QueueEvent] = [
            .caching(photo: "a.heic", source: 9, within: .seconds(60)),
            .cached(photo: "a.heic", source: 9, bytes: 1024),
            .cacheUnnecessary(photo: "a.heic", source: 9),
            .cacheFailed(photo: "a.heic", source: 9, because: "no"),
            .cacheTimedOut(photo: "a.heic", source: 9, after: .seconds(60)),
        ]
        for event in events {
            #expect(event.line.contains("source 9"), "\(event.line)")
        }
    }
}
