import Console
import Foundation
import Testing

@testable import PhotosGoRoundAgentAPI
@testable import PhotosGoRoundKit
@testable import photogoroundd

/// How the agent's red lines reach its error record: under a kind, by their
/// words, or not at all when something beside them already records the event.
@Suite("Recording the agent's red lines", .serialized)
struct ErrorRecordingTests {

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(text: String, kind: String?)] = []

        func record(_ text: String, _ kind: String?) {
            lock.lock()
            entries.append((text, kind))
            lock.unlock()
        }

        /// Only what this test said: anything else running prints red lines too.
        func about(_ marker: String) -> [(text: String, kind: String?)] {
            lock.lock()
            defer { lock.unlock() }
            return entries.filter { $0.text.contains(marker) }
        }
    }

    @Test("An alert is recorded under its kind, by its words, or not at all")
    func alertRecording() {
        let heard = Heard()
        let marker = UUID().uuidString
        Console.recordAlerts { heard.record($0, $1) }
        defer { Console.recordAlerts(to: nil) }

        Console.alert("kinded \(marker)", recording: .kind("tests.kinded"))
        Console.alert("by text \(marker)")
        Console.alert("unrecorded \(marker)", recording: .unrecorded)

        let recorded = heard.about(marker)
        #expect(recorded.map(\.text) == ["kinded \(marker)", "by text \(marker)"])
        #expect(recorded.map(\.kind) == ["tests.kinded", nil])
    }

    /// The error logged where the failure happened is what records it; this
    /// line carries a latency and would be a new row every time.
    @Test("A failed request's red line is left to the error logged beside it")
    func failedRequestIsNotRecordedTwice() {
        let heard = Heard()
        let marker = UUID().uuidString
        Console.recordAlerts { heard.record($0, $1) }
        defer { Console.recordAlerts(to: nil) }

        PictureEndpoint.Served(
            status: 503, detail: "library unavailable \(marker)", consumer: "app",
            bytes: 0, milliseconds: 1
        ).report()

        #expect(heard.about(marker).isEmpty)
    }

    @Test("Red queue lines are filed by the kind of event and its source")
    func queueEventKinds() {
        #expect(
            RunCommand.recording(for: .cacheTimedOut(photo: "a.jpg", source: 6, after: .seconds(60)))
                == .kind("cache.timed-out.source-6"))
        #expect(
            RunCommand.recording(
                for: .dropped(photo: "a.jpg", source: 6, because: "gone", queued: 17))
                == .kind("library.photo-dropped.source-6"))
        #expect(
            RunCommand.recording(for: .sourcePaused(source: 6, until: .seconds(120)))
                == .kind("source.paused.source-6"))
        #expect(
            RunCommand.recording(for: .cacheFailed(photo: "a.jpg", source: 6, because: "no"))
                == .kind("cache.fetch-failed.source-6"))
        #expect(
            RunCommand.recording(for: .configurationChanged(what: "preferences re-read"))
                == .byText)
    }

    // MARK: - How long a row lasts

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A paused source stands until its pause ends, and a timeout is an event")
    func pausedStandsUntilItEnds() async {
        let ledger = AgentErrors(recording: true)
        RunCommand.record(.sourcePaused(source: 6, until: .seconds(120)), into: ledger, at: start)
        RunCommand.record(
            .cacheTimedOut(photo: "a.jpg", source: 6, after: .seconds(60)), into: ledger, at: start)

        let later = await ledger.settled(at: start.addingTimeInterval(119))
        #expect(later.compactMap(\.kind) == ["source.paused.source-6"])
        #expect(later.first?.standing == true)
        #expect(later.first?.until == start.addingTimeInterval(120))
        #expect(await ledger.settled(at: start.addingTimeInterval(120)).isEmpty)
    }

    @Test("A failed fetch is recorded under its source, in the words the fetch gave")
    func fetchFailureIsRecorded() async throws {
        let ledger = AgentErrors(recording: true)
        let card = DeckCard(
            id: 7, uuid: "u", sourceID: 9, sourceUUID: "s", externalID: "C3D4/L0/001",
            storage: .materialized, dealSeq: 12, originalFilename: "IMG_0042.HEIC")

        RunCommand.recordFetchFailure(card, because: "its source is disabled", into: ledger, at: start)
        RunCommand.recordFetchFailure(
            card, because: "the network connection was lost", into: ledger,
            at: start.addingTimeInterval(1))

        let entries = await ledger.settled(at: start.addingTimeInterval(1))
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.kind == "cache.fetch-failed.source-9")
        #expect(entry.count == 2)
        #expect(
            entry.message
                == QueueEvent.cacheFailed(
                    photo: card.spokenName, source: 9, because: "the network connection was lost"
                ).line)
        #expect(entry.message.contains("IMG_0042.HEIC"))
        #expect(!entry.standing)
    }

    private func scan(unchanged: Int = 0, unavailable: Bool = false) -> ScanResult {
        ScanResult(
            sourceID: 13, added: 0, removed: 0, unchanged: unchanged,
            sourceUnavailable: unavailable, reason: unavailable ? "not mounted" : nil,
            bytesFreed: 0)
    }

    /// Recorded on every refresh rather than on the transition, so a source that
    /// was already unavailable when the agent launched still appears.
    @Test("An unavailable source stands on every refresh that finds it so, and clears when one does not")
    func unavailableStands() async {
        let ledger = AgentErrors(recording: true)
        let reporter = Reporter(errors: ledger)

        reporter.finish(scan(unavailable: true), wasAvailable: false)
        reporter.finish(scan(unavailable: true), wasAvailable: false)
        let entries = await ledger.settled
        #expect(entries.compactMap(\.kind) == ["source.unavailable.source-13"])
        #expect(entries.first?.standing == true)
        #expect(entries.first?.count == 2)

        reporter.finish(scan(unchanged: 4), wasAvailable: false)
        #expect(await ledger.settled.isEmpty)
    }

    /// Disabled by `pgr_ctl`, which reconciles in its own process, so the agent
    /// never sees the change happen — only a source it no longer refreshes.
    @Test("A refresh pass clears the standing conditions of the sources it skips as disabled")
    func disabledSourcesAreCleared() async {
        let ledger = AgentErrors(recording: true)
        let reporter = Reporter(errors: ledger)
        reporter.finish(scan(unavailable: true), wasAvailable: true)
        ledger.record(kind: "source.empty.source-14", "source 14 is empty", lasting: .standing)

        let disabled = Source(
            id: 13, uuid: "s", kind: .folder, locator: "/Volumes/NotMounted/photos",
            description: nil, addedAt: Date(timeIntervalSince1970: 0))
        reporter.skipped([disabled])

        #expect(await ledger.settled.compactMap(\.kind) == ["source.empty.source-14"])
    }

    @Test("An empty source stands until a scan finds photographs, or cannot look")
    func emptyStands() async {
        let ledger = AgentErrors(recording: true)
        let reporter = Reporter(errors: ledger)

        reporter.finish(scan(), wasAvailable: true)
        #expect(await ledger.settled.compactMap(\.kind) == ["source.empty.source-13"])
        #expect(await ledger.settled.first?.standing == true)

        reporter.finish(scan(unchanged: 1), wasAvailable: true)
        #expect(await ledger.settled.isEmpty)

        reporter.finish(scan(), wasAvailable: true)
        reporter.finish(scan(unavailable: true), wasAvailable: true)
        #expect(await ledger.settled.compactMap(\.kind) == ["source.unavailable.source-13"])
    }
}
