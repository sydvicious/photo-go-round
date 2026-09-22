import Console
import Foundation
import Synchronization
import Testing

/// What the console mirror carried.
///
/// Process-global because `Console` is, and installed on first use rather than
/// in a setup hook, since Swift Testing has none. Assert with `contains`: these
/// suites run in parallel, so every other test's console output lands here too.
enum Mirrored {
    private static let said = Mutex<[(text: String, level: Console.Level)]>([])
    private static let ready = Atomic(false)

    /// **A call rather than a `Void` `static let`.** The lazy-global pattern
    /// reads a value of type `Void`, and reading one is trivially removable — so
    /// whether the side effect happens at all is a question about the optimiser
    /// rather than about this code. An explicit call has no such question.
    static func install() {
        guard !ready.exchange(true, ordering: .acquiringAndReleasing) else { return }
        Console.mirror { text, level in said.withLock { $0.append((text, level)) } }
    }

    static var all: [(text: String, level: Console.Level)] { said.withLock { $0 } }

    /// The level a line was mirrored at, or nil if it was not mirrored at all.
    static func level(of text: String) -> Console.Level? {
        all.first { $0.text == text }?.level
    }
}

/// **Every kind of console line reaches the unified log.**
///
/// Under launchd the agent's standard output goes nowhere, so a `Console` call
/// that the mirror does not carry is a line that is lost. This is what catches
/// a new call kind being added without one. `Plans/Logging.md`, Phase 1.
@Suite("The console mirror")
struct ConsoleMirrorTests {

    /// Unique per assertion, because the suites run in parallel and the agent's
    /// own lines are in the same collection.
    private func marker(_ what: String) -> String {
        "console-mirror-test \(what) \(UUID().uuidString)"
    }

    @Test("Every kind of line is mirrored, and at the level its colour implies")
    func everyKindIsMirrored() {
        Mirrored.install()

        let banner = marker("banner")
        let note = marker("note")
        let event = marker("event")
        let change = marker("change")
        let recovered = marker("recovered")
        let summary = marker("summary")
        let alert = marker("alert")
        let failure = marker("failure")

        Console.banner(banner)
        Console.note(note)
        Console.event(event)
        Console.change("▸", change, .yellow)
        Console.recovered(recovered)
        Console.summary(summary)
        Console.alert(alert, recording: .unrecorded)
        Console.failure(failure)

        #expect(Mirrored.level(of: banner) == .notice)
        #expect(Mirrored.level(of: note) == .notice)
        #expect(Mirrored.level(of: event) == .notice)
        #expect(Mirrored.level(of: recovered) == .notice)
        #expect(Mirrored.level(of: summary) == .notice)
        #expect(Mirrored.level(of: alert) == .error)
        #expect(Mirrored.level(of: failure) == .error)
    }

    /// The mark is the whole identity of the line `Documentation/Installing.md`
    /// tells a person to search for, so it has to survive the crossing.
    @Test("A change keeps its mark and its suffix")
    func changeKeepsItsMark() {
        Mirrored.install()
        let name = marker("served")
        Console.change("▸", name, .yellow, suffix: "consumer=screensaver")

        let line = Mirrored.all.first { $0.text.contains(name) }
        #expect(line?.text == "▸ \(name)  consumer=screensaver")
        #expect(line?.level == .notice)
    }

    /// A banner is one fact laid out over several lines for a terminal's sake.
    @Test("A banner crosses as one line")
    func bannerIsOneLine() {
        Mirrored.install()
        let name = marker("multiline")
        Console.banner("\(name)\nsecond line")

        let line = Mirrored.all.first { $0.text.contains(name) }
        #expect(line?.text == "\(name) · second line")
    }

    /// **The queue's own lines are the one set the mirror must not carry.**
    /// `QueueEvent.report` logs them at a level chosen per case; mirroring them
    /// as well would log each twice, and the second copy at the wrong level.
    @Test("A line marked not-mirrored does not cross")
    func optingOutSuppressesTheLine() {
        Mirrored.install()
        let quietEvent = marker("quiet event")
        let quietAlert = marker("quiet alert")

        Console.event(quietEvent, mirrored: false)
        Console.alert(quietAlert, recording: .unrecorded, mirrored: false)

        #expect(Mirrored.level(of: quietEvent) == nil)
        #expect(Mirrored.level(of: quietAlert) == nil)
    }

    /// **The served `▸` line is terminal-only.** `PictureEndpoint` logs the same
    /// request as `served status=…`; mirroring this one as well put the same
    /// picture in the log twice. `Plans/Logging.md`, Phase 5.
    @Test("A change marked not-mirrored does not cross")
    func aQuietChangeDoesNotCross() {
        Mirrored.install()
        let name = marker("quiet served")
        Console.change("▸", name, .yellow, suffix: "consumer=app", mirrored: false)

        #expect(Mirrored.all.first { $0.text.contains(name) } == nil)
    }
}
