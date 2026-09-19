import OSLog

/// Every process in the system logs through here, and nowhere else.
///
/// Unified logging is not merely the zero-dependency choice — it is the only
/// mechanism that works from inside the screensaver's and the widget's
/// sandboxes, where a hand-rolled file logger could not write at all.
///
/// Level determines persistence, so choose deliberately: `.debug` is
/// memory-only and gone by the time you look at it; state transitions worth
/// reconstructing after the fact must be `.notice` or higher.
///
/// Privacy annotations are on by default and that is correct here. File paths,
/// photo filenames, and album names stay private. Structural values — source
/// ids, counts, durations, error codes, deal ordinals — are marked `.public`,
/// because a log full of `<private>` is not a log.
///
/// **The agent's record of what it served is the exception**, public name and
/// source name included, at Syd's direction on 2026-09-12. An installed agent's
/// unified log is the only log it has, and a served line reading
/// `name=<private>` says nothing to the person reading it. The queue's lines —
/// `QueueEvent.report`, which names photographs throughout — were already
/// public whole.
public enum Log {
    /// `com.sydpolk.photogoround`, or `com.sydpolk.photogoround.tests` in a
    /// test run.
    ///
    /// **A test run logs apart. Since 2026-09-16.** Every test wrote under the
    /// agent's subsystem, as `swiftpm-testing-helper`, so `log show` on the Mac
    /// that ran them mixed fake photographs, port 9000 and `test:` consumers in
    /// with the real agent's lines. Syd: "fix that test logging". Everything
    /// that logs names this rather than spelling the string, so one decision
    /// covers the kit, the display module, the app, the saver and the wallpaper.
    public static let subsystem = subsystem(
        forProcess: ProcessInfo.processInfo.processName,
        environment: ProcessInfo.processInfo.environment)

    /// A test run is `swift test`'s helper or `xctest`, or any process Xcode
    /// started to host tests, which it marks with `XCTestConfigurationFilePath`.
    static func subsystem(forProcess name: String, environment: [String: String]) -> String {
        let testing =
            name == "swiftpm-testing-helper" || name == "xctest"
            || environment["XCTestConfigurationFilePath"] != nil
        return testing ? "com.sydpolk.photogoround.tests" : "com.sydpolk.photogoround"
    }

    /// Everything the agent prints on its console, mirrored here because under
    /// launchd its standard output goes nowhere.
    ///
    /// **Its own category rather than borrowed ones.** The mirror holds a
    /// `String` and cannot know whether a line was about a source, a photograph
    /// or the cache, so putting it under `deck` would quietly file source
    /// refreshes and cache walks as deck lines. `category == "console"` names
    /// exactly the set that would have been on standard output, which is the
    /// question somebody reading these is actually asking.
    /// `Plans/Logging.md`, Phase 1.
    public static let console = Logger(subsystem: subsystem, category: "console")
    public static let sql = Logger(subsystem: subsystem, category: "sql")
    public static let deck = Logger(subsystem: subsystem, category: "deck")
    public static let cache = Logger(subsystem: subsystem, category: "cache")
    public static let sources = Logger(subsystem: subsystem, category: "sources")
    public static let photos = Logger(subsystem: subsystem, category: "photos")
    public static let prefs = Logger(subsystem: subsystem, category: "prefs")
    public static let saver = Logger(subsystem: subsystem, category: "saver")
    public static let widget = Logger(subsystem: subsystem, category: "widget")

    /// The level a line that happens on every request is logged at.
    ///
    /// **A release build says less, and this is the whole mechanism.** Syd,
    /// 2026-09-19: the prod versions "should have less than the claude or debug
    /// versions", and "putting in logs while we are investigating is great, but
    /// downgrading them later is essential." `.default` persists to disk and is
    /// therefore the budget; `.info` does not, and comes back with
    /// `log show --info` or `log config` without a rebuild.
    ///
    /// **A Debug or Claude build keeps everything at `.default`**, because that
    /// is the build somebody is watching, and a shorter retention window on a
    /// development machine costs nothing.
    ///
    /// The same compile-time conditions that pick the service port, for the same
    /// reason: build-time identity rather than which library a run opens.
    /// `ServiceAddress`, and `Plans/Logging.md`, Phase 2.
    public static var chatter: OSLogType {
        #if DEBUG || PGR_AGENT_CLAUDE
            .default
        #else
            .info
        #endif
    }

    /// Intervals go through signposts rather than log lines, so they are
    /// readable in Instruments without a benchmark harness.
    public static let signposter = OSSignposter(subsystem: subsystem, category: "intervals")
}

extension Logger {
    /// An error, logged exactly as `error` logs it and recorded in the agent's
    /// error ledger under `kind` — or only logged, when `kind` is nil because
    /// something at the same site already records the event.
    ///
    /// **The message is logged public, whole.** Every error this replaced
    /// already marked each of its values `.public`, so the record in the log is
    /// what it was; the difference is that the words are now a `String` the
    /// ledger can keep. An error whose words must stay private does not belong
    /// here — use `error` and let it go unrecorded.
    public func error(kind: String?, _ message: String, into ledger: AgentErrors = .shared) {
        self.error("\(message, privacy: .public)")
        if let kind { ledger.record(kind: kind, message) }
    }
}
