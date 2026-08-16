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
public enum Log {
    public static let subsystem = "com.sydpolk.photogoround"

    public static let sql = Logger(subsystem: subsystem, category: "sql")
    public static let deck = Logger(subsystem: subsystem, category: "deck")
    public static let cache = Logger(subsystem: subsystem, category: "cache")
    public static let sources = Logger(subsystem: subsystem, category: "sources")
    public static let photos = Logger(subsystem: subsystem, category: "photos")
    public static let prefs = Logger(subsystem: subsystem, category: "prefs")
    public static let wallpaper = Logger(subsystem: subsystem, category: "wallpaper")
    public static let saver = Logger(subsystem: subsystem, category: "saver")
    public static let widget = Logger(subsystem: subsystem, category: "widget")

    /// Intervals go through signposts rather than log lines, so they are
    /// readable in Instruments without a benchmark harness.
    public static let signposter = OSSignposter(subsystem: subsystem, category: "intervals")
}
