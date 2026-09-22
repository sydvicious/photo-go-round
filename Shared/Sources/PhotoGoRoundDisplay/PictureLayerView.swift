#if canImport(AppKit)

import AppKit
import SwiftUI

/// The photograph, in a layer, on black.
///
/// A layer rather than a drawn image because of where this goes next: the pan
/// is a `CABasicAnimation` on this layer's position, and a layer animation runs
/// on the render server, so it stays smooth while this process is busy decoding
/// the next photograph. Per-frame drawing would stutter at exactly the moment
/// somebody would notice.
///
/// **AppKit is why this file is the only conditional one in the library.**
/// `Shuffle` and the geometry beside it compile anywhere; a view does not, and
/// `PLAN.md` has an iOS app and an iOS widget waiting behind Phase 6.
public final class PictureLayerView: NSView {

    /// Where the photograph sits. Its frame is computed rather than left to
    /// `contentsGravity`, because the pan needs the letterbox as a number and a
    /// gravity keeps that to itself.
    private let pictureLayer = CALayer()
    private var photoSize: CGSize = .zero
    private var reported: PixelSize?

    /// The size this view is about to draw at, in pixels, and the display it is
    /// on, whenever either changes.
    ///
    /// **The display arrives as a string rather than an `NSScreen`**, because
    /// `Shuffle` is shared with surfaces that have no AppKit and no window. This
    /// is the only place in the project holding a screen, so it is the place
    /// that turns one into an identifier.
    public var draws: ((PixelSize, String?) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Black rather than a dark grey: on OLED and XDR panels the letterbox
        // is genuinely black, and anything else is visibly not.
        layer?.backgroundColor = NSColor.black.cgColor
        pictureLayer.contentsGravity = .resize
        pictureLayer.magnificationFilter = .trilinear
        pictureLayer.minificationFilter = .trilinear
        layer?.addSublayer(pictureLayer)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    public func show(_ frame: Shuffle.Frame?) {
        guard let frame else { return }
        photoSize = frame.size
        // No implicit animation on the swap: the cross-fade is its own thing
        // and arrives with the pan, and Core Animation's default half-second
        // dissolve is not it.
        withoutAnimation { pictureLayer.contents = frame.image }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        withoutAnimation {
            pictureLayer.frame = AspectFit.rect(of: photoSize, in: bounds.size)
        }
        report()
    }

    /// A backing-scale change is a resolution change even when the view's size
    /// in points has not moved — dragging the window to a display of a
    /// different density is the case.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        report()
    }

    /// What to ask the service for: the view's size in *pixels*, since the
    /// point of the box is that what comes back can be drawn 1:1.
    private func report() {
        let backing = convertToBacking(bounds).size
        guard backing.width >= 1, backing.height >= 1 else { return }
        let pixels = PixelSize(width: Int(backing.width), height: Int(backing.height))
        guard pixels != reported else { return }
        reported = pixels
        draws?(pixels, Self.identifier(of: window?.screen))
    }

    /// `CGDisplayCreateUUIDFromDisplayID`, which survives reboots and cable
    /// swaps where the transient `CGDirectDisplayID` does not — so a monitor is
    /// one consumer rather than a new row every time it wakes.
    ///
    /// Moved here from `Shuffle` in Phase 2. It is the one thing in that loop
    /// that needed AppKit, and it belongs beside the screen rather than beside
    /// the request.
    public static func identifier(of screen: NSScreen?) -> String? {
        guard
            let number = screen?.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// SwiftUI's side of it, which is a wrapper and nothing more.
public struct PictureDisplay: NSViewRepresentable {
    private let frame: Shuffle.Frame?
    private let draws: (PixelSize, String?) -> Void

    public init(frame: Shuffle.Frame?, draws: @escaping (PixelSize, String?) -> Void) {
        self.frame = frame
        self.draws = draws
    }

    public func makeNSView(context: Context) -> PictureLayerView {
        let view = PictureLayerView(frame: .zero)
        view.draws = draws
        view.show(frame)
        return view
    }

    public func updateNSView(_ view: PictureLayerView, context: Context) {
        view.draws = draws
        view.show(frame)
    }
}

#endif
