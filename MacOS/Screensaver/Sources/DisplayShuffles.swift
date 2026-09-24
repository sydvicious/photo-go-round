import Foundation
import OSLog
import PhotosGoRoundAgentAPI
import PhotosGoRoundDisplay

/// One picture loop per display, however many views the host makes.
///
/// **This exists because of what the first Phase 3 run measured.** macOS does
/// not make one `ScreenSaverView` per display and stop there: on 2026-09-08 two
/// views reported the *same* display UUID inside one `legacyScreenSaver`
/// process, both ran their own loop, and deals 29557 through 29562 alternated
/// between them — one screen drawing twice as many photographs from a shared
/// queue as anyone was looking at. `stopAnimation` then reached one of them and
/// not the other.
///
/// Making a view's own `startAnimation` idempotent could never fix that, because
/// the duplication is across views rather than within one. The consumer is the
/// *display*, which is what `PLAN.md` says and what the deck's `(kind,
/// displayID)` identity already assumes, so the loop belongs to the display and
/// the views borrow it.
///
/// Two things fall out for free. A view that appears while another is already
/// running joins the loop mid-flight and inherits the photograph on screen, so
/// there is no black frame at a wake. And a `Shuffle` is never discarded — only
/// stopped — so the picture outlives every view that was showing it.
@MainActor
enum DisplayShuffles {

    private static let log = Logger(subsystem: Log.subsystem, category: "saver")

    /// A display with no identity of its own still gets exactly one loop rather
    /// than one per view, which is the whole point.
    static let unknownDisplay = "unknown"

    private struct Entry {
        let shuffle: Shuffle
        /// How many views are currently showing this display. The loop runs
        /// while this is above zero.
        var views: Int
    }

    private static var entries: [String: Entry] = [:]

    /// Which loop a view on this display belongs to.
    ///
    /// **An unidentified view on a machine with exactly one identified display
    /// is on that display**, and adopting it is the difference between three
    /// views sharing a loop and three views sharing a loop while a fourth runs
    /// its own. Measured 2026-09-08: `9e00` never resolved a screen, kept the
    /// `unknown` key, and spent deals 29692 and 29693 on its own while the other
    /// three shared 29694.
    ///
    /// Resolving live rather than caching fixes a window that lands on a screen
    /// *later*; it does nothing for one that never reports a screen at all, which
    /// is what this is for. Two or more identified displays make the guess
    /// ambiguous, so it is not made.
    ///
    /// It is a guess, and it is a safe one: the worst case is that two views of
    /// one screen share a loop, which is what we want anyway.
    static func effectiveKey(for displayID: String?) -> String {
        if let displayID { return displayID }
        let identified = entries.keys.filter { $0 != unknownDisplay }
        guard identified.count == 1, let sole = identified.first else { return unknownDisplay }
        return sole
    }

    /// The display a key names, or `nil` for the unidentified one — which is
    /// what goes on the wire, so an adopted view asks as the display it adopted
    /// rather than as nobody.
    static func displayID(for key: String) -> String? {
        key == unknownDisplay ? nil : key
    }

    /// The loop for this key, joining one that exists or starting one that
    /// does not.
    static func attach(key: String) -> Shuffle {
        if var entry = entries[key] {
            entry.views += 1
            entries[key] = entry
            log.notice(
                "saver: joined the loop for display \(key, privacy: .public), now \(entry.views, privacy: .public) views")
            return entry.shuffle
        }
        let environment = MacHostEnvironment(deployment: .current)
        reportPort(environment.preferences)
        if key == unknownDisplay {
            log.notice("saver: starting a loop for a view whose display is unidentified")
        }
        let screensaver = ScreensaverPreferences(deployment: .current)
        let shuffle = Shuffle(
            source: PictureClient(preferences: environment.preferences),
            consumer: ConsumerKind.screensaver.rawValue,
            dwellFrom: { Self.interval(from: screensaver).duration },
            memory: PictureMemory(directory: memoryDirectory, key: key))
        entries[key] = Entry(shuffle: shuffle, views: 1)
        log.notice("saver: new loop for display \(key, privacy: .public)")
        return shuffle
    }

