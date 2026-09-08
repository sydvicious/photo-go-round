import AppKit
import OSLog
import PhotoGoRoundDisplay
import ScreenSaver

/// The screensaver: one photograph at a time, sized to fit, on black.
///
/// **It is the app's window with the chrome taken off, and that is literal.**
/// The loop that asks the agent for a picture, the layer that draws it, and the
/// fit that sizes it are all `PhotoGoRoundDisplay`, shared with the window
/// rather than reimplemented here. What this file adds is a `ScreenSaverView`'s
/// lifecycle and nothing else.
///
/// **The loop belongs to the display, not to this view** — see
/// `DisplayShuffles`, and the measurement that put it there. A view borrows its
/// display's loop and gives it back; it never owns one.
///
/// **No pan and no cross-fade in v1**, by decision on 2026-09-07. Both are
/// deferred rather than dropped; `Pan` is already in the display library with
/// its geometry tested, waiting for the phase that turns it on. See
/// `Screensaver Plan.md`.
@objc(PGRScreenSaverView)
public final class PGRScreenSaverView: ScreenSaverView {

    private static let log = Logger(subsystem: "com.sydpolk.photogoround", category: "saver")

    /// The photograph. A subview rather than this view's own layer, because it
    /// is the same one the window uses and it owns its own geometry.
    private let picture = PictureLayerView(frame: .zero)

    /// The words, when there has never been a photograph.
    ///
    /// **Sitting still would be a burn-in hazard**, so it is repositioned once
    /// per dwell below. That is a placeholder for the bouncing empty state,
    /// which is deferred with the rest of the motion and is not this.
    private let words = NSTextField(labelWithString: "")

    /// The display's loop, borrowed. Never created here and never discarded
    /// here — `DisplayShuffles` owns both ends of that.
    private var shuffle: Shuffle?

    /// Whether the engine currently wants this view animating. Attaching is
    /// gated on it so that a layout arriving before or after `startAnimation`
    /// lands the same way.
    private var running = false

    /// The registry key this view is currently holding a claim on.
    ///
    /// **`nonisolated(unsafe)` for `deinit` alone.** Every read and write is on
    /// the main actor; `deinit` runs after the last reference is gone, when
    /// nothing else can be touching it, and it has to know whether a claim is
    /// still outstanding.
    nonisolated(unsafe) private var claimed: String?

    /// The last size the view said it was, so a loop joined *after* layout
    /// still learns how big this display is.
    private var lastBox: PixelSize?

    /// Which display this view is on, **resolved fresh every time it is asked
    /// for rather than cached.**
    ///
    /// Caching it was a bug with a measurement: on 2026-09-08 one view keyed
    /// itself to `unknown` and its sibling to the real UUID, so two views on one
    /// screen took two loops and drew twice the screen's share. The cause is
    /// that the identity was taken at first layout, and `NSWindow.screen` is nil
    /// until the window has actually been placed on one — `window != nil` is not
    /// the same question. Reading it live means the answer corrects itself the
    /// moment the window lands.
    private var currentDisplay: String? {
        PictureLayerView.identifier(of: window?.screen)
    }

    /// The card last put on the glass, so a picture is logged once when it
    /// arrives rather than on every observation that fires.
    private var showing: Int64?

