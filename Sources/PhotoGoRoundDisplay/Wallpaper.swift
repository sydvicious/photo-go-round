import Foundation
import Observation
import PhotoGoRoundAgentAPI
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif

/// One display the wallpaper is set on: which one, and how many pixels it has.
public struct WallpaperDisplay: Sendable, Equatable {
    /// `CGDisplayCreateUUIDFromDisplayID`, the same identity the deck keys a
    /// consumer on — and the start of the names of this display's files.
    public let id: String
    public let pixels: PixelSize

    public init(id: String, pixels: PixelSize) {
        self.id = id
        self.pixels = pixels
    }
}

/// What the wallpaper owns and where it keeps it: a preference domain and a
/// directory, one of each per deployment.
///
/// **Neither is the agent's.** Syd, 2026-09-10: "the app should not need to see
/// the agent's container", and "give the wallpaper its own domain. Actually
/// two" — `com.sydpolk.photogoround.wallpaper.dev` and `.prod`. The directory
/// is named the same, under `Application Support`: the files outlive the
/// process that wrote them, because macOS keeps reading whatever the desktop
/// points at, so they are not cache and must not be purged like it.
public struct WallpaperHome: Sendable, Equatable {
    public let domain: String
    public let directory: URL

    public init(domain: String, directory: URL) {
        self.domain = domain
        self.directory = directory
    }

    public init(deployment: Deployment, home: URL = URL.homeDirectory) {
        let suffix = switch deployment {
        case .production: "prod"
        case .development: "dev"
        }
        let domain = "\(Deployment.identifier).wallpaper.\(suffix)"
        self.init(
            domain: domain,
            directory: home.appending(path: "Library/Application Support/\(domain)"))
    }
}

/// When a display's picture last changed, and which file it is showing.
struct WallpaperRecord: Equatable {
    let changedAt: Date
    let file: URL
}

/// The desktop picture: one photograph per display, changed every minute for
/// now — see `defaultInterval`.
///
/// **A client like every other surface.** It asks the agent for a picture over
/// HTTP as consumer `wallpaper`, at each display's size in pixels, and the agent
/// does nothing for it but serve — "the agent's job is just to serve pictures."
/// The app hosts it today and a binary of its own may later, which is why it
/// lives in the display library: moving it is a new host, not a move of code.
///
/// **A display changes only when its stored time is `interval` old, launches
/// included.** Syd: "the image should not be changed before the time
/// interval (initially 30 minutes) if it has previously been saved, even if the
/// binary was just started up." Each display's change time and file are kept in
/// the wallpaper's own preference domain, so one question — which displays are
/// due? — is asked at start, on wake, when the loop's sleep ends, and when a
/// display appears, and there is no separate rule for each.
///
/// **Two files per display, alternating.** Setting the URL the desktop already
/// shows does not redraw it, even when the file underneath has changed —
/// measured with `Scripts/wallpaper-probe.swift` on 2026-09-10 — so every
/// change writes and sets the name that is not on screen.
///
/// **The fill colour is not ours.** The options carry scaling and clipping and
/// nothing else, which keeps whatever colour System Settings has — measured the
/// same day, with Syd's colour changed to rule out a coincidental default.
///
/// **An empty library, or no agent, leaves the desktop alone**, and the display
/// is asked for again after `retry` rather than the whole interval.
///
/// Everything AppKit is at the bottom of the file, behind closures, so a test
/// drives the loop without touching anybody's desktop. See `Wallpaper Plan.md`.
@MainActor
@Observable
public final class Wallpaper {

    /// What `intervalSeconds` means when nothing has set it. **Sixty seconds for
    /// now.** Syd, 2026-09-10: "could we make the internal for the wallpaper 60
    /// seconds for now? Eventually we will have a set of choices" — and "this
    /// should be part of the wallpaper preferences." It was thirty minutes,
    /// which is what `Wallpaper Plan.md` was written around.
    public static let defaultInterval = Duration.seconds(60)
    /// The bounds `intervalSeconds` is clamped to. `defaults write` accepts
    /// anything, and a wallpaper asking every tenth of a second, or never, is
    /// not a setting anybody meant.
    static let shortestInterval = Duration.seconds(10)
    static let longestInterval = Duration.seconds(7 * 24 * 60 * 60)
    /// The loop never sleeps longer than this, so a changed `intervalSeconds`
    /// is noticed within it rather than at the next change — no preference
    /// ever needs a restart. A round with nothing due costs one file check per
    /// display.
    public static let defaultRecheck = Duration.seconds(30)
    /// How soon to ask again for a display that got nothing. Not the
    /// screensaver's three seconds: nothing on the desktop is blank while this
    /// waits, so there is no hurry worth the log lines.
    public static let defaultRetry = Duration.seconds(60)
    /// The loop never sleeps for less than this, whatever the arithmetic says,
    /// so a clock that misbehaves cannot make it spin.
    static let shortestWait = Duration.seconds(1)

