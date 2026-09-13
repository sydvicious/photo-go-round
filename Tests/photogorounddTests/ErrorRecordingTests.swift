import Console
import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit
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
            RunCommand.recording(for: .configurationChanged(what: "preferences re-read"))
                == .byText)
    }
}
