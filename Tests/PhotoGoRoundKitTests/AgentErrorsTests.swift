import Foundation
import OSLog
import Testing

@testable import PhotoGoRoundAgentAPI

/// The agent's record of its errors: one row per kind, most recent first, and
/// nothing at all in a process that never starts recording.
@Suite("The agent's error record")
struct AgentErrorsTests {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Nothing is recorded until recording starts")
    func silentUntilStarted() {
        let ledger = AgentErrors()
        ledger.record(kind: "cache.timed-out", "CACHE: a.jpg did not answer in 60s", at: start)
        #expect(ledger.entries.isEmpty)

        ledger.startRecording()
        ledger.record(kind: "cache.timed-out", "CACHE: a.jpg did not answer in 60s", at: start)
        #expect(ledger.entries.count == 1)
    }

    /// The reason it is keyed on kind: the photograph on the line changes every
    /// time, and a person wants to see one row that keeps counting.
    @Test("One kind is one row, counted, keeping when it began and the latest words")
    func oneKindOneRow() {
        let ledger = AgentErrors(recording: true)
        ledger.record(kind: "cache.timed-out.source-6", "CACHE: a.jpg did not answer", at: start)
        ledger.record(
            kind: "cache.timed-out.source-6", "CACHE: b.jpg did not answer",
            at: start.addingTimeInterval(30))
        ledger.record(
            kind: "cache.timed-out.source-6", "CACHE: c.jpg did not answer",
            at: start.addingTimeInterval(90))

        let entry = try? #require(ledger.entries.first)
        #expect(ledger.entries.count == 1)
        #expect(entry?.count == 3)
        #expect(entry?.message == "CACHE: c.jpg did not answer")
        #expect(entry?.firstSeen == start)
        #expect(entry?.lastSeen == start.addingTimeInterval(90))
        #expect(entry?.kind == "cache.timed-out.source-6")
    }

    @Test("Without a kind, identical words are one row and different words are another")
    func unclassifiedByText() {
        let ledger = AgentErrors(recording: true)
        ledger.record(kind: nil, "something went wrong", at: start)
        ledger.record(kind: nil, "something went wrong", at: start.addingTimeInterval(1))
        ledger.record(kind: nil, "something else went wrong", at: start.addingTimeInterval(2))

        #expect(ledger.entries.map(\.message) == ["something else went wrong", "something went wrong"])
        #expect(ledger.entries.map(\.count) == [1, 2])
        #expect(ledger.entries.allSatisfy { $0.kind == nil })
    }

    @Test("The most recently seen comes first, whatever began first")
    func newestFirst() {
        let ledger = AgentErrors(recording: true)
        ledger.record(kind: "a", "first seen, then again last", at: start)
        ledger.record(kind: "b", "seen once in the middle", at: start.addingTimeInterval(10))
        ledger.record(kind: "a", "first seen, then again last", at: start.addingTimeInterval(20))

        #expect(ledger.entries.compactMap(\.kind) == ["a", "b"])
    }

    @Test("At capacity, the kind seen longest ago makes room for a new one")
    func capacity() {
        let ledger = AgentErrors(capacity: 2, recording: true)
        ledger.record(kind: "old", "seen first", at: start)
        ledger.record(kind: "kept", "seen second", at: start.addingTimeInterval(1))
        ledger.record(kind: "old", "seen first, and again", at: start.addingTimeInterval(2))
        ledger.record(kind: "new", "seen last", at: start.addingTimeInterval(3))

        // `kept` began after `old`, but `old` was seen again since: recency is
        // what decides, not age.
        #expect(Set(ledger.entries.compactMap(\.kind)) == ["old", "new"])
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