    /// The displays attached right now.
    public typealias Displays = @MainActor () -> [WallpaperDisplay]
    /// Makes a file the desktop on the display with this identity.
    public typealias SetDesktop = @MainActor (URL, String) throws -> Void
    /// What the system says a display is showing — for the log only, since it
    /// was measured lagging behind the glass on 2026-09-10.
    public typealias Reported = @MainActor (String) -> URL?

    public enum Failure: Error, CustomStringConvertible {
        /// The display was there when the round began and was gone when its
        /// picture arrived — unplugged mid-request.
        case displayGone(String)

        public var description: String {
            switch self {
            case .displayGone(let id): "display \(id) is no longer attached"
            }
        }
    }

    /// The *Also set wallpapers* checkbox. **Off until somebody ticks it** —
    /// the default is an open question in `Wallpaper Plan.md`, and off means a
    /// development build does not change anybody's desktop just by launching.
    public private(set) var isEnabled: Bool

    @ObservationIgnored private let source: PictureSource
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let retry: Duration
    @ObservationIgnored private let recheck: Duration
    @ObservationIgnored private let displays: Displays
    @ObservationIgnored private let setDesktop: SetDesktop
    @ObservationIgnored private let reported: Reported
    @ObservationIgnored private let now: @MainActor () -> Date

    @ObservationIgnored private var loop: Task<Void, Never>?
    /// A round is in flight. Nothing starts a second one on top of it.
    @ObservationIgnored private var changing = false
    /// Something asked for a round while one was in flight, so the loop runs
    /// another as soon as this one ends instead of sleeping.
    @ObservationIgnored private var kicked = false
    /// The last trouble logged, so a quiet agent is one line when it goes quiet
    /// and one when it comes back, not one per retry.
    @ObservationIgnored private var trouble: String?
    /// The last complaint about `intervalSeconds`, so a bad value is one line
    /// and not one per read.
    @ObservationIgnored private var intervalProblem: String?
    /// Held for the life of the wallpaper; see `watchTheSystem()`.
    @ObservationIgnored var observers: [any NSObjectProtocol] = []

    private enum Key {
        static let enabled = "enabled"
        /// How long a display keeps its picture, in seconds. See `interval`.
        static let interval = "intervalSeconds"
        /// `[display UUID: ["changedAt": Date, "file": path]]`, readable with
        /// `defaults read` on the wallpaper's domain.
        static let displays = "displays"
    }

    public init(
        source: PictureSource,
        directory: URL,
        defaults: UserDefaults,
        retry: Duration = Wallpaper.defaultRetry,
        recheck: Duration = Wallpaper.defaultRecheck,
        displays: @escaping Displays,
        setDesktop: @escaping SetDesktop,
        reported: @escaping Reported = { _ in nil },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.source = source
        self.directory = directory
        self.defaults = defaults
        self.retry = retry
        self.recheck = recheck
        self.displays = displays
        self.setDesktop = setDesktop
        self.reported = reported
        self.now = now
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? false
    }

    // MARK: - On and off

    /// The host's launch: runs the wallpaper if the checkbox is ticked.
    public func resume() {
        guard isEnabled else {
            Log.wallpaper.notice("wallpaper: off; the desktop is left alone")
            return
        }
        start()
    }

