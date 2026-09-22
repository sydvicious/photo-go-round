import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI

/// The two numbers a minute of samples is reduced to.
///
/// Syd, 2026-09-18: "if stage 7 is supposed to solve this… you should be the
/// probe so you can prove it does when we think we are done."
/// `Plans/Agent Performance Overhaul.md`, Phase 7.
@Suite("How long a task waits to start")
struct PoolWaitTests {

    @Test("A window carries the median and the worst")
    func summaryIsMedianAndWorst() throws {
        let waits: [Duration] = [
            .milliseconds(1), .milliseconds(2), .milliseconds(3), .milliseconds(4),
            .milliseconds(900),
        ]

        let window = try #require(PoolWait.summarise(waits))

        #expect(window.samples == 5)
        #expect(window.typical == .milliseconds(3))
        #expect(window.worst == .milliseconds(900))
    }

    /// **The worst is the point.** A median of two milliseconds with a worst of
    /// two seconds is the shape that breaks a one-second deadline, and an
    /// average would hide it completely.
    @Test("One long wait among many short ones survives the summary")
    func theSpikeIsNotAveragedAway() throws {
        var waits = [Duration](repeating: .milliseconds(1), count: 59)
        waits.append(.seconds(2))

        let window = try #require(PoolWait.summarise(waits))

        #expect(window.typical == .milliseconds(1))
        #expect(window.worst == .seconds(2))
    }

    @Test("Samples arrive in any order and the summary does not care")
    func orderDoesNotMatter() throws {
        let ordered = try #require(PoolWait.summarise([.milliseconds(1), .milliseconds(50)]))
        let jumbled = try #require(PoolWait.summarise([.milliseconds(50), .milliseconds(1)]))

        #expect(ordered == jumbled)
    }

    /// A line saying nothing happened is worse than no line.
    @Test("An empty window says nothing at all")
    func nothingIsNotReported() {
        #expect(PoolWait.summarise([]) == nil)
    }

    @Test("The line reads as the other diagnostics do")
    func theLineReads() {
        let window = PoolWait.Window(
            samples: 60, typical: .milliseconds(2), worst: .milliseconds(1842))

        let line = PoolWait.line(window)

        #expect(line == "POOL: waited 2ms typical · 1842ms worst · 60 samples")
    }

    @Test("A sample every second, reported every minute")
    func theCadenceIsWhatWasAsked() {
        #expect(PoolWait.sample == .seconds(1))
        #expect(PoolWait.report == .seconds(60))
    }
}
