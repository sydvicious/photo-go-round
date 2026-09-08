import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// **What counts as a source that has stopped answering.**
///
/// The bench exists to stop spending fetch lanes on a source that is producing
/// nothing, and for most of its life it could not do that for the one source
/// that needed it most: a Photos album that is half downloaded. Some of its
/// photographs are on the disk and answer in milliseconds; the rest are in
/// iCloud and, with no network, answer never. Every local one that succeeded
/// wiped the account of every remote one that had failed.
///
/// Measured on 2026-09-07 against Favorites: 689 successful fetches, 66
/// timeouts, and four benches in four hours — where the runs of failures were
/// long enough to have earned sixteen.
@Suite("Leaving a source alone when it stops answering")
struct SourceBenchTests {

    @Test("A run of failures is not wiped by the successes between them")
    func successesDoNotWipeTheAccount() {
        let bench = SourceBench(pauseAfter: 4)

        // The shape a half-downloaded album makes while the network is off:
        // mostly failures, with a local photograph answering now and again.
        // Three failures, one success, and the account stands at two.
        for _ in 0..<3 { #expect(bench.failed(1) == nil) }
        bench.succeeded(1)
        #expect(bench.failed(1) == nil, "the fourth failure benched a source at two")

        // Which the next one tips over.
        #expect(bench.failed(1) != nil, "a success wiped three failures instead of one")
    }

    @Test("A source that mostly answers is never benched")
    func healthySourcesAreLeftAlone() {
        let bench = SourceBench(pauseAfter: 4)

        // Ninety per cent healthy, which is what Favorites measured at. An
        // occasional timeout on a working source is weather, and the bucket
        // drains faster than it fills.
        for _ in 0..<50 {
            #expect(bench.failed(1) == nil)
            for _ in 0..<9 { bench.succeeded(1) }
        }
        #expect(bench.isBenched(1) == false)
    }

    @Test("Nothing but failures benches at the threshold, and the account starts again")
    func failuresAloneBench() {
        let bench = SourceBench(pauseAfter: 4, firstPause: .seconds(60))
        for _ in 0..<3 { #expect(bench.failed(2) == nil) }
        #expect(bench.failed(2) == .seconds(60))
        #expect(bench.isBenched(2))

        // The count is reset by the bench itself, so the next one is earned
        // afresh rather than on the next failure.
        #expect(bench.failed(2) == nil)
    }

    @Test("The account cannot go negative, so a quiet source does not bank credit")
    func successesDoNotBankCredit() {
        let bench = SourceBench(pauseAfter: 4)

        // A thousand successes must not buy a thousand free failures — the
        // source that has been fine all day is exactly the one whose going
        // wrong should be noticed promptly.
        for _ in 0..<1000 { bench.succeeded(3) }
        for _ in 0..<3 { #expect(bench.failed(3) == nil) }
        #expect(bench.failed(3) != nil, "banked successes swallowed a real run of failures")
    }
}