    /// Where each display's last picture is kept between sessions. See
    /// `PictureMemory`.
    ///
    /// **Inside the host's container, which every legacy screensaver shares**,
    /// so in a folder named for this bundle. Its identifier differs by build
    /// configuration, which keeps a Debug and a Release saver from opening
    /// with each other's pictures. Caches, because losing it costs only the
    /// picture a session opens with.
    private static let memoryDirectory: URL = {
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let name =
            Bundle(for: PGRScreenSaverView.self).bundleIdentifier ?? "com.sydpolk.photosgoround.saver"
        return caches.appending(path: name, directoryHint: .isDirectory)
    }()

    /// The last reading reported, so a change is one line and an unchanged
    /// read is none — the interval is read before every picture.
    private static var reportedInterval: IntervalReading?

    /// The *Shuffle All* choice, read fresh before every picture so a change in
    /// the app reaches a host that is already running. See `Shuffle.dwell`.
    ///
    /// `via file` means the sandbox refused the domain and the saver read its
    /// `.plist`, as it does for the port.
    private static func interval(from preferences: ScreensaverPreferences) -> ShuffleInterval {
        let reading = preferences.read()
        let fallback = ScreensaverPreferences.defaultInterval
        if reading != reportedInterval {
            reportedInterval = reading
            switch reading {
            case .set(let choice, let origin):
                log.notice(
                    "saver: shuffle interval \(choice.rawValue, privacy: .public) via \(origin.rawValue, privacy: .public)")
            case .unset:
                log.notice("saver: no shuffle interval chosen; using \(fallback.rawValue, privacy: .public)")
            case .unknown(let raw, let origin):
                log.error(
                    "saver: shuffle interval \(raw, privacy: .public) via \(origin.rawValue, privacy: .public) is not one of the choices; using \(fallback.rawValue, privacy: .public)")
            case .unreadable(let reason):
                log.error(
                    "saver: the shuffle interval could not be read — \(reason, privacy: .public); using \(fallback.rawValue, privacy: .public)")
            }
        }
        return reading.choice(default: fallback)
    }

    /// One view has finished with this display. The loop stops when the last of
    /// them does; the `Shuffle` itself stays, holding its photograph.
    static func release(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.views = max(0, entry.views - 1)
        entries[key] = entry
        guard entry.views == 0 else {
            log.notice(
                "saver: released display \(key, privacy: .public), \(entry.views, privacy: .public) views still showing it")
            return
        }
        entry.shuffle.stop()
        log.notice("saver: last view of display \(key, privacy: .public) went; loop stopped, picture kept")
    }

    /// Logged once per loop, because it is the answer to the question the Phase
    /// 1 spike existed to ask and the one that will regress silently when a
    /// macOS release changes what the host is allowed to read.
    ///
    /// `via file` means the sandbox refused the preference domain and the client
    /// recovered by reading the `.plist` directly.
    private static func reportPort(_ preferences: Preferences) {
        switch ServicePort.read(preferences) {
        case .published(let port, let origin):
            log.notice(
                "saver: agent on port \(port, privacy: .public) via \(origin.rawValue, privacy: .public)")
        case .none:
            log.notice("saver: no port published; the agent is not running")
        case .unreadable(let reason):
            log.error("saver: the port could not be read — \(reason, privacy: .public)")
        }
        // **The secret, by the same route, and never its value.** The saver is
        // the one reader that goes through the file, so this is where a secret
        // written but not yet on disk would show. `Plans/Multi-user Support.md`.
        switch ServicePort.readSecret(preferences) {
        case .published(_, let origin):
            log.notice("saver: secret via \(origin.rawValue, privacy: .public)")
        case .none:
            log.notice("saver: no secret published beside the port")
        case .unreadable(let reason):
            log.error("saver: the secret could not be read — \(reason, privacy: .public)")
        }
    }
}
