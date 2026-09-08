import Foundation
import PhotoGoRoundAgentAPI

/// Where the agent is listening, read from a process that may not be allowed to
/// ask the ordinary way.
///
/// **This exists because of one measurement.** The Phase 1 screensaver spike,
/// 2026-09-07: `UserDefaults(suiteName:)` inside `legacyScreenSaver`'s sandbox
/// does not fail, does not return `nil`, and does not throw. It hands back a
/// suite that opens cleanly and holds nothing. So the sandbox's refusal arrives
/// wearing the exact costume of *the agent has published no port* — and a saver
/// written the obvious way reports that the agent is not running while the agent
/// answers `200` on the next line of the same log.
///
/// The whole-filesystem read the host is granted means the `.plist` behind that
/// domain is an ordinary file this process can open, so the fallback is a read
/// rather than a protocol. See `Screensaver Plan.md`, *The question the
/// entitlements do not answer*.
///
/// **It lives beside the client rather than inside `Preferences`.** The agent
/// uses `Preferences` too, and the agent is never sandboxed; teaching the
/// durable configuration store about somebody else's container would put a
/// workaround in the one type every process shares.
public enum ServicePort {

    /// Which route produced the answer. Worth reporting because a value that
    /// came from the file means the suite was refused, which is a fact about
    /// the process rather than about the library.
    public enum Origin: String, Sendable {
        case suite
        case file
    }

    /// What could be learned about the port, which is three things and not two.
    public enum Reading: Equatable, Sendable {
        /// A port, and how it was found.
        case published(UInt16, from: Origin)
        /// Nobody has published one. The agent is not running, or stopped
        /// cleanly and withdrew it.
        case none
        /// A domain exists, something is in the way of reading it, and whether a
        /// port is published is unknown.
        ///
        /// **Deliberately not folded into `none`.** They send somebody to
        /// different places: `none` is fixed by starting the agent, and this is
        /// not fixed by anything the person at the keyboard can do.
        case unreadable(reason: String)
    }

    /// The suite first, the file underneath it.
    ///
    /// **Falling through on empty rather than on failure** is the point: an
    /// empty suite is what a refusal looks like, so there is nothing else to
    /// branch on. The cost is one file read on a genuinely stopped agent, which
    /// happens at the polling interval of a surface that has nothing to draw.
    public static func read(_ preferences: Preferences) -> Reading {
        if let port = preferences.servicePort { return .published(port, from: .suite) }
        guard let url = plistURL(for: preferences) else { return .none }
        return readFile(at: url)
    }

    /// `<path>.plist` for a path-named suite, `~/Library/Preferences/<domain>.plist`
    /// for a dotted one.
    ///
    /// Both spellings are real. `CFPreferences` has always accepted an absolute
    /// path — `defaults read /path/to/file` is the same feature — and the test
    /// suites use one so that nothing lands in the directory `cfprefsd` owns.
    static func plistURL(for preferences: Preferences) -> URL? {
        guard let domain = preferences.domain else { return nil }
        if domain.hasPrefix("/") {
            return URL(filePath: domain).appendingPathExtension("plist")
        }
        return URL(filePath: realHome())
            .appending(path: "Library/Preferences")
            .appending(path: "\(domain).plist")
    }

    static func readFile(at url: URL) -> Reading {
        // A domain nothing ever wrote has no file, and that is *not* a refusal —
        // it is the ordinary state of a machine where the agent has never run.
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .none
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable(reason: error.localizedDescription)
        }
        guard
            let any = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
            let dictionary = any as? [String: Any]
        else {
            return .unreadable(reason: "the preference file would not parse")
        }
        guard let raw = dictionary[Preferences.Key.servicePort.rawValue] as? Int,
            raw > 0, raw <= Int(UInt16.max)
        else {
            return .none
        }
        // **A port read from the file can be stale in a way one read from the
        // suite cannot.** `cfprefsd` buffers, so a port published seconds ago may
        // not be on disk yet, and the agent takes a new one every launch. Nothing
        // is done about it here: the client re-reads on every request and a wrong
        // port surfaces as `unreachable`, which is already the shape of *the
        // agent moved*. See `Screensaver Plan.md`, *Not yet decided*.
        return .published(UInt16(raw), from: .file)
    }

    /// The true home. `NSHomeDirectory()` is rewritten to the container inside a
    /// sandbox, and the container holds none of our preferences; `getpwuid`
    /// reads the password database and is not rewritten. Measured in the Phase 1
    /// spike, where the two differed exactly as expected.
    static func realHome() -> String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return NSHomeDirectory()
        }
        return String(cString: directory)
    }
}
