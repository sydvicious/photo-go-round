import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI

/// A session's own timeouts have to sit above the deadline its client applies,
/// or the transport fires first and reports a silence in its own words.
///
/// **The bug this holds shut, 2026-09-21.** Adding 26 albums from a freshly
/// installed Release agent failed with "The request timed out": the agent sends
/// nothing until it has done the work, and the session's 15-second gap between
/// packets fired inside the panel's 30-second write limit. The agent went on to
/// add all 26. The panel's read limit, 20 seconds, and its consent limit, 120 —
/// past the session's 60-second whole-answer bound too — had the same flaw.
@Suite("An agent session outlasts the deadline around it")
struct AgentSessionTests {

    @Test(
        "Both of the session's timeouts sit above the limit it is made for",
        arguments: [Duration.seconds(5), .seconds(20), .seconds(30), .seconds(120)])
    func timeoutsExceedTheLimit(_ limit: Duration) {
        let configuration = AgentSession.make(above: limit).configuration
        #expect(configuration.timeoutIntervalForRequest > limit.totalSeconds)
        #expect(configuration.timeoutIntervalForResource > limit.totalSeconds)
    }

    /// The pictures' own session, which the default is for: a five-second
    /// read, well inside both.
    @Test("The default session outlasts a picture read")
    func defaultOutlastsAPicture() {
        let configuration = AgentSession.make().configuration
        #expect(configuration.timeoutIntervalForRequest > ServiceTiming.pictureReadLimit.totalSeconds)
        #expect(configuration.timeoutIntervalForResource > ServiceTiming.pictureReadLimit.totalSeconds)
    }
}
