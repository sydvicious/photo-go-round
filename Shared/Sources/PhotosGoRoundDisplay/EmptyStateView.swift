#if canImport(AppKit)

import AppKit
import SwiftUI

/// The words that appear when there has never been a photograph, drifting around
/// the view and reflecting off its edges.
///
/// **Shared by the window and the screensaver, which settles an argument.**
/// `MacOS/Desktop/FEATURES.md` listed *The empty state moves* as the app's to build
/// "so Phase 6 inherits it"; `Shuffle` parked the bouncing letters as "Phase 6's
/// treatment". Each pointed at the other and neither built it. It is one view in
/// the display library now, and both surfaces mount it.
///
/// **It moves for a reason beyond being fun.** A static label on the OLED and XDR
/// panels this runs on all night is a genuine burn-in hazard, and a screensaver
/// showing a motionless word is indistinguishable from one that has crashed. See
/// `PLAN.md`, *The empty state*.
public final class EmptyStateView: NSView {

    private let words = CATextLayer()
    /// What the animation moves, with the words inside it.
    private let group = CALayer()

    private var currentWords: String?
    private var laidOutFor: CGSize = .zero

    private static let animationKey = "bounce"

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(group)
        words.foregroundColor = NSColor.white.cgColor
        words.alignmentMode = .center
        words.truncationMode = .none
        words.isWrapped = false
        group.addSublayer(words)
        group.isHidden = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    /// The words, or `nil` — which hides them and stops the animation.
    ///
    /// **One line only.** There was a second, smaller one underneath until
    /// 2026-09-26, when Syd asked for "No secondary lines of text."
    ///
    /// **New words are laid out again even at the same size.** `layout()` skips
    /// a pass at the size it last laid out for, so the bounce is not restarted
    /// on every pass — and until 2026-09-26 that skip also kept new words off
    /// the screen. Syd's window said *Waiting for Photos* for as long as it was
    /// open after the agent had answered *no sources*: the words had changed,
    /// the window had not, and nothing was drawn.
    public func show(words newWords: String?) {
        guard newWords != currentWords else { return }
        currentWords = newWords
        laidOutFor = .zero
        needsLayout = true
    }

    /// What the text layer is drawing, which is what a test has to read: the
    /// words asked for and the words drawn came apart once.
    var drawnWords: String? { words.string as? String }

    public override var isFlipped: Bool { false }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        words.contentsScale = scale
        laidOutFor = .zero
        needsLayout = true
    }

    public override func layout() {
        super.layout()

        guard let currentWords, !currentWords.isEmpty else {
            group.isHidden = true
            group.removeAnimation(forKey: Self.animationKey)
            laidOutFor = .zero
            return
        }
        // Relaying out restarts the animation, so it happens on a real change of
        // size and not on every pass.
        guard bounds.size != laidOutFor else { return }
        laidOutFor = bounds.size

        group.isHidden = false
        let size = arrange(currentWords)
        animate(within: size)
    }

    /// Sizes the words, returning their size.
    ///
    /// **The font is fitted rather than fixed.** A point size that suits a laptop
    /// panel is lost on a 6K display and overflows a small window, so the words
    /// are sized to occupy a share of the width — by `EmptyStateWords`, which
    /// the wallpaper's still follows too.
    private func arrange(_ line: String) -> CGSize {
        let font = EmptyStateWords.font(for: line, in: bounds.size)
        words.string = line
        words.font = font
        words.fontSize = font.pointSize
        let size = (line as NSString).size(withAttributes: [.font: font])
        // The group's own position is what the animation moves.
        group.bounds = CGRect(origin: .zero, size: size)
        words.frame = group.bounds
        return size
    }

    /// One keyframe animation over a closed path, repeating for ever.
    ///
    /// **Not a per-bounce chain and not a timer.** A layer animation runs on the
    /// render server, so the words keep moving smoothly while this process is
    /// busy decoding a photograph — which is exactly the moment a stutter would
    /// be noticed. The path closes on itself, so `repeatCount: .infinity` has no
    /// seam and there is nothing to reschedule.
    private func animate(within label: CGSize) {
        group.removeAnimation(forKey: Self.animationKey)

        guard let path = BouncePath.plan(in: bounds.size, label: label) else {
            // Not enough room to travel. Centred and still is the right answer;
            // manufacturing motion in a space too small for it reads as a defect.
            group.position = CGPoint(x: bounds.midX, y: bounds.midY)
            return
        }

        group.position = path.points[0]
        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.values = path.points
        animation.keyTimes = path.keyTimes.map(NSNumber.init(value:))
        animation.duration = path.duration
        animation.calculationMode = .linear
        animation.repeatCount = .infinity
        // Constant speed and pure reflection: no easing anywhere, because a
        // bounce that slows into the wall is a physics this does not have.
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        group.add(animation, forKey: Self.animationKey)
    }
}

/// SwiftUI's side of it, so the window mounts the same view the saver does.
public struct EmptyStateDisplay: NSViewRepresentable {
    private let words: String?

    public init(words: String?) {
        self.words = words
    }

    public func makeNSView(context: Context) -> EmptyStateView {
        let view = EmptyStateView(frame: .zero)
        view.show(words: words)
        return view
    }

    public func updateNSView(_ view: EmptyStateView, context: Context) {
        view.show(words: words)
    }
}

#endif
