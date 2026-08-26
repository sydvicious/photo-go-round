import AppKit
import PhotoGoRoundDisplay
import SwiftUI

/// The photograph, in a layer, on black.
///
/// A layer rather than a drawn image because of where this goes next: the pan
/// is a `CABasicAnimation` on this layer's position, and a layer animation runs
/// on the render server, so it stays smooth while this process is busy decoding
/// the next photograph. Per-frame drawing would stutter at exactly the moment
/// somebody would notice.
final class PictureLayerView: NSView {

    /// Where the photograph sits. Its frame is computed rather than left to
    /// `contentsGravity`, because the pan needs the letterbox as a number and a
    /// gravity keeps that to itself.
    private let pictureLayer = CALayer()
    private var photoSize: CGSize = .zero
    private var reported: PixelSize?

    /// The size this view is about to draw at, in pixels, whenever it changes.
    var draws: ((PixelSize, NSScreen?) -> Void)?

    override init(frame frameRect: NSRect) {
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
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    func show(_ frame: Shuffle.Frame?) {
        guard let frame else { return }
        photoSize = frame.size
        // No implicit animation on the swap: the cross-fade is its own thing
        // and arrives with the pan, and Core Animation's default half-second
        // dissolve is not it.
        withoutAnimation { pictureLayer.contents = frame.image }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        withoutAnimation {
            pictureLayer.frame = AspectFit.rect(of: photoSize, in: bounds.size)
        }
        report()
    }

    /// A backing-scale change is a resolution change even when the view's size
    /// in points has not moved — dragging the window to a display of a
    /// different density is the case.
    override func viewDidChangeBackingProperties() {
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
        draws?(pixels, window?.screen)
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// SwiftUI's side of it, which is a wrapper and nothing more.
struct PictureDisplay: NSViewRepresentable {
    let frame: Shuffle.Frame?
    let draws: (PixelSize, NSScreen?) -> Void

    func makeNSView(context: Context) -> PictureLayerView {
        let view = PictureLayerView(frame: .zero)
        view.draws = draws
        view.show(frame)
        return view
    }

    func updateNSView(_ view: PictureLayerView, context: Context) {
        view.draws = draws
        view.show(frame)
    }
}
