import CoreGraphics
import Foundation

/// The slow pan: a fitted photograph sliding back and forth through its own
/// letterbox, rather than sitting still in dead black.
///
/// This is geometry only. The motion itself is a `CABasicAnimation` with
/// `autoreverses` and an ease-in-ease-out curve, because a layer animation runs
/// on the render server and stays smooth while this process is busy decoding the
/// next photograph — which is exactly when a stutter would be noticed.
public struct Pan: Sendable, Equatable {

    /// Which way the photograph travels, which is the axis the black is on.
    public enum Axis: String, Sendable {
        /// Black above and below: the photograph is relatively wider than the
        /// view, so it fits to the width and travels up and down.
        case vertical
        /// Black at the sides: the photograph is relatively taller, so it fits
        /// to the height and travels left and right.
        case horizontal
    }

    public let axis: Axis
    /// The whole distance from one extreme to the other, in points — which is
    /// the letterbox thickness and nothing more. Unlike a fill-and-overflow pan
    /// this is often small: a 3:2 photograph on a 16:10 display has only a few
    /// percent of the screen to move through. That is the point. The motion is
    /// meant to be barely perceptible.
    public let travel: CGFloat
    /// One traverse, at constant speed.
    public let duration: TimeInterval

    /// Points per second, and **constant speed rather than constant duration**.
    /// Deriving speed from travel over a fixed dwell would streak a panorama
    /// across the screen while a nearly-square photograph crept, and the
    /// inconsistency reads as a glitch. At a constant rate some photographs
    /// complete their traverse and reverse and some do not finish; both look
    /// intentional. To be tuned by eye.
    public static let speed: CGFloat = 10

    /// Below this much black there is nothing worth moving through, so the
    /// photograph sits still. Manufacturing motion where none is warranted — a
    /// photograph jittering back and forth across twelve points — looks like a
    /// defect rather than a pan.
    public static let threshold: CGFloat = 24

    /// The pan for this photograph in this view, or `nil` when it should not
    /// move: the ratios match, the black is below the threshold, or there is
    /// nothing to draw.
    public static func plan(
        photo: CGSize,
        in bounds: CGSize,
        speed: CGFloat = Pan.speed,
        threshold: CGFloat = Pan.threshold
    ) -> Pan? {
        guard speed > 0 else { return nil }
        let black = AspectFit.letterbox(of: photo, in: bounds)
        // At most one of the two is non-zero, so this is a choice between a
        // number and a zero rather than a contest.
        let axis: Axis = black.height >= black.width ? .vertical : .horizontal
        let travel = axis == .vertical ? black.height : black.width
        guard travel >= threshold else { return nil }
        return Pan(axis: axis, travel: travel, duration: TimeInterval(travel / speed))
    }
}
