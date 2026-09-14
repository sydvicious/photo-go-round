import Foundation
import OSLog
import Testing

@testable import PhotoGoRoundAgentAPI

/// The agent's record of its errors: one row per kind, most recent first, kept
/// for as long as the trouble lasts, and nothing at all in a process that never
/// starts recording.
///
/// Every reading names its moment, because a row's life is measured from when
/// it was reported and these are reported at a fixed date.
@Suite("The agent's error record")
struct AgentErrorsTests {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test("Nothing is recorded until recording starts")
    func silentUntilStarted() {
        let ledger = AgentErrors()
        ledger.record(kind: "cache.timed-out", "CACHE: a.jpg did not answer in 60s", at: start)
        #expect(ledger.entries(at: start).isEmpty)

        ledger.startRecording()
        ledger.record(kind: "cache.timed-out", "CACHE: a.jpg did not answer in 60s", at: start)
        #expect(ledger.entries(at: start).count == 1)
    }

    /// The reason it is keyed on kind: the photograph on the line changes every
    /// time, and a person wants to see one row that keeps counting.
    @Test("One kind is one row, counted, keeping when it began and the latest words")
    func oneKindOneRow() {
        let ledger = AgentErrors(recording: true)
        ledger.record(kind: "cache.timed-out.source-6", "CACHE: a.jpg did not answer", at: start)
        ledger.record(kind: "cache.timed-out.source-6", "CACHE: b.jpg did not answer", at: at(30))
        ledger.record(kind: "cache.timed-out.source-6", "CACHE: c.jpg did not answer", at: at(80))

        let entries = ledger.entries(at: at(80))
        let entry = entries.first
        #expect(entries.count == 1)
        #expect(entry?.count == 3)
        #expect(entry?.message == "CACHE: c.jpg did not answer")
        #expect(entry?.firstSeen == start)
        #expect(entry?.lastSeen == at(80))
        #expect(entry?.kind == "cache.timed-out.source-6")
        #expect(entry?.standing == false)
    }

    @Test("Without a kind, identical words are one row and different words are another")
    func unclassifiedByText() {
        let ledger = AgentErrors(recording: true)
        ledger.record(kind: nil, "something went wrong", at: start)
        ledger.record(kind: nil, "something went wrong", at: at(1))
        ledger.record(kind: nil, "something else went wrong", at: at(2))

        let entries = ledger.entries(at: at(2))
        #expect(entries.map(\.message) == ["something else went wrong", "something went wrong"])
        #expect(entries.map(\.count) == [1, 2])
        #expect(entries.allSatisfy { $0.kind == nil })
    }

    @Test("The most recently seen comes first, whatever began first")
    func newestFirst() {
        let ledger = AgentErrors(recording: true)
        ledger.record(kind: "a", "first seen, then again last", at: start)
        ledger.record(kind: "b", "seen once in the middle", at: at(10))
        ledger.record(kind: "a", "first seen, then again last", at: at(20))

        #expect(ledger.entries(at: at(20)).compactMap(\.kind) == ["a", "b"])
    }

    @Test("At capacity, the kind seen longest ago makes room for a new one")
    func capacity() {
        let ledger = AgentErrors(capacity: 2, recording: true)
        ledger.record(kind: "old", "seen first", at: start)
        ledger.record(kind: "kept", "seen second", at: at(1))
        ledger.record(kind: "old", "seen first, and again", at: at(2))
        ledger.record(kind: "new", "seen last", at: at(3))

        // `kept` began after `old`, but `old` was seen again since: recency is
        // what decides, not age.
        #expect(Set(ledger.entries(at: at(3)).compactMap(\.kind)) == ["old", "new"])
    }

    @Test("At capacity, an event makes room before a standing condition does")
    func capacityKeepsConditions() {
        let ledger = AgentErrors(capacity: 2, recording: true)
        ledger.record(kind: "standing", "seen first, and still true", lasting: .standing, at: start)
        ledger.record(kind: "event", "seen second", at: at(1))
        ledger.record(kind: "new", "seen last", at: at(2))

        #expect(Set(ledger.entries(at: at(2)).compactMap(\.kind)) == ["standing", "new"])
    }