    /// The checkbox. Ticking starts it; unticking stops it and leaves the
    /// desktop as it is — taking our picture down would mean choosing a
    /// replacement for somebody.
    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        Log.wallpaper.notice("wallpaper: \(enabled ? "turned on" : "turned off", privacy: .public)")
        if enabled { start() } else { stop() }
    }

    /// **Displays that are not due get their stored file back at once**, and
    /// the first round changes the ones that are. Syd: "yes, put the stored
    /// files back at launch" — the desktop may have been reverted, or changed,
    /// while nothing was running.
    private func start() {
        guard loop == nil else { return }
        Log.wallpaper.notice(
            "wallpaper: starting, every \(self.interval.spokenSeconds, privacy: .public), into \(self.directory.path(percentEncoded: false), privacy: .private)")
        compareWithReported()
        putBack(because: "starting")
        begin()
    }

    private func stop() {
        loop?.cancel()
        loop = nil
        Log.wallpaper.notice("wallpaper: stopped; the desktop keeps what it has")
    }

    private func begin() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.round()
                try? await Task.sleep(for: wait)
            }
        }
    }

    // MARK: - Events

    /// The Mac woke. Whatever came due while it slept changes now — the loop's
    /// own sleep is not trusted to have noticed the time that passed.
    public func woke() {
        guard loop != nil else { return }
        Log.wallpaper.info("wallpaper: woke; asking which displays are due")
        kick()
    }

    /// Displays or Spaces changed. `setDesktopImageURL` sets the current Space
    /// on one screen and nothing else, so each display's file is put back — no
    /// card spent — and a display that has never had a picture is given one.
    public func reapply(because reason: String) {
        guard loop != nil else { return }
        if putBack(because: reason) > 0 { kick() }
    }

    /// Runs a round now rather than when the loop's sleep ends.
    private func kick() {
        if changing {
            kicked = true
            return
        }
        loop?.cancel()
        begin()
    }

    // MARK: - Rounds

    /// A new picture for every display that is due, and how long to sleep
    /// before asking again.
    func round() async -> Duration {
        changing = true
        defer { changing = false }
        kicked = false

        let present = displays()
        guard !present.isEmpty else {
            note("no identified display to set")
            return min(retry, recheck)
        }
        var shortfall = false
        for display in present where isDue(display.id) {
            if Task.isCancelled { return retry }
            if await !give(display) { shortfall = true }
        }
        if kicked { return .zero }
        return min(wait(for: present, shortfall: shortfall), recheck)
    }

    /// Until the next display that is not due becomes due — or `retry`, when a
    /// display that was due got nothing.
    private func wait(for present: [WallpaperDisplay], shortfall: Bool) -> Duration {
        let current = now()
        var next = shortfall ? retry : interval
        for display in present where !isDue(display.id) {
            guard let record = record(for: display.id) else { continue }
            let remaining = interval.totalSeconds - current.timeIntervalSince(record.changedAt)
            next = min(next, .seconds(max(remaining, 0)))
        }
        return max(next, Self.shortestWait)
    }

    /// Due when there is no record, when its file is gone, when its time is in
    /// the future — a clock set back would otherwise hold it until the clock
    /// caught up — or when the interval has passed.
    func isDue(_ id: String) -> Bool {
        guard let record = record(for: id) else { return true }
        guard FileManager.default.fileExists(atPath: record.file.path(percentEncoded: false)) else {
            return true
        }
        let elapsed = now().timeIntervalSince(record.changedAt)
        return elapsed < 0 || elapsed >= interval.totalSeconds
    }

    /// Sets each display's stored file again, for displays that are not due;
    /// a due display is left for the round. Returns how many are due.
    @discardableResult
    private func putBack(because reason: String) -> Int {
        var restored = 0
        var due = 0
        for display in displays() {
            guard !isDue(display.id), let record = record(for: display.id) else {
                due += 1
                continue
            }
            do {
                try setDesktop(record.file, display.id)
                restored += 1
            } catch {
                Log.wallpaper.error(
                    "wallpaper: could not put \(record.file.lastPathComponent, privacy: .public) back on \(display.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        Log.wallpaper.notice(
            "wallpaper: \(reason, privacy: .public); put \(restored, privacy: .public) displays' files back, \(due, privacy: .public) due for a new picture")
        return due
    }

    /// Says when a display reports something other than the file stored for
    /// it — the desktop changed while nothing was running, or the report lags.
    /// **A log line and nothing more**: the report was measured wrong once.
    private func compareWithReported() {
        for display in displays() {
            guard let record = record(for: display.id), let shown = reported(display.id) else { continue }
            if shown.standardizedFileURL != record.file.standardizedFileURL {
                Log.wallpaper.notice(
                    "wallpaper: display \(display.id, privacy: .public) reports \(shown.lastPathComponent, privacy: .public), stored \(record.file.lastPathComponent, privacy: .public)")
            }
        }
    }

    /// Asks for one display's picture and makes it that display's desktop.
    /// False, and the desktop and the record untouched, when there was nothing
    /// to give it.
    private func give(_ display: WallpaperDisplay) async -> Bool {
        let picture: ServedPicture?
        do {
            picture = try await source.next(
                consumer: ConsumerKind.wallpaper.rawValue, displayID: display.id,
                fitting: display.pixels)
        } catch let failure as PictureClient.Failure {
            if Task.isCancelled { return false }
            note(Shuffle.trouble(from: failure).line)
            return false
        } catch {
            if Task.isCancelled { return false }
            note("no agent: \(error.localizedDescription)")
            return false
        }
        // Unticked while the picture was on its way: it is not set.
        guard !Task.isCancelled else { return false }
        guard let picture else {
            note("no photos")
            return false
        }

        let file = directory.appending(
            path: Self.filename(
                for: display.id, contentType: picture.contentType,
                after: record(for: display.id)?.file))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Atomic, so the system never reads a half-written file.
            try picture.data.write(to: file, options: .atomic)
            try setDesktop(file, display.id)
        } catch {
            Log.wallpaper.error(
                "wallpaper: could not set display \(display.id, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
        // Only now: a fetch or a set that failed leaves the display due.
        store(WallpaperRecord(changedAt: now(), file: file), for: display.id)
        note(nil)
        Log.wallpaper.notice(
            """
            wallpaper: display \(display.id, privacy: .public) now card \
            \(picture.card ?? -1, privacy: .public) deal \(picture.deal ?? -1, privacy: .public) \
            at \(picture.pixels?.width ?? 0, privacy: .public)x\(picture.pixels?.height ?? 0, privacy: .public) \
            for \(display.pixels.width, privacy: .public)x\(display.pixels.height, privacy: .public), \
            \(file.lastPathComponent, privacy: .public)
            """)
        return true
    }

    /// `<display UUID>-a.<extension>` or `-b`, whichever is not the file the
    /// display showed last. The extension follows what was served — HEIC,
    /// unless something asks otherwise — because the system decides how to
    /// read the file by its name.
    static func filename(for displayID: String, contentType: String, after previous: URL?) -> String {
        let side = previous?.lastPathComponent.hasPrefix("\(displayID)-a.") == true ? "b" : "a"
        let suffix = UTType(mimeType: contentType)?.preferredFilenameExtension ?? "image"
        return "\(displayID)-\(side).\(suffix)"
    }

    // MARK: - The preferences

    /// `intervalSeconds` in the wallpaper's domain, **read every time it is
    /// needed** — nothing reads a preference into a stored property, so a
    /// `defaults write` applies within `recheck` and never needs a restart.
    /// Parsed with a default and a clamp, as every preference is: a value that
    /// is not a number is ignored, and one out of range is brought inside it.
    var interval: Duration {
        guard let raw = defaults.object(forKey: Key.interval) else { return Self.defaultInterval }
        guard let seconds = (raw as? NSNumber)?.doubleValue, seconds.isFinite else {
            complainAboutInterval(
                "\(Key.interval) is not a number; using \(Self.defaultInterval.spokenSeconds)")
            return Self.defaultInterval
        }
        let clamped = min(
            max(seconds, Self.shortestInterval.totalSeconds), Self.longestInterval.totalSeconds)
        if clamped != seconds {
            complainAboutInterval(
                "\(Key.interval) of \(seconds) is out of range; using \(Duration.seconds(clamped).spokenSeconds)")
        }
        return .seconds(clamped)
    }

    /// Once per bad value, not once per read — the interval is read on every
    /// round.
    private func complainAboutInterval(_ line: String) {
        guard line != intervalProblem else { return }
        intervalProblem = line
        Log.wallpaper.error("wallpaper: \(line, privacy: .public)")
    }

    // MARK: - The record

    func record(for id: String) -> WallpaperRecord? {
        guard
            let entry = defaults.dictionary(forKey: Key.displays)?[id] as? [String: Any],
            let changedAt = entry["changedAt"] as? Date,
            let path = entry["file"] as? String
        else { return nil }
        return WallpaperRecord(changedAt: changedAt, file: URL(filePath: path))
    }

    private func store(_ record: WallpaperRecord, for id: String) {
        var all = defaults.dictionary(forKey: Key.displays) ?? [:]
        all[id] = ["changedAt": record.changedAt, "file": record.file.path(percentEncoded: false)]
        defaults.set(all, forKey: Key.displays)
    }

    /// Logs trouble **when it changes**, the way `Shuffle` does: a retry every
    /// minute with the agent down would otherwise be a line a minute all night.
    private func note(_ next: String?) {
        defer { trouble = next }
        guard next != trouble else {
            if let next { Log.wallpaper.debug("wallpaper: still \(next, privacy: .public)") }
            return
        }
        if let next {
            Log.wallpaper.notice("wallpaper: \(next, privacy: .public); the desktop keeps what it has")
        } else if trouble != nil {
            Log.wallpaper.notice("wallpaper: answering again")
        }
    }
}

#if canImport(AppKit)

extension WallpaperDisplay {
    /// A screen as the wallpaper sees it, or nil for one with no identity —
    /// which has no file name and so cannot be given a picture.
    @MainActor
    public init?(screen: NSScreen) {
        guard let id = PictureLayerView.identifier(of: screen) else { return nil }
        let backing = screen.convertRectToBacking(screen.frame).size
        self.init(id: id, pixels: PixelSize(width: Int(backing.width), height: Int(backing.height)))
    }
}

extension Wallpaper {

    /// The real desktop: the agent this deployment's runs talk to, the
    /// wallpaper's own domain and directory for the deployment, and every
    /// attached screen.
    public static func desktop(deployment: Deployment = .development) -> Wallpaper {
        let home = WallpaperHome(deployment: deployment)
        // `nil` only for the app's own bundle identifier or the global domain,
        // and this is neither.
        let defaults = UserDefaults(suiteName: home.domain)!
        return Wallpaper(
            source: PictureClient(preferences: MacHostEnvironment(deployment: deployment).preferences),
            directory: home.directory,
            defaults: defaults,
            displays: {
                NSScreen.screens.compactMap { screen in
                    let display = WallpaperDisplay(screen: screen)
                    if display == nil {
                        Log.wallpaper.notice(
                            "wallpaper: skipping \(screen.localizedName, privacy: .public), which has no display identity")
                    }
                    return display
                }
            },
            setDesktop: { file, id in try Self.setDesktop(file, on: id) },
            reported: { id in Self.screen(id).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) } })
    }

    /// The screensaver's rule: the whole photograph, never cropped, enlarged
    /// when it is small. **No `.fillColor`**, so System Settings' colour stays.
    static func fitOptions() -> [NSWorkspace.DesktopImageOptionKey: Any] {
        [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: NSNumber(value: false),
        ]
    }

    private static func screen(_ id: String) -> NSScreen? {
        NSScreen.screens.first { PictureLayerView.identifier(of: $0) == id }
    }

    private static func setDesktop(_ file: URL, on id: String) throws {
        guard let screen = screen(id) else { throw Failure.displayGone(id) }
        try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: fitOptions())
        // What the system says it is showing, when that is not what was just
        // set. It has been measured lagging, so this is a line and not a check.
        let reported = NSWorkspace.shared.desktopImageURL(for: screen)
        if reported?.standardizedFileURL != file.standardizedFileURL {
            Log.wallpaper.notice(
                "wallpaper: set \(file.lastPathComponent, privacy: .public) on \(id, privacy: .public); the system reports \(reported?.lastPathComponent ?? "nothing", privacy: .public)")
        }
    }

    /// Wake, displays, and Spaces. Called once by the host.
    ///
    /// Not session activation, and not reverting a desktop macOS reset on its
    /// own: `PLAN.md`'s *Wallpaper is asserted continuously* is later work.
    public func watchTheSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.woke() }
            })
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reapply(because: "the Space changed") }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reapply(because: "the displays changed") }
            })
    }
}

#endif
