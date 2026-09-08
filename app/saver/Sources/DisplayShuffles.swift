import Foundation
import OSLog
import PhotoGoRoundAgentAPI
import PhotoGoRoundDisplay

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

    private static let log = Logger(subsystem: "com.sydpolk.photogoround", category: "saver")

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

    static func key(for displayID: String?) -> String { displayID ?? unknownDisplay }

    /// The loop for this display, joining one that exists or starting one that
    /// does not.
    static func attach(displayID: String?) -> Shuffle {
        let key = key(for: displayID)
        if var entry = entries[key] {
            entry.views += 1
            entries[key] = entry
            log.notice(
                "saver: joined the loop for display \(key, privacy: .public), now \(entry.views, privacy: .public) views")
            return entry.shuffle
        }
        let environment = MacHostEnvironment(deployment: .development)
        reportPort(environment.preferences)
        let shuffle = Shuffle(
            source: PictureClient(preferences: environment.preferences),
            consumer: ConsumerKind.screensaver.rawValue)
        entries[key] = Entry(shuffle: shuffle, views: 1)
        log.notice("saver: new loop for display \(key, privacy: .public)")
        return shuffle
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
    }
}
