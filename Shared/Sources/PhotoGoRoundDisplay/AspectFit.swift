import CoreGraphics

/// Sizing a photograph to a view: shrink or expand, aspect ratio preserved.
///
/// The whole photograph is always visible and nothing is ever cropped. Where the
/// two ratios differ there is black, and that black is what the pan slides
/// through.
///
/// **This is not the same fit the service does, and the difference is
/// deliberate.** `PhotoRenderer` never enlarges: a box larger than the original
/// comes back at the original's pixels. A view has no such option — it has a
/// size it must fill — so a small photograph is drawn larger than its pixels and
/// looks soft. *Screensaver v1* states that plainly and expands anyway; an
/// upscale cap belongs with the other display options rather than here.
public enum AspectFit {

    /// The size the photograph is drawn at inside `bounds`.
    public static func size(of photo: CGSize, in bounds: CGSize) -> CGSize {
        guard photo.width > 0, photo.height > 0, bounds.width > 0, bounds.height > 0
        else { return .zero }
        let scale = min(bounds.width / photo.width, bounds.height / photo.height)
        return CGSize(width: photo.width * scale, height: photo.height * scale)
    }

    /// The same, centred — which is where a fitted photograph sits when nothing
    /// is panning it.
    public static func rect(of photo: CGSize, in bounds: CGSize) -> CGRect {
        let fitted = size(of: photo, in: bounds)
        return CGRect(
            x: (bounds.width - fitted.width) / 2,
            y: (bounds.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// How much black there is, on each axis. Exactly one of these is non-zero
    /// for any photograph whose ratio differs from the view's, and both are zero
    /// when the ratios match.
    public static func letterbox(of photo: CGSize, in bounds: CGSize) -> CGSize {
        let fitted = size(of: photo, in: bounds)
        guard fitted != .zero else { return .zero }
        return CGSize(
            width: max(0, bounds.width - fitted.width),
            height: max(0, bounds.height - fitted.height)
        )
    }
}