    /// Which instance a line came from. The host reuses its process and makes
    /// more than one view per display, so without this the log is several
    /// conversations interleaved with no way to tell them apart.
    nonisolated var instance: String {
        String(UInt(bitPattern: ObjectIdentifier(self)) & 0xffff, radix: 16)
    }

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)

        // Nothing is animated per frame; see `animateOneFrame`. The interval
        // still has to be something the engine will accept.
        animationTimeInterval = 1

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        picture.autoresizingMask = [.width, .height]
        picture.frame = bounds
        addSubview(picture)

        words.textColor = .white
        words.alignment = .center
        words.isHidden = true
        addSubview(words)

        picture.draws = { [weak self] pixels, display in
            guard let self else { return }
            self.lastBox = pixels
            // `display` is ignored: this view resolves its own, live, because
            // the value the layout pass had may predate the window landing on a
            // screen. See `currentDisplay`.
            _ = display
            if self.running { self.attach() }
        }

        // **Every instantiation says so.** The host makes views this file does
        // not control the number or the purpose of, and a run where nothing is
        // on screen has to be able to say whether a view was even made.
        Self.log.notice(
            "saver[\(self.instance, privacy: .public)]: created, preview=\(isPreview, privacy: .public), \(Int(frame.width), privacy: .public)x\(Int(frame.height), privacy: .public)")
    }

    /// Required because the class is instantiated through the Objective-C
    /// runtime — one of the three configuration traps in `PLAN.md`'s *Swift
    /// everywhere, including the screensaver*.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// **Gives the claim back even if nothing else did.** If a claim is still
    /// outstanding here, neither `stopAnimation` nor losing a window reached
    /// this view, and without this the display's loop would run for ever.
    deinit {
        let outstanding = claimed
        Self.log.notice(
            "saver[\(self.instance, privacy: .public)]: gone\(outstanding == nil ? "" : ", with a claim outstanding", privacy: .public)")
        guard let outstanding else { return }
        // No `self` crosses this boundary — only the key, by value.
        Task { @MainActor in DisplayShuffles.release(outstanding) }
    }

    public override var hasConfigureSheet: Bool { false }
    public override var configureSheet: NSWindow? { nil }

    // MARK: - Lifecycle

    public override func startAnimation() {
        super.startAnimation()

        // **The preview never serves.** Serving pops the queue, so a thumbnail
        // that asked would spend photographs nobody sees — and with one shared
        // queue it would spend the wallpaper's too. The real thumbnail is
        // Phase 4's; this is the guard that keeps browsing settings free.
        //
        // It says so out loud: returning here in silence made a preview
        // instance and a view that never started produce identical logs, which
        // is exactly the question that had to be answered on 2026-09-08.
        guard !isPreview else {
            Self.log.notice(
                "saver[\(self.instance, privacy: .public)]: preview, not serving")
            words.stringValue = "Photo-Go-Round"
            words.isHidden = false
            needsLayout = true
            return
        }

        Self.log.notice(
            "saver[\(self.instance, privacy: .public)]: startAnimation, window=\(self.window != nil, privacy: .public), box=\(self.lastBox != nil, privacy: .public)")

        running = true
        attach()
    }

    public override func stopAnimation() {
        super.stopAnimation()
        guard !isPreview else { return }
        Self.log.notice("saver[\(self.instance, privacy: .public)]: stopAnimation")
        running = false
        release()
    }

    /// **The guard for a view the engine forgot.** A view belonging to a
    /// finished session has no window, whoever is still holding a pointer to
    /// it — and a claim it never gives back would keep the display's loop
    /// asking all day with nothing on screen.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.log.notice(
            "saver[\(self.instance, privacy: .public)]: window=\(self.window != nil, privacy: .public), running=\(self.running, privacy: .public)")
        if window == nil {
            release()
        } else if running {
            attach()
        }
    }

    /// **Deliberately empty.** `ScreenSaverView`'s per-frame callback is the
    /// wrong tool: a layer animation runs on the render server and stays smooth
    /// while this process is decoding the next photograph, which is exactly
    /// when per-frame drawing would stutter. The pan will be a `CABasicAnimation`
    /// for that reason, and there is nothing to animate yet regardless.
    public override func animateOneFrame() {}

    // MARK: - Borrowing the display's loop

    /// **Cheap and idempotent, so it can be called from anywhere the answer
    /// might have changed** — starting, gaining a window, and every layout. A
    /// view that first attached under `unknown` moves itself to the real
    /// display's loop as soon as the window is placed, which costs one card and
    /// says so in the log.
    private func attach() {
        let display = currentDisplay
        let key = DisplayShuffles.key(for: display)

        // Already on this display's loop: nothing to claim, just make sure it
        // is running and knows the current size. `draws` starts a loop only
        // when there is not one, so this is safe to call repeatedly — which the
        // engine does.
        if claimed == key, let shuffle {
            if let lastBox { shuffle.draws(at: lastBox, on: display) }
            return
        }

        // A different display, or none yet: give back what we hold first.
        if let previous = claimed {
            Self.log.notice(
                "saver[\(self.instance, privacy: .public)]: display resolved \(previous, privacy: .public) -> \(key, privacy: .public)")
        }
        release()

        let shuffle = DisplayShuffles.attach(displayID: display)
        self.shuffle = shuffle
        claimed = key
        observe()
        // Whatever is already on that loop belongs on this glass immediately,
        // rather than after the first request comes back.
        render()
        if let lastBox { shuffle.draws(at: lastBox, on: display) }
        Self.log.notice(
            "saver[\(self.instance, privacy: .public)]: showing display \(key, privacy: .public)")
    }

    private func release() {
        guard let key = claimed else { return }
        claimed = nil
        shuffle = nil
        DisplayShuffles.release(key)
    }

    // MARK: - Drawing what the loop has

    private func observe() {
        withObservationTracking {
            _ = shuffle?.shown
            _ = shuffle?.trouble
        } onChange: { [weak self] in
            // `onChange` fires *before* the value is written, so the read has
            // to happen on the next turn — and re-registering is how tracking
            // continues past the first change.
            Task { @MainActor in
                self?.render()
                self?.observe()
            }
        }
    }

    private func render() {
        // Passing `nil` shows nothing rather than clearing, which is the rule:
        // a picture already on screen is never taken down.
        picture.show(shuffle?.shown)

        // **One line per photograph, at info.** The gate for this phase is an
        // evening, and with nothing at all a saver that ran perfectly and one
        // that showed a single picture and stalled produce identical logs.
        if let frame = shuffle?.shown, frame.picture.card != showing {
            showing = frame.picture.card
            let size = frame.picture.pixels
            Self.log.info(
                """
                saver[\(self.instance, privacy: .public)]: showing card \
                \(frame.picture.card ?? -1, privacy: .public) deal \
                \(frame.picture.deal ?? -1, privacy: .public) at \
                \(size?.width ?? 0, privacy: .public)x\(size?.height ?? 0, privacy: .public)
                """)
        }

        if shuffle?.shown != nil {
            words.isHidden = true
        } else if let trouble = shuffle?.trouble {
            words.stringValue = trouble.words
            words.isHidden = false
        }
        // Moved on every change, which with a ten-second dwell is roughly once
        // per dwell — enough that nothing sits in one place all night.
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        // The window may only now have landed on a screen, which is when a view
        // that attached under `unknown` can find its real display.
        if running { attach() }
        picture.frame = bounds
        words.font = .systemFont(ofSize: max(24, bounds.height / 12), weight: .thin)
        words.sizeToFit()
        words.frame.origin = wordsOrigin()
    }

    /// Centred, then nudged by a slowly changing offset so a label that stays
    /// up for hours does not stay in one place for hours.
    private func wordsOrigin() -> NSPoint {
        let slack = NSSize(
            width: max(0, bounds.width - words.frame.width),
            height: max(0, bounds.height - words.frame.height))
        guard slack.width > 0 || slack.height > 0 else { return .zero }
        // A cheap wander rather than a bounce: the bouncing empty state is the
        // deferred treatment, and pretending this is it would be worse than
        // being plainly a placeholder.
        let step = Double(Int(Date().timeIntervalSinceReferenceDate) / 10)
        let x = (sin(step * 0.7) + 1) / 2
        let y = (cos(step * 0.4) + 1) / 2
        return NSPoint(x: slack.width * x, y: slack.height * y)
    }
}
