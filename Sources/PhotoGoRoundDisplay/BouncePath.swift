import CoreGraphics
import Foundation

/// The path the empty state's words travel: constant speed, reflecting off each
/// edge, the way a breakout brick or a DVD logo does.
///
/// **Geometry only, and closed on purpose.** The motion itself is one
/// `CAKeyframeAnimation` running on the render server — `PLAN.md`'s *The empty
/// state* asks for "a `CAKeyframeAnimation` over an analytically-computed
/// reflecting path" rather than per-bounce chaining, because a saver that
/// stutters is stuttering at the moment somebody is looking straight at it.
///
/// **The trick that makes one animation enough is choosing a velocity whose
/// trajectory closes.** Reflection inside a rectangle is linear motion unfolded
/// onto a torus, so the path repeats exactly when the horizontal and vertical
/// round-trip times are commensurate. Picking the velocity from a ratio of small
/// integers guarantees that, which means the animation can simply repeat for
/// ever with no seam and nothing to schedule.
public struct BouncePath: Sendable, Equatable {

    /// Corners of the trajectory, in order, starting and ending at the same
    /// point. Motion between them is linear, so these are exact rather than
    /// sampled.
    public let points: [CGPoint]
    /// Each point's place in the loop, 0 through 1, for `CAKeyframeAnimation`.
    public let keyTimes: [Double]
    /// One full circuit, after which the path repeats exactly.
    public let duration: TimeInterval

    /// Points per second, so the words move at the same visible rate on a laptop
    /// panel and on a 6K display.
    ///
    /// **Slow on purpose.** The motion is there to keep the pixels from sitting
    /// still, not to be watched — see `FEATURES.md`, *The empty state moves*.
    public static let speed: CGFloat = 24

    /// Below this much room in either axis there is nothing worth traversing,
    /// and the words sit still instead. The same judgement `Pan.threshold`
    /// makes about a letterbox too thin to travel through.
    public static let minimumTravel: CGFloat = 24

    /// **Angles too close to an axis trace the same boring line for ever**, so
    /// the velocity ratio is drawn from a band away from both. Roughly 30° to
    /// 60° and its reflections.
    static let shallowest: CGFloat = 0.577  // tan 30°
    static let steepest: CGFloat = 1.732  // tan 60°

    /// The path for a label of this size inside a view of that size, or `nil`
    /// when there is not enough room to move.
    ///
    /// The explicit parameters exist so a test can pin what is otherwise random;
    /// nothing else passes them.
    public static func plan(
        in view: CGSize,
        label: CGSize,
        speed: CGFloat = BouncePath.speed,
        start: CGPoint? = nil,
        ratio: (m: Int, n: Int)? = nil,
        signs: (x: CGFloat, y: CGFloat)? = nil
    ) -> BouncePath? {
        // The label's *centre* travels in a rectangle inset by half its size, so
        // the words touch each edge rather than leaving it.
        let width = view.width - label.width
        let height = view.height - label.height
        guard width >= minimumTravel, height >= minimumTravel, speed > 0 else { return nil }

        let (m, n) = ratio ?? chooseRatio(width: width, height: height)

        // Horizontal round trip takes `duration / m`, vertical `duration / n`, so
        // both return to their starting phase at `duration` — which is what makes
        // the loop seamless.
        let horizontal = 2 * width * CGFloat(m)
        let vertical = 2 * height * CGFloat(n)
        let duration = TimeInterval(sqrt(horizontal * horizontal + vertical * vertical) / speed)
        guard duration > 0 else { return nil }

        let sign = signs ?? (Bool.random() ? 1 : -1, Bool.random() ? 1 : -1)
        var velocity = CGVector(
            dx: sign.x * horizontal / CGFloat(duration),
            dy: sign.y * vertical / CGFloat(duration))

        let minimum = CGPoint(x: label.width / 2, y: label.height / 2)
        let maximum = CGPoint(x: minimum.x + width, y: minimum.y + height)
        var point =
            start
            ?? CGPoint(
                x: CGFloat.random(in: minimum.x...maximum.x),
                y: CGFloat.random(in: minimum.y...maximum.y))

        var points = [point]
        var times: [Double] = [0]
        var elapsed: TimeInterval = 0

        // At most one reflection per wall per round trip, plus slack for a corner
        // hit resolving as two. A bound rather than `while true`: this runs on the
        // main thread while somebody is waiting to see words.
        let limit = 4 * (m + n) + 8
        while points.count < limit {
            let step = min(
                timeToWall(from: point.x, velocity: velocity.dx, low: minimum.x, high: maximum.x),
                timeToWall(from: point.y, velocity: velocity.dy, low: minimum.y, high: maximum.y))
            guard step.isFinite, step > 0 else { break }

            if elapsed + TimeInterval(step) >= duration {
                // The circuit closes here. The final point is the first one by
                // construction, and is written as such rather than computed, so
                // no accumulated error can leave a visible jump at the seam.
                points.append(points[0])
                times.append(1)
                break
            }

            elapsed += TimeInterval(step)
            point = CGPoint(x: point.x + velocity.dx * step, y: point.y + velocity.dy * step)
            // Reflect whichever wall was reached; a corner reflects both.
            if abs(point.x - minimum.x) < 0.001 || abs(point.x - maximum.x) < 0.001 {
                velocity.dx = -velocity.dx
            }
            if abs(point.y - minimum.y) < 0.001 || abs(point.y - maximum.y) < 0.001 {
                velocity.dy = -velocity.dy
            }
            points.append(point)
            times.append(elapsed / duration)
        }

        guard points.count > 2 else { return nil }
        return BouncePath(points: points, keyTimes: times, duration: duration)
    }

    /// How long until this axis reaches a wall, or infinity when it never does.
    static func timeToWall(
        from position: CGFloat, velocity: CGFloat, low: CGFloat, high: CGFloat
    ) -> CGFloat {
        if velocity > 0 { return (high - position) / velocity }
        if velocity < 0 { return (low - position) / velocity }
        return .infinity
    }

    /// A small integer ratio whose resulting angle is away from both axes.
    ///
    /// The slope is `(height * n) / (width * m)`, so the view's own proportions
    /// are already in it — a ratio that looks fine on a square would trace a
    /// near-horizontal line on a 21:9 display.
    static func chooseRatio(width: CGFloat, height: CGFloat) -> (m: Int, n: Int) {
        var candidates: [(m: Int, n: Int)] = []
        for m in 1...6 {
            for n in 1...6 {
                let slope = (height * CGFloat(n)) / (width * CGFloat(m))
                if slope >= shallowest, slope <= steepest { candidates.append((m, n)) }
            }
        }
        guard let chosen = candidates.randomElement() else {
            // No ratio in the band — a very long, thin view. Take the closest to
            // 45° that exists rather than refusing to move at all.
            var best = (m: 1, n: 1)
            var bestDistance = CGFloat.infinity
            for m in 1...6 {
                for n in 1...6 {
                    let distance = abs((height * CGFloat(n)) / (width * CGFloat(m)) - 1)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = (m, n)
                    }
                }
            }
            return best
        }
        return chosen
    }
}
