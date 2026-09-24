import CoreGraphics
import Foundation
import ImageIO
import Observation
import PhotosGoRoundAgentAPI

/// Asks the agent for a picture, decodes it, and holds the one on screen.
///
/// **A picture already showing is never taken down.** When the queue runs empty
/// or the agent goes away, what is up stays up and the trouble is recorded
/// beside it — the words only appear when there has never been anything to show.
/// Blanking a window because the *next* picture is late would be a worse answer
/// than the stale picture, and the same rule keeps a screensaver from going
/// black mid-session when the cache is cleared under it.
///
/// **Shared by every surface as of Phase 2, and it names none of them.** The
/// window and the screensaver run this same loop; what differs is the
/// `consumer` it announces itself as, the deployment it was pointed at, and
/// the size it says it is drawing at. Nothing here knows what a window is, and
/// there is deliberately no `NSScreen` in the signature — a display's identity
/// arrives as the string the view worked out, so this file compiles anywhere
/// the library does.
@MainActor
@Observable
public final class Shuffle {

    /// The picture on screen, decoded and ready to draw.
    public private(set) var shown: Frame?
    /// Why there is nothing new, when there is a reason worth saying. Present
    /// alongside `shown`, which is what lets a stale picture stay up.
    public private(set) var trouble: Trouble?

    public struct Frame {
        public let image: CGImage
        public let picture: ServedPicture
        /// Read back from `PictureMemory` rather than served this session: the
        /// picture a surface opens with while it waits for a fresh one.
        public var remembered = false
        public var size: CGSize { CGSize(width: image.width, height: image.height) }
    }

    /// The empty states, of which the wire can distinguish exactly two.
    ///
    /// *The empty state* separates no-sources, sources-that-enumerate-to-nothing,
    /// and cold-start, and all three arrive here as `204` — a client cannot see
    /// the pool, which is the point of the service being the interface. The
    /// fourth is one that section predates: with no agent there is nobody to
    /// answer at all.
    public enum Trouble: Equatable {
        /// **Said only after three empty answers in a row.** See
        /// `emptyAnswersBeforeSaying`: one `204` is a queue turning over, not a
        /// library with nothing in it, and the first picture to arrive takes
        /// the words back down.
        case noPhotos
        case noAgent(String)
        /// The agent accepted the connection and never answered.
        ///
        /// **Not folded into `noAgent`, because it sends somebody to a
        /// different place.** "No agent" means start it; this means it is
        /// running and stuck, which on this project has one usual cause — a
        /// photo library that has stopped answering, taking the agent's
        /// cooperative threads with it. Telling somebody their agent is not
        /// running while its process sits in Activity Monitor is worse than
        /// saying nothing.
        case silent(String)

        /// **These are the words, and nothing here moves them.** Which
        /// surface owns the motion was ambiguous for a while — `FEATURES.md`
        /// said the app built it so the saver could inherit it, and this
        /// comment said it was the saver's — and the screensaver's v1 defers
        /// motion entirely, so neither has it yet. See `Screensaver Plan.md`,
        /// *The empty state without motion*.
        /// **A missing agent and a wedged one say the same thing here.** Syd,
        /// 2026-09-09: "to the user, 'no agent' and 'stuck agent' are the same
        /// thing." Nothing is arriving and there is one thing to do about it,
        /// so two messages would be a distinction drawn for the implementer's
        /// benefit. The difference is real and it survives in `line`, where
        /// whoever is diagnosing it can see which one happened.
        public var words: String {
            switch self {
            case .noPhotos: "No Photos Available"
            case .noAgent, .silent: "Waiting for Photos"
            }
        }

        /// The line underneath the words: **what to do, never what went wrong.**
        ///
        /// The reason a failure was constructed with is a fact about the agent
        /// and not an instruction to anybody, so it stays in `line` and out of
        /// this. Nothing is broken when there are no photographs — nobody has
        /// added any — so that case names a place to go.
        ///
        /// **Agent trouble has nothing underneath.** Until 2026-09-16 it said
        /// "Open the Photos-Go-Round application to start it." — shown inside the
        /// application it named, and wrong everywhere once launchd started the
        /// agent at login: opening the app starts nothing, and an agent that is
        /// still starting or busy is running. Syd: "fix the wording. it's
        /// stupid." There is no instruction that would help, so there is none;
        /// the Install and Launch buttons in `TODO.md` are what would go here.
        public var detail: String? {
            switch self {
            case .noPhotos: "Use the Settings panel in the application to add images."
            case .noAgent, .silent: nil
            }
        }

