#if canImport(AppKit)

import AppKit
import SwiftUI

/// The words that appear when there has never been a photograph, drifting around
/// the view and reflecting off its edges.
///
/// **Shared by the window and the screensaver, which settles an argument.**
/// `app/mac/FEATURES.md` listed *The empty state moves* as the app's to build
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
    private let detail = CATextLayer()
    /// Both lines move together, so one animation carries the pair.
    private let group = CALayer()

    private var currentWords: String?
    private var currentDetail: String?
    private var laidOutFor: CGSize = .zero

    private static let animationKey = "bounce"

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(group)
        for text in [words, detail] {
            text.foregroundColor = NSColor.white.cgColor
            text.alignmentMode = .center
            text.truncationMode = .none
            text.isWrapped = false
            group.addSublayer(text)
        }
        group.isHidden = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    /// The words and the line underneath, or `nil` for neither — which hides the
    /// whole thing and stops the animation.
    public func show(words newWords: String?, detail newDetail: String?) {
        guard newWords != currentWords || newDetail != currentDetail else { return }
        currentWords = newWords
        currentDetail = newDetail
        needsLayout = true
    }

    public override var isFlipped: Bool { false }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for text in [words, detail] { text.contentsScale = scale }
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
        let size = arrange(currentWords, currentDetail)
        animate(within: size)
    }

    /// Sizes both lines and stacks them, returning the block's size.
    ///
    /// **The font is fitted rather than fixed.** A point size that suits a laptop
    /// panel is lost on a 6K display and overflows a small window, so the words
    /// are sized to occupy a share of the width and the second line follows at a
    /// fraction of that.
    private func arrange(_ line: String, _ second: String?) -> CGSize {
        let target = bounds.width * 0.55
        let wordsFont = Self.font(for: line, fitting: target, cap: bounds.height / 5)
        let detailFont = NSFont.systemFont(ofSize: wordsFont.pointSize * 0.34, weight: .regular)

        words.string = line
        words.font = wordsFont
        words.fontSize = wordsFont.pointSize
        let wordsSize = (line as NSString).size(withAttributes: [.font: wordsFont])

        var detailSize = CGSize.zero
        if let second, !second.isEmpty {
            detail.isHidden = false
            detail.string = second
            detail.font = detailFont
            detail.fontSize = detailFont.pointSize
            detailSize = (second as NSString).size(withAttributes: [.font: detailFont])
        } else {
            detail.isHidden = true
            detail.string = nil
        }

        let gap = detailSize.height > 0 ? wordsFont.pointSize * 0.45 : 0
        let width = max(wordsSize.width, detailSize.width)
        let height = wordsSize.height + gap + detailSize.height

        // Laid out inside the group with the words on top; the group's own
        // position is what the animation moves.
        group.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        words.frame = CGRect(
            x: 0, y: height - wordsSize.height, width: width, height: wordsSize.height)
        detail.frame = CGRect(x: 0, y: 0, width: width, height: detailSize.height)
        return CGSize(width: width, height: height)
    }

    /// The largest size at which the line still fits the width, bounded so it
    /// cannot swallow the view vertically either.
    private static func font(for line: String, fitting width: CGFloat, cap: CGFloat) -> NSFont {
        let probe = NSFont.systemFont(ofSize: 100, weight: .thin)
        let measured = (line as NSString).size(withAttributes: [.font: probe]).width
        guard measured > 0, width > 0 else { return NSFont.systemFont(ofSize: 24, weight: .thin) }
        let scaled = 100 * width / measured
        return NSFont.systemFont(ofSize: max(16, min(scaled, max(16, cap))), weight: .thin)
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
    private let detail: String?

    public init(words: String?, detail: String?) {
        self.words = words
        self.detail = detail
    }

    public func makeNSView(context: Context) -> EmptyStateView {
        let view = EmptyStateView(frame: .zero)
        view.show(words: words, detail: detail)
        return view
    }

    public func updateNSView(_ view: EmptyStateView, context: Context) {
        view.show(words: words, detail: detail)
    }
}

#endif
