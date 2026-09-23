import Foundation
import Testing

@testable import PhotosGoRoundKit

/// The steps of one request, as the `TIMING:` line reports them.
@Suite("Timing a request's steps")
struct StageTimesTests {

    @Test("Each lap is charged the time since the one before")
    func lapsAreCharged() {
        let start = ContinuousClock.now
        var stages = StageTimes(from: start)
        stages.lap("open", now: start + .milliseconds(2))
        stages.lap("check", now: start + .milliseconds(1002))

        #expect(stages.stages.map(\.name) == ["open", "check"])
        #expect(stages.stages.map(\.took) == [.milliseconds(2), .seconds(1)])
    }

    /// A request that walks past a card meets `queue` and `check` again. The
    /// line has one field per step, so a second visit adds to the first rather
    /// than appearing twice.
    @Test("A step met twice is one entry, in the place it was first met")
    func repeatedStepsAccumulate() {
        let start = ContinuousClock.now
        var stages = StageTimes(from: start)
        stages.lap("queue", now: start + .milliseconds(1))
        stages.lap("check", now: start + .milliseconds(11))
        stages.lap("queue", now: start + .milliseconds(12))
        stages.lap("check", now: start + .milliseconds(32))

        #expect(stages.stages.map(\.name) == ["queue", "check"])
        #expect(stages.stages.map(\.took) == [.milliseconds(2), .milliseconds(30)])
    }

    @Test("The summary is one field per step, in whole milliseconds")
    func summary() {
        let start = ContinuousClock.now
        var stages = StageTimes(from: start)
        stages.lap("waited", now: start + .microseconds(400))
        stages.lap("render", now: start + .microseconds(109_900))

        #expect(stages.summary == "waited 0ms · render 109ms")
    }
}