        /// Whether this is the agent's fault rather than an empty library.
        ///
        /// The window veils the photograph and names the trouble in its title
        /// for these and not for `noPhotos`, which is a library somebody can
        /// fix by adding a source and not a sign anything is broken.
        public var isAgentTrouble: Bool {
            switch self {
            case .noPhotos: false
            case .noAgent, .silent: true
            }
        }

        /// What to say in a log line — the words plus whatever detail came
        /// with them.
        public var line: String {
            switch self {
            case .noPhotos: "no photos"
            case .noAgent(let why): "no agent: \(why)"
            case .silent(let why): "not answering: \(why)"
            }
        }
    }

    /// A cold start answers `204` until the first downloads land, so this is
    /// how quickly a fresh library starts showing something.
    public static let defaultWhenEmpty = Duration.seconds(3)
    /// Longer, because a missing agent is not going to fix itself in a tick and
    /// hammering a closed port helps nobody.
    public static let defaultWhenAbsent = Duration.seconds(5)
    /// A picture that will not decode costs this much before the next is asked
    /// for — enough that a library of broken files cannot spin.
    private static let whenUndecodable = Duration.milliseconds(250)
    /// Empty answers in a row before the words go up.
    ///
    /// **One `204` is not news.** The agent's request drops every cold card it
    /// meets, so a request that arrives just as the queue turns over can walk
    /// off the end of it and answer empty while the fetcher is landing the next
    /// twenty cards — a gap of one refresh, not an empty library. Saying *No
    /// Photos Available* for that and taking it back three seconds later is a
    /// flicker that tells somebody nothing true.
    ///
    /// Three, against `whenEmpty` of three seconds, is about ten seconds of
    /// consistently nothing before the words appear — one dwell, and past any
    /// refresh the agent could still be inside.
    private static let emptyAnswersBeforeSaying = 3

    private let source: PictureSource
    /// What this surface calls itself on the wire, and in its own log lines.
    ///
    /// **A parameter rather than a constant, because there are two of these
    /// now.** The deck keys a consumer's history on it, so a screensaver
    /// announcing itself as `app` would share the window's row and neither
    /// would be readable afterwards.
    private let consumer: String
    /// The three waits, injected for the same reason `SourcesModel` takes its
    /// poll interval: a test that waits ten real seconds to watch one picture
    /// give way to the next is a test nobody will run.
    ///
    /// **The dwell is asked for before every wait**, not fixed when the loop is
    /// made. The screensaver hands in a read of its *Shuffle All* preference:
    /// its host outlives a session and a `Shuffle` is stopped rather than
    /// discarded, so a value captured once would keep an old choice until
    /// `legacyScreenSaver` exits. A window hands in its own value, and changes
    /// it with `setDwell`.
    @ObservationIgnored private var dwell: @MainActor () -> Duration
    private let whenEmpty: Duration
    private let whenAbsent: Duration
    /// The size the view is about to draw at, in pixels. Nothing is asked for
    /// until the view has laid out once and said what it is.
    private var box: PixelSize?
    private var displayID: String?
    private var loop: Task<Void, Never>?
    /// Empty answers since the last one that was not. Reset by anything else
    /// the agent says, including a failure — a streak is *consecutive* empties
    /// or it is not a streak.
    private var emptyAnswers = 0
    /// Whether the agent has answered since the loop last began — a picture or
    /// an empty queue alike. Until it has, a request is patient. See
    /// `ServiceTiming.firstPictureReadLimit`.
    private var answeredThisRun = false
    /// Where the last picture shown is kept for the next session, if this
    /// surface keeps one. See `PictureMemory`.
    @ObservationIgnored private let memory: PictureMemory?
    /// When the picture on screen appeared, which is what its dwell counts from.
    @ObservationIgnored private var appearedAt: ContinuousClock.Instant?
    /// The sleep the loop is in while a picture dwells, held so `setDwell` can
    /// wake the loop without ending it.
    @ObservationIgnored private var pause: Task<Void, Never>?