    @Test("An event leaves the record a minute after it last happened")
    func eventsLeaveAfterAMinute() {
        let ledger = AgentErrors(recording: true)
        ledger.record(kind: "cache.timed-out.source-6", "CACHE: a.jpg did not answer", at: start)
        #expect(ledger.entries(at: at(59)).count == 1)

        // Happening again starts the minute over.
        ledger.record(kind: "cache.timed-out.source-6", "CACHE: b.jpg did not answer", at: at(50))
        #expect(ledger.entries(at: at(109)).count == 1)
        #expect(ledger.entries(at: at(110)).isEmpty)

        // Gone is gone: happening after that is a new row, counted from one.
        ledger.record(kind: "cache.timed-out.source-6", "CACHE: c.jpg did not answer", at: at(200))
        #expect(ledger.entries(at: at(200)).map(\.count) == [1])
        #expect(ledger.entries(at: at(200)).first?.firstSeen == at(200))
    }

    @Test("A standing condition stays until it is cleared")
    func standingStaysUntilCleared() {
        let ledger = AgentErrors(recording: true)
        ledger.record(
            kind: "source.unavailable.source-6", "source 6 unavailable: not mounted",
            lasting: .standing, at: start)

        let entry = ledger.entries(at: at(86_400)).first
        #expect(entry?.standing == true)
        #expect(entry?.until == nil)

        ledger.clear(kind: "source.unavailable.source-6")
        #expect(ledger.entries(at: at(86_400)).isEmpty)
        // Clearing what is not there is nothing.
        ledger.clear(kind: "source.unavailable.source-6")
    }

    @Test("A condition with an end leaves when it ends, and a later report moves the end")
    func standingUntil() {
        let ledger = AgentErrors(recording: true)
        ledger.record(
            kind: "source.paused.source-6", "paused for 2 minutes",
            lasting: .standingUntil(at(120)), at: start)
        #expect(ledger.entries(at: at(119)).first?.until == at(120))

        ledger.record(
            kind: "source.paused.source-6", "paused for 4 minutes",
            lasting: .standingUntil(at(360)), at: at(119))
        #expect(ledger.entries(at: at(300)).map(\.message) == ["paused for 4 minutes"])
        #expect(ledger.entries(at: at(360)).isEmpty)
    }

    @Test("A removed source's standing conditions clear together, and nothing else does")
    func clearStandingForOneSource() {
        let ledger = AgentErrors(recording: true)
        ledger.record(kind: "source.unavailable.source-6", "6 unavailable", lasting: .standing, at: start)
        ledger.record(kind: "source.paused.source-6", "6 paused", lasting: .standingUntil(at(60)), at: start)
        // The same digits, a different source.
        ledger.record(kind: "source.empty.source-60", "60 empty", lasting: .standing, at: start)
        // An event about the source, left to leave on its own.
        ledger.record(kind: "cache.timed-out.source-6", "a timeout", at: start)

        ledger.clearStanding(source: 6)

        #expect(
            Set(ledger.entries(at: start).compactMap(\.kind))
                == ["source.empty.source-60", "cache.timed-out.source-6"])
    }

    @Test("An error logged with a kind is recorded, and one logged without is not")
    func loggerRecords() {
        let ledger = AgentErrors(recording: true)
        let logger = Logger(subsystem: Log.subsystem, category: "tests")

        logger.error(kind: "tests.recorded", "this one is kept", into: ledger)
        logger.error(kind: nil, "this one is only logged", into: ledger)

        #expect(ledger.entries.map(\.message) == ["this one is kept"])
    }

    @Test("A kind about a source names the source, and one about nothing does not")
    func sourceKinds() {
        #expect(AgentErrors.kind("cache.timed-out", source: 6) == "cache.timed-out.source-6")
        #expect(AgentErrors.kind("cache.timed-out", source: nil) == "cache.timed-out")
    }
}
