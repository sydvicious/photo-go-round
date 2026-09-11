import CoreGraphics
import Foundation
import ImageIO
import Observation
import PhotoGoRoundAgentAPI

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
            case .noAgent, .silent: "Photo-Go-Round Is Not Running"
            }
        }

        /// The line underneath the words: **what to do, never what went wrong.**
        ///
        /// The reason a failure was constructed with is a fact about the agent
        /// and not an instruction to anybody, so it stays in `line` and out of
        /// this. Nothing is broken when there are no photographs — nobody has
        /// added any — and nothing the person can read will unstick a wedged
        /// agent, so both cases name a place to go instead.
        ///
        /// **The agent wording is wrong inside the app and right inside the
        /// saver**, because the app *is* the application it tells you to open.
        /// It stands until the first-launch work gives the window its Install
        /// and Launch buttons, which is what it should show instead.
        public var detail: String? {
            switch self {
            case .noPhotos: "Use the Settings panel in the application to add images."
            case .noAgent, .silent: "Open the Photo-Go-Round application to start it."
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

    /// How long a picture stays up. Not yet a preference: *Everything
    /// user-settable is a user default* is held back to Beyond 0.1, and a
    /// number nobody has looked at yet is not worth a key.
    public static let defaultDwell = Duration.seconds(10)
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
    private let dwell: Duration
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

    public init(
        source: PictureSource,
        consumer: String,
        dwell: Duration = Shuffle.defaultDwell,
        whenEmpty: Duration = Shuffle.defaultWhenEmpty,
        whenAbsent: Duration = Shuffle.defaultWhenAbsent
    ) {
        self.source = source
        self.consumer = consumer
        self.dwell = dwell
        self.whenEmpty = whenEmpty
        self.whenAbsent = whenAbsent
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
    public convenience init(consumer: String, deployment: Deployment = .development) {
        let environment = MacHostEnvironment(deployment: deployment)
        self.init(
            source: PictureClient(preferences: environment.preferences),
            consumer: consumer)
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
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.advance()
                try? await Task.sleep(for: wait)
            }
        }
    }

    /// One picture, and how long to wait before the next.
    private func advance() async -> Duration {
        guard let box else { return whenEmpty }
        do {
            guard let picture = try await source.next(
                consumer: consumer, displayID: displayID, fitting: box)
            else {
                emptyAnswers += 1
                // Below the threshold nothing is said at all — not even that
                // the trouble has cleared. An empty answer is not the agent
                // answering again; it is the agent saying it has nothing, and
                // whatever was already up stays up and keeps its words.
                if emptyAnswers >= Self.emptyAnswersBeforeSaying { note(.noPhotos) }
                return whenEmpty
            }
            emptyAnswers = 0
            guard let image = await Self.decode(picture.data) else {
                // The service skips a photograph that will not render and
                // retires it after three tries; this is the same failure on
                // our side of the wire, and the answer is the same — ask for
                // another rather than show nothing.
                return Self.whenUndecodable
            }
            shown = Frame(image: image, picture: picture)
            note(nil)
            return dwell
        } catch let failure as PictureClient.Failure {
            emptyAnswers = 0
            note(Self.trouble(from: failure))
            return whenAbsent
        } catch {
            emptyAnswers = 0
            note(.noAgent(error.localizedDescription))
            return whenAbsent
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
    private static func decode(_ data: Data) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> Decoded? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return Decoded(image: image)
        }.value?.image
    }
}