    public init(
        source: PictureSource,
        consumer: String,
        dwellFrom dwell: @escaping @MainActor () -> Duration,
        whenEmpty: Duration = Shuffle.defaultWhenEmpty,
        whenAbsent: Duration = Shuffle.defaultWhenAbsent,
        memory: PictureMemory? = nil
    ) {
        self.source = source
        self.consumer = consumer
        self.dwell = dwell
        self.whenEmpty = whenEmpty
        self.whenAbsent = whenAbsent
        self.memory = memory
        if memory != nil {
            Task { await self.openWithRemembered() }
        }
    }

    /// Puts up the picture the last session left, **unless a fresh one has
    /// already arrived** — the read is a few milliseconds and the agent can
    /// occasionally beat it.
    private func openWithRemembered() async {
        guard let memory, shown == nil, let recalled = await memory.recall(), shown == nil
        else { return }
        shown = Frame(image: recalled.image, picture: recalled.picture, remembered: true)
        Log.deck.notice(
            "\(self.consumer, privacy: .public): opening with the remembered picture, card \(recalled.picture.card ?? -1, privacy: .public)"
        )
    }

    /// A dwell that never changes: a window's copy, or a test's.
    public convenience init(
        source: PictureSource,
        consumer: String,
        dwell: Duration = ScreensaverPreferences.defaultInterval.duration,
        whenEmpty: Duration = Shuffle.defaultWhenEmpty,
        whenAbsent: Duration = Shuffle.defaultWhenAbsent
    ) {
        self.init(
            source: source, consumer: consumer, dwellFrom: { dwell },
            whenEmpty: whenEmpty, whenAbsent: whenAbsent)
    }

    /// The ordinary case: the agent this checkout's development runs talk to.
    ///
    /// `MacHostEnvironment` is asked for its preferences rather than a domain
    /// being spelled here, so the app and the agent cannot disagree about which
    /// deployment they are in — including when `PGR_PREFS_SUITE` moves it.
    ///
    /// **The deployment is a parameter and still defaults to development.** It
    /// was hardcoded while the window was the only surface; a shipped saver
    /// talks to production, and the default is what keeps every development run
    /// off a real library — see `Deployment`.
    public convenience init(
        consumer: String, deployment: Deployment = .development,
        dwell: Duration = ScreensaverPreferences.defaultInterval.duration
    ) {
        let environment = MacHostEnvironment(deployment: deployment)
        self.init(
            source: PictureClient(preferences: environment.preferences),
            consumer: consumer, dwell: dwell)
    }

    /// How long the next picture will stay up, as things stand.
    var currentDwell: Duration { dwell() }

    /// A new dwell for a loop that may already be running: the window's
    /// Window Settings sheet.
    ///
    /// **The picture on screen is held to it at once.** Syd, 2026-09-14:
    /// "change right away, counted from when the picture appeared." A dwell
    /// shorter than the picture has already been up changes it now; a longer
    /// one keeps it until the new dwell has passed since it appeared.
    public func setDwell(_ duration: Duration) {
        dwell = { duration }
        Log.deck.notice(
            "\(self.consumer, privacy: .public): each picture now up for \(duration.spokenSeconds, privacy: .public)")
        pause?.cancel()
    }

    /// Waits until the picture on screen has been up for the dwell, **counted
    /// from when it appeared**, and works it out again whenever `setDwell`
    /// wakes it. The sleep is a task of its own for exactly that: cancelling it
    /// ends the wait and leaves the loop running.
    private func dwellOnPicture() async {
        while !Task.isCancelled, let appearedAt {
            let remaining = appearedAt + dwell() - ContinuousClock.now
            guard remaining > .zero else { return }
            let pause = Task { _ = try? await Task.sleep(for: remaining) }
            self.pause = pause
            // `stop` cancels the loop, and the handler passes that on to the
            // sleep — or a stopped loop would sit out the rest of an hour's
            // dwell, and a restart would run beside it.
            await withTaskCancellationHandler {
                await pause.value
            } onCancel: {
                pause.cancel()
            }
        }
    }

