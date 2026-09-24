import Foundation
import Testing

@testable import PhotosGoRoundKit
@testable import PhotosGoRoundServer

/// When a source that went unanswered is asked again.
///
/// Every test supplies its own `now`, so the backoff is covered without
/// waiting for any of it.
@Suite("Retries")
struct RetriesTests {

    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private let scan = Duration.seconds(300)

    private func unanswered(_ id: Int64) -> ScanResult {
        ScanResult(
            sourceID: id, added: 0, removed: 0, unchanged: 0,
            sourceUnavailable: true, reason: "Photos is not responding.", unanswered: true)
    }

    private func answered(_ id: Int64) -> ScanResult {
        ScanResult(
            sourceID: id, added: 0, removed: 0, unchanged: 8552,
            sourceUnavailable: false, reason: nil)
    }

    @Test("The wait doubles from thirty seconds")
    func theBackoff() {
        #expect(Retries.delay(afterFailures: 1) == .seconds(30))
        #expect(Retries.delay(afterFailures: 2) == .seconds(60))
        #expect(Retries.delay(afterFailures: 3) == .seconds(120))
        #expect(Retries.delay(afterFailures: 4) == .seconds(240))
    }

    /// **The boot, stated as a property.** Unanswered at launch, asked again
    /// thirty seconds later rather than five minutes.
    @Test("An unanswered source is due again after thirty seconds, not a scan")
    func dueAfterThirtySeconds() async {
        let retries = Retries()
        await retries.heard(unanswered(1), at: epoch)

        #expect(await retries.take(at: epoch.addingTimeInterval(29), ceiling: scan).isEmpty)
        #expect(await retries.take(at: epoch.addingTimeInterval(30), ceiling: scan) == [1])
    }

    /// Handed out once per walk, or every tick would start another while the
    /// first was still running.
    @Test("A retry in flight is not handed out again")
    func inFlightIsNotRepeated() async {
        let retries = Retries()
        await retries.heard(unanswered(1), at: epoch)

        #expect(await retries.take(at: epoch.addingTimeInterval(30), ceiling: scan) == [1])
        #expect(await retries.take(at: epoch.addingTimeInterval(31), ceiling: scan).isEmpty)
        #expect(await retries.take(at: epoch.addingTimeInterval(600), ceiling: scan).isEmpty)
    }

    @Test("Silent again, the next wait is twice as long")
    func silentAgainWaitsLonger() async {
        let retries = Retries()
        await retries.heard(unanswered(1), at: epoch)
        _ = await retries.take(at: epoch.addingTimeInterval(30), ceiling: scan)
        let again = epoch.addingTimeInterval(40)
        await retries.heard(unanswered(1), at: again)

        #expect(await retries.take(at: again.addingTimeInterval(59), ceiling: scan).isEmpty)
        #expect(await retries.take(at: again.addingTimeInterval(60), ceiling: scan) == [1])
    }

    @Test("An answer forgets the source")
    func anAnswerClears() async {
        let retries = Retries()
        await retries.heard(unanswered(1), at: epoch)
        await retries.heard(answered(1), at: epoch.addingTimeInterval(5))

        #expect(await retries.isEmpty)
        #expect(await retries.take(at: epoch.addingTimeInterval(60), ceiling: scan).isEmpty)
    }

    /// An unplugged drive is unavailable too, and is not coming back in
    /// thirty seconds.
    @Test("A source that answered no is not retried early")
    func unavailableIsNotRetried() async {
        let retries = Retries()
        await retries.heard(
            ScanResult(
                sourceID: 7, added: 0, removed: 0, unchanged: 0,
                sourceUnavailable: true, reason: "the volume is not mounted"),
            at: epoch)

        #expect(await retries.isEmpty)
    }

    /// Once the wait would be as long as the scan, the scan gets there as soon.
    @Test("A source that stays silent is left to the scan")
    func theCeilingEndsIt() async {
        let retries = Retries()
        var now = epoch
        for _ in 1...4 {
            await retries.heard(unanswered(1), at: now)
            now = now.addingTimeInterval(1000)
            #expect(await retries.take(at: now, ceiling: scan) == [1])
        }
        // A fifth failure: the next wait would be 480 s, past the 300 s scan.
        await retries.heard(unanswered(1), at: now)
        #expect(await retries.take(at: now.addingTimeInterval(1000), ceiling: scan).isEmpty)
        #expect(await retries.isEmpty)
    }
}
