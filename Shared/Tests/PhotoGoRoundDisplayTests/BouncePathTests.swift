import CoreGraphics
import Foundation
import Testing

@testable import PhotoGoRoundDisplay

/// The empty state's path: constant speed, pure reflection, and closed.
///
/// **The closure is the load-bearing property.** One `CAKeyframeAnimation`
/// repeating for ever is only seamless if the trajectory returns exactly to
/// where it began, which is why the velocity comes from a ratio of small
/// integers rather than an arbitrary angle.
@Suite("The bouncing empty state's path")
struct BouncePathTests {

    /// A view and label with room to move, and a ratio that lands in the band.
    private static func plan(
        view: CGSize = CGSize(width: 1000, height: 600),
        label: CGSize = CGSize(width: 200, height: 100),
        speed: CGFloat = 24
    ) -> BouncePath? {
        BouncePath.plan(
            in: view, label: label, speed: speed,
            start: CGPoint(x: 100, y: 50), ratio: (m: 1, n: 2), signs: (x: 1, y: 1))
    }

    @Test("The path closes, so the animation can repeat with no seam")
    func thePathCloses() throws {
        let path = try #require(Self.plan())
        let first = try #require(path.points.first)
        let last = try #require(path.points.last)
        #expect(first == last)
        #expect(path.keyTimes.first == 0)
        #expect(path.keyTimes.last == 1)
    }

    /// **Constant speed, not constant duration.** Every leg is travelled at the
    /// same rate, which is what makes the motion read as one object moving
    /// rather than an animation easing between poses.
    @Test("Every leg is travelled at the requested speed")
    func speedIsConstant() throws {
        let speed: CGFloat = 24
        let path = try #require(Self.plan(speed: speed))
        for index in 1..<path.points.count {
            let from = path.points[index - 1]
            let to = path.points[index]
            let distance = hypot(to.x - from.x, to.y - from.y)
            let seconds = (path.keyTimes[index] - path.keyTimes[index - 1]) * path.duration
            #expect(abs(distance / CGFloat(seconds) - speed) < 0.01)
        }
    }

    /// The label's centre travels in a rectangle inset by half its size, so the
    /// words touch each edge rather than sliding off it.
    @Test("Every point keeps the whole label on screen")
    func nothingLeavesTheView() throws {
        let view = CGSize(width: 1000, height: 600)
        let label = CGSize(width: 200, height: 100)
        let path = try #require(Self.plan(view: view, label: label))
        for point in path.points {
            #expect(point.x >= label.width / 2 - 0.001)
            #expect(point.x <= view.width - label.width / 2 + 0.001)
            #expect(point.y >= label.height / 2 - 0.001)
            #expect(point.y <= view.height - label.height / 2 + 0.001)
        }
    }

    @Test("Times run forward, once")
    func timesAreMonotonic() throws {
        let path = try #require(Self.plan())
        for index in 1..<path.keyTimes.count {
            #expect(path.keyTimes[index] > path.keyTimes[index - 1])
        }
        #expect(path.points.count == path.keyTimes.count)
    }

    /// **Nothing is manufactured in a space too small to move through.** The same
    /// judgement `Pan` makes about a letterbox thinner than its threshold: a
    /// label jittering across a few points looks like a defect, not a drift.
    @Test("With no room to travel there is no path")
    func tooSmallToMove() {
        let path = BouncePath.plan(
            in: CGSize(width: 100, height: 100), label: CGSize(width: 90, height: 90))
        #expect(path == nil)
    }

    @Test("A view with no size at all has no path")
    func zeroSized() {
        #expect(BouncePath.plan(in: .zero, label: .zero) == nil)
    }

    /// **An angle too close to an axis traces the same line for ever.** The ratio
    /// is picked so the slope sits between 30 and 60 degrees, and the view's own
    /// proportions are inside that calculation — a ratio that looks fine on a
    /// square would be near-horizontal on a very wide display.
    @Test("The chosen ratio keeps the angle away from both axes")
    func ratioAvoidsDegenerateAngles() {
        for (width, height) in [(1000.0, 600.0), (2560.0, 1440.0), (600.0, 1000.0), (3840.0, 1080.0)] {
            let (m, n) = BouncePath.chooseRatio(width: width, height: height)
            let slope = (height * Double(n)) / (width * Double(m))
            #expect(slope >= Double(BouncePath.shallowest) - 0.001)
            #expect(slope <= Double(BouncePath.steepest) + 0.001)
        }
    }

    /// Reflection is the whole physics: the component that met the wall changes
    /// sign and nothing else changes.
    @Test("A wall is met when the axis runs out, and not before")
    func timeToWallIsTheDistanceOverTheRate() {
        #expect(BouncePath.timeToWall(from: 10, velocity: 5, low: 0, high: 110) == 20)
        #expect(BouncePath.timeToWall(from: 10, velocity: -5, low: 0, high: 110) == 2)
        #expect(BouncePath.timeToWall(from: 10, velocity: 0, low: 0, high: 110) == .infinity)
    }
}