    /// The view saying how big it is, in pixels, and which display it is on.
    ///
    /// Asking at the size actually being drawn is the whole point of the
    /// endpoint taking a box. A resize does not fetch a new picture — that
    /// would spend a card on a window drag — so the one on screen is scaled
    /// until the next arrives at the new size.
    ///
    /// **The display arrives as a string the view worked out**, rather than as
    /// an `NSScreen` this file would have to know about. That is what keeps the
    /// loop free of AppKit, and it puts the identifier next to the only code
    /// that has a screen in hand anyway — see `PictureLayerView.identifier(of:)`.
    public func draws(at pixels: PixelSize, on displayID: String?) {
        guard pixels.width > 0, pixels.height > 0 else { return }
        box = pixels
        self.displayID = displayID
        if loop == nil { begin() }
    }

    /// Stops asking, and **keeps what is on screen**.
    ///
    /// **Because the host process outlives the session.** `legacyScreenSaver`
    /// serves many screensaver sessions from one process — measured in the
    /// Phase 1 spike, where two view instances shared a pid 32 seconds apart —
    /// so a surface that starts a loop per session and never ends one
    /// accumulates them, each asking the agent for a photograph on its own
    /// tick, in a process nobody restarts.
    ///
    /// `shown` and `trouble` survive deliberately. Starting again after a wake
    /// then has a photograph to put up immediately rather than a black frame
    /// while the first request is in flight, which is *Always have something to
    /// show* applied to the surface it was written for. Asking again is
    /// `draws(at:on:)`, which starts the loop whenever there is not one.
    public func stop() {
        loop?.cancel()
        loop = nil
    }

    private func begin() {
        answeredThisRun = false
        Log.deck.notice(
            "\(self.consumer, privacy: .public): starting, each picture up for \(self.currentDwell.spokenSeconds, privacy: .public)")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                switch await self.advance() {
                case .fixed(let wait): try? await Task.sleep(for: wait)
                case .dwell: await self.dwellOnPicture()
                }
            }
        }
    }

    /// What the loop waits for after one ask.
    private enum Wait {
        /// A picture went up: until it has been up for the dwell.
        case dwell
        /// Nothing went up: a fixed pause before asking again.
        case fixed(Duration)
    }

    /// One picture, and what to wait for before the next.
    private func advance() async -> Wait {
        guard let box else { return .fixed(whenEmpty) }
        do {
            let answer = try await source.next(
                consumer: consumer, displayID: displayID, fitting: box,
                patient: !answeredThisRun)
            answeredThisRun = true
            guard let picture = answer else {
                emptyAnswers += 1
                // Below the threshold nothing is said at all — not even that
                // the trouble has cleared. An empty answer is not the agent
                // answering again; it is the agent saying it has nothing, and
                // whatever was already up stays up and keeps its words.
                if emptyAnswers >= Self.emptyAnswersBeforeSaying { note(.noPhotos) }
                return .fixed(whenEmpty)
            }
            emptyAnswers = 0
            guard let image = await Self.decode(picture.data, fitting: box) else {
                // The service skips a photograph that will not render and
                // retires it after three tries; this is the same failure on
                // our side of the wire, and the answer is the same — ask for
                // another rather than show nothing.
                return .fixed(Self.whenUndecodable)
            }
            shown = Frame(image: image, picture: picture)
            appearedAt = .now
            note(nil)
            if let memory {
                let consumer = self.consumer
                Task {
                    do {
                        try await memory.remember(image, as: picture)
                    } catch {
                        Log.deck.error(
                            "\(consumer, privacy: .public): could not keep the picture for next time: \(String(describing: error), privacy: .public)"
                        )
                    }
                }
            }
            return .dwell
        } catch let failure as PictureClient.Failure {
            emptyAnswers = 0
            note(Self.trouble(from: failure))
            return .fixed(whenAbsent)
        } catch {
            emptyAnswers = 0
            note(.noAgent(error.localizedDescription))
            return .fixed(whenAbsent)
        }
    }

    /// Records the trouble, and logs it **when it changes**.
    ///
    /// The loop turns every few seconds, so a log line per attempt would be a
    /// thousand identical entries across an evening with the agent down — which
    /// buries the one line that says when it went wrong and the one that says
    /// when it came back. Transitions go in at `.notice`, where they persist;
    /// each unchanged retry goes in at `.debug`, which is memory-only and there
    /// for somebody watching a stream live.
    private func note(_ next: Trouble?) {
        defer { trouble = next }
        guard next != trouble else {
            if let next { Log.deck.debug("\(self.consumer, privacy: .public): still \(next.line, privacy: .public)") }
            return
        }
        switch next {
        case .none:
            // Only worth a line if something had gone wrong. A first picture
            // arriving is not news.
            if trouble != nil {
                Log.deck.notice("\(self.consumer, privacy: .public): answering again, showing pictures")
            }
        case .some(let trouble):
            Log.deck.notice("\(self.consumer, privacy: .public): \(trouble.line, privacy: .public)")
        }
    }

    /// Internal rather than private so the wallpaper logs a failure in the same
    /// words the window and the saver do.
    static func trouble(from failure: PictureClient.Failure) -> Trouble {
        switch failure {
        case .noPortPublished:
            .noAgent("nothing has published a port — the agent is not running")
        // **The words are "No agent" and the log line is not.** For the person
        // looking at the glass these are the same predicament — there is nothing
        // either of them can do — so this does not earn a fourth set of words.
        // For whoever reads the log afterwards they are nothing alike, and that
        // is where the distinction is spent. A `Trouble` case of its own would
        // change what a window says, which is Syd's call rather than this
        // file's.
        case .portUnreadable(let reason):
            .noAgent("the port could not be read — \(reason)")
        case .unreachable(let port, let reason):
            .noAgent("nothing is listening on \(port) — \(reason)")
        case .refused(let status):
            .noAgent("the service answered \(status)")
        // **Still `noAgent`, and deliberately.** Syd, 2026-09-23, asked whether
        // a refused secret earns words of its own: no — the person at the glass
        // can do nothing about either. The log line is where they differ.
        case .noSecret:
            .noAgent("a port is published and no secret beside it — the agent is older, or still starting")
        case .notOurs(let port):
            .noAgent("the agent on \(port) refused this user's secret — it is not this user's agent")
        // **The one that is not `noAgent`.** Something is listening on the port
        // and did not answer inside the limit, which is a running agent that is
        // stuck rather than one that is gone.
        case .silent(let port, let limit):
            .silent("the agent on \(port) said nothing within \(limit.spokenSeconds)")
        }
    }

    /// `CGImage` is immutable once made and safe to read from anywhere, which
    /// the compiler has no way to know. The box says so once, here, rather than
    /// at every hop.
    private struct Decoded: @unchecked Sendable {
        let image: CGImage
    }

    /// Off the main thread, because a decode during a pan is exactly the moment
    /// a stutter would be noticed.
    ///
    /// **Upright, and no larger than the box.** Until 2026-09-16 this decoded
    /// the bytes as they stood, which was right while the agent always sent a
    /// picture already resized to the box and already rotated upright. Since
    /// then it sends the original when a resize stalls (`Agent Performance
    /// Overhaul.md`, Phase 2a): as large as the camera made it, a 48-megapixel
    /// HEIC costing about 190 MB decoded whole, and carrying its orientation as
    /// EXIF, which `CGImageSourceCreateImageAtIndex` ignores — a portrait
    /// photograph would have gone up sideways. The thumbnail call does both, and
    /// for a picture the agent already resized it changes nothing.
    static func decode(_ data: Data, fitting box: PixelSize) async -> CGImage? {
        // **`.medium`, not `.userInitiated`.** ImageIO hands part of a decode
        // to a thread of its own at Default QoS and waits on it, so a
        // user-initiated task here was a priority inversion — Xcode's Thread
        // Performance Checker, 2026-09-23. The decode is for the next picture,
        // made during this one's dwell; nothing waits on it at a higher class.
        await Task.detached(priority: .medium) { () -> Decoded? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0
            else { return nil }
            // Orientations 5 to 8 turn the picture a quarter, so its upright
            // width is its stored height.
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            let turned = (5...8).contains(orientation)
            let upright = CGSize(
                width: turned ? height : width, height: turned ? width : height)
            let fitted = AspectFit.size(
                of: upright, in: CGSize(width: box.width, height: box.height))
            // Never larger than the original: the view scales up, the decoder
            // need not.
            let longest = min(
                max(Int(fitted.width.rounded()), Int(fitted.height.rounded())), max(width, height))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, longest),
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return Decoded(image: image)
        }.value?.image
    }
}
