import Foundation

/// Registering the wallpaper extension: what would happen, and then it
/// happening.
///
/// **The only install here with real judgement in it**, which is why moving it
/// out of shell buys correctness rather than only reach. Deciding which of the
/// Mac's registrations are dead used to be an unreadable `sed` expression and a
/// loop nothing could exercise; it is a pure function with a test now.
///
/// Translated from `Scripts/install-wallpaper-extension.sh`, 2026-09-19.
/// `Plans/Xcode - Separate Build and Run.md`, Phase 4.
public enum WallpaperInstall {

    /// The extension point the extension registers against.
    public static let extensionPoint = "com.apple.wallpaper"

    static let identifierPrefix = "com.sydpolk.photosgoround.wallpaper"
    static let identifierSuffix = ".extension"

    /// One record from `pluginkit -m -D -v`.
    public struct Registration: Equatable, Sendable {
        public var identifier: String
        public var path: String
        /// When `pkd` recorded it. **The registration's own time, not the
        /// bundle's** — measured 2026-09-21: an appex last changed at 03:02:50
        /// read 03:16:48 when registered at 03:16:48, and a later `pluginkit
        /// -a` moved it on. Nil when the line carried none that parsed.
        public var registered: Date?
        public init(identifier: String, path: String, registered: Date? = nil) {
            self.identifier = identifier
            self.path = path
            self.registered = registered
        }
    }

    /// What should happen to a registration that is not this install's own.
    ///
    /// **A registration is dead when its bundle is gone, or when the bundle is
    /// still there but now holds a different identifier.** The second is what a
    /// rebuild at the same path under a new identity leaves behind, as Syd's
    /// Debug build did moving from `…wallpaper.extension` to
    /// `…wallpaper.debug.extension`.
    ///
    /// **Anything else is somebody else's live build and is left alone.** An
    /// earlier version removed every copy sharing the identifier, reasoning that
    /// LaunchServices keeps one record per identifier and the wrong one may
    /// answer. Measured 2026-09-15, that hijacked: a build from one directory
    /// silently unregistered the copy another directory had installed, and the
    /// last build won. It took Syd's registration while an agent was verifying
    /// a target dependency.
    public enum Verdict: Equatable, Sendable {
        /// This very bundle, about to be registered again.
        case ours
        /// Somebody else's, and still real.
        case liveElsewhere
        /// The bundle it named is no longer there.
        case bundleGone
        /// The bundle is there and holds something else now.
        case identifierChanged(nowHolds: String?)

        public var isDead: Bool {
            switch self {
            case .bundleGone, .identifierChanged: true
            case .ours, .liveElsewhere: false
            }
        }
    }

    public struct Judged: Equatable, Sendable {
        public var registration: Registration
        public var verdict: Verdict
    }

    public struct Plan: Equatable, Sendable {
        public var appex: URL
        public var identifier: String
        /// Every Photos-Go-Round wallpaper registration on the Mac, judged.
        public var judged: [Judged]

        public var toRemove: [Registration] {
            judged.filter(\.verdict.isDead).map(\.registration)
        }
        public var toLeave: [Registration] {
            judged.filter { $0.verdict == .liveElsewhere }.map(\.registration)
        }

        public var describedSteps: [String] {
            var steps: [String] = []
            for item in judged {
                switch item.verdict {
                case .ours:
                    continue
                case .liveElsewhere:
                    steps.append("leave another live copy registered: \(item.registration.identifier)")
                    steps.append("  \(item.registration.path)")
                case .bundleGone:
                    steps.append("remove a registration whose bundle is gone: \(item.registration.identifier)")
                    steps.append("  \(item.registration.path)")
                case .identifierChanged(let holds):
                    steps.append(
                        "remove a registration whose bundle now holds \(holds ?? "nothing"): \(item.registration.identifier)")
                    steps.append("  \(item.registration.path)")
                }
            }
            steps.append("stop only this bundle's extension process, if one is running")
            steps.append("register \(identifier)")
            steps.append("  \(appex.path(percentEncoded: false))")
            steps.append("restart WallpaperAgent so the desktop is re-acquired")
            return steps
        }
    }

    public struct Surroundings: Sendable {
        public var directoryExists: @Sendable (URL) -> Bool
        /// What the bundle at this path says its identifier is, now.
        public var identifierAt: @Sendable (String) -> String?
        public var registrations: @Sendable () -> [Registration]
        /// When the appex's executable last changed — its `ctime`, which a copy
        /// of the app into place always moves. `CodeIdentity.changedAt`.
        public var changedAt: @Sendable (URL) -> Date?

        public init(
            directoryExists: @escaping @Sendable (URL) -> Bool,
            identifierAt: @escaping @Sendable (String) -> String?,
            registrations: @escaping @Sendable () -> [Registration],
            changedAt: @escaping @Sendable (URL) -> Date? = { _ in nil }
        ) {
            self.directoryExists = directoryExists
            self.identifierAt = identifierAt
            self.registrations = registrations
            self.changedAt = changedAt
        }

        public static let live = Surroundings(
            directoryExists: { url in
                var isDirectory: ObjCBool = false
                let there = FileManager.default.fileExists(
                    atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
                return there && isDirectory.boolValue
            },
            identifierAt: { path in PluginKit.identifier(ofBundleAt: path) },
            registrations: { PluginKit.registrations(for: extensionPoint) },
            changedAt: { appex in
                (Bundle(url: appex)?.executableURL).flatMap(CodeIdentity.changedAt)
            }
        )
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noBundle(URL)
        case notOurExtension(URL, read: String?)
        case didNotRegister(String, at: URL)
        case didNotUnregister(String, at: URL)

        public var description: String {
            switch self {
            case .noBundle(let url):
                "no bundle at \(url.path(percentEncoded: false))"
            case .notOurExtension(let url, let read):
                """
                \(url.lastPathComponent) has no Photos-Go-Round wallpaper identifier \
                (read "\(read ?? "")")
                """
            case .didNotRegister(let identifier, let url):
                """
                \(identifier) did not register from \(url.path(percentEncoded: false)) in time
                  pkd logs the reason: /usr/bin/log show --last 5m --predicate 'process == "pkd"'
                """
            case .didNotUnregister(let identifier, let url):
                "\(identifier) was still registered from \(url.path(percentEncoded: false)) after pluginkit -r"
            }
        }
    }

    /// **`pluginkit -a` returns before `pkd` has written the record** — measured
    /// 2026-09-15, where an immediate check found nothing and the same check
    /// seconds later found it. Run from a build it is slower still: an install
    /// that verified first time from a terminal took longer than ten seconds
    /// while Xcode was finishing.
    public static let registrationTimeout = Duration.seconds(30)

    public static func plan(
        for appex: URL,
        surroundings: Surroundings = .live
    ) throws -> Plan {
        guard surroundings.directoryExists(appex) else { throw Failure.noBundle(appex) }
        let identifier = surroundings.identifierAt(appex.path(percentEncoded: false))
        guard let identifier, isOurs(identifier) else {
            throw Failure.notOurExtension(appex, read: identifier)
        }

        let ourPath = appex.path(percentEncoded: false)
        let judged = surroundings.registrations()
            .filter { isOurs($0.identifier) }
            .map { registration in
                Judged(
                    registration: registration,
                    verdict: verdict(
                        for: registration, ourIdentifier: identifier, ourPath: ourPath,
                        identifierAt: surroundings.identifierAt))
            }
        return Plan(appex: appex, identifier: identifier, judged: judged)
    }

    /// Whether this appex is the one registered for its identifier.
    ///
    /// **Current only when registered from this very path, since the appex
    /// last changed.** The app carries it in `Contents/Library/Wallpaper`,
    /// where LaunchServices does not look, so nothing registers it but an
    /// install. Registered from anywhere else is another copy of the app, or a
    /// dead one, and `plan` already knows which of those to remove.
    ///
    /// **An app replaced at the same path leaves the registration pointing at
    /// the right place and describing the old bundle.** Syd, 2026-09-21, for
    /// an install over an existing one: "unregister the extension, re-register
    /// the extension, tickle Wallpaper agent". A registration older than the
    /// appex's executable is that case. One whose date or `ctime` cannot be
    /// read is taken as current: re-registering restarts `WallpaperAgent`,
    /// which is visible, and doing it on every launch would be worse.
    public static func standing(
        of appex: URL,
        surroundings: Surroundings = .live
    ) throws -> Standing {
        let plan = try plan(for: appex, surroundings: surroundings)
        if let ours = plan.judged.first(where: { $0.verdict == .ours }) {
            if let registered = ours.registration.registered,
                let changed = surroundings.changedAt(appex), changed > registered
            {
                return .stale("replaced since it was registered")
            }
            return .current
        }
        let elsewhere = plan.judged.map(\.registration)
            .filter { $0.identifier == plan.identifier }
        guard let other = elsewhere.first else { return .missing }
        return .differs("registered from \(other.path)")
    }

    /// Where `WallpaperAgent` keeps what each display and space shows.
    public static let store = URL.homeDirectory
        .appending(path: "Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    /// Whether the wallpaper somebody chose is this extension.
    ///
    /// **Why a launch needs to know.** Measured 2026-09-21: rebuilding the app
    /// made `pkd` drop the extension's registration altogether, and
    /// `WallpaperAgent` kept the choice and showed grey. Syd: "yes, re-register
    /// it in any build" — so a launch registers again when the registration is
    /// gone but the choice is still this extension.
    ///
    /// **The store's format is private.** Read that day, the choice sat at
    /// `AllSpacesAndDisplays / Desktop / Content / Choices / [n] / Provider`
    /// and the same under `SystemDefault`; `Spaces` and `Displays` hold
    /// per-space and per-display choices. So any `Provider` equal to the
    /// identifier, anywhere in it, counts. A store that cannot be read or parsed
    /// counts as not chosen: a registration nobody asked for is the worse
    /// mistake.
    public static func isChosen(_ identifier: String, store data: Data?) -> Bool {
        guard let data,
            let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return false }
        func names(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                if dictionary["Provider"] as? String == identifier { return true }
                return dictionary.values.contains(where: names)
            }
            if let array = value as? [Any] { return array.contains(where: names) }
            return false
        }
        return names(root)
    }

    /// A wallpaper extension process that is running, and what it runs.
    public struct Running: Equatable, Sendable {
        public var pid: Int32
        /// The appex its executable sits in.
        public var appex: String
        public var started: Date?

        public init(pid: Int32, appex: String, started: Date?) {
            self.pid = pid
            self.appex = appex
            self.started = started
        }
    }

    /// The executable inside the appex, and the name every configuration's
    /// extension process has.
    static let executableName = "Photos-Go-Round Wallpaper"

    /// Every Photos-Go-Round wallpaper extension process on the Mac, of any
    /// configuration, with the appex it runs from.
    public static func runningExtensions() -> [Running] {
        let marker = ".appex/Contents/MacOS/\(executableName)"
        let found = Shell.run("/usr/bin/pgrep", ["-f", marker])
        guard found.status == 0 else { return [] }
        return found.output.split(separator: "\n").compactMap { line in
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else { return nil }
            let path = Shell.run("/bin/ps", ["-o", "comm=", "-p", String(pid)]).output
            guard let end = path.range(of: ".appex/Contents/MacOS/") else { return nil }
            let appex = String(path[path.startIndex..<end.lowerBound]) + ".appex"
            return Running(pid: pid, appex: appex, started: CodeIdentity.startedAt(pid))
        }
    }

    /// Why a running extension of this appex's identifier is not this appex,
    /// or nil when every one that is running is.
    ///
    /// Syd, 2026-09-21: "we are going to have to detect whether or not the
    /// wallpaper agent that is running matches the one in the app bundle". Two
    /// ways not to: it runs from somewhere else — another copy of the app — or
    /// it runs from here and started before the appex last changed, which is an
    /// app replaced under a running extension. **Another configuration's
    /// process is not this one's business** and is passed over.
    ///
    /// A start or change time that cannot be read counts as a mismatch: the
    /// cost is one re-registration, which Syd called "not a disaster".
    public static func mismatch(
        of appex: URL,
        running: [Running],
        surroundings: Surroundings = .live
    ) -> String? {
        let ourPath = appex.path(percentEncoded: false)
        guard let ours = surroundings.identifierAt(ourPath) else { return nil }
        for process in running where surroundings.identifierAt(process.appex) == ours {
            if process.appex != ourPath {
                return "pid \(process.pid) runs from \(process.appex)"
            }
            guard let started = process.started, let changed = surroundings.changedAt(appex) else {
                return "could not tell when pid \(process.pid) started or its appex changed"
            }
            if changed > started {
                return "pid \(process.pid) started before its appex was replaced"
            }
        }
        return nil
    }

    /// Whether an identifier is one of this project's wallpaper extensions,
    /// whichever build configuration made it.
    static func isOurs(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix) && identifier.hasSuffix(identifierSuffix)
    }

    static func verdict(
        for registration: Registration,
        ourIdentifier: String,
        ourPath: String,
        identifierAt: (String) -> String?
    ) -> Verdict {
        if registration.identifier == ourIdentifier && registration.path == ourPath { return .ours }
        let holds = identifierAt(registration.path)
        if holds == registration.identifier { return .liveElsewhere }
        if holds == nil { return .bundleGone }
        return .identifierChanged(nowHolds: holds)
    }

    /// `pluginkit -m -D -v` prints one record per line: `identifier(version)`, a
    /// UUID, a date whose own fields vary, then the path.
    ///
    /// **Counting fields gets the date wrong** — measured, it left `+0000 `
    /// glued to the front of the path. So the identifier is everything before
    /// the first `(` and the path is everything from the first `/`, which is
    /// unambiguous because a bundle path is absolute and nothing before it
    /// contains a slash.
    /// `2026-09-19 22:07:04 +0000`, as `pluginkit -v` prints it.
    static let registrationDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    public static func parseRegistrations(_ output: String) -> [Registration] {
        output.split(separator: "\n").compactMap { line in
            guard let openParen = line.firstIndex(of: "("),
                let firstSlash = line.firstIndex(of: "/"),
                firstSlash > openParen
            else { return nil }
            let identifier = line[line.startIndex..<openParen]
                .trimmingCharacters(in: .whitespaces)
            let path = String(line[firstSlash...]).trimmingCharacters(in: .whitespaces)
            guard !identifier.isEmpty, !path.isEmpty else { return nil }
            // The date is the tab-separated field just before the path.
            let date = line[line.startIndex..<firstSlash]
                .split(separator: "\t").last
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { registrationDate.date(from: $0) }
            return Registration(identifier: identifier, path: path, registered: date)
        }
    }

    @discardableResult
    public static func apply(
        _ plan: Plan,
        timeout: Duration = registrationTimeout,
        report: (String) -> Void = { _ in }
    ) throws -> [String] {
        var done: [String] = []

        for item in plan.judged {
            switch item.verdict {
            case .ours:
                continue
            case .liveElsewhere:
                done.append("leaving another live copy registered")
                done.append("  \(item.registration.identifier)  \(item.registration.path)")
            case .bundleGone:
                PluginKit.remove(item.registration.path)
                done.append("removed a registration whose bundle is gone")
                done.append("  \(item.registration.identifier)  \(item.registration.path)")
            case .identifierChanged(let holds):
                PluginKit.remove(item.registration.path)
                done.append("removed a registration whose bundle now holds \(holds ?? "nothing")")
                done.append("  \(item.registration.identifier)  \(item.registration.path)")
            }
        }

        // A suspended extension process keeps answering after a rebuild, which
        // cost a debugging round during the probes. **Only this bundle's**:
        // every configuration's process has the same name, so a kill by name
        // would stop another build's wallpaper too.
        Shell.run("/usr/bin/pkill", ["-f", plan.appex.path(percentEncoded: false) + "/Contents/MacOS/"])

        // **Over an existing registration of this very bundle, unregister
        // first.** Syd, 2026-09-21: "unregister the extension, re-register the
        // extension, tickle Wallpaper agent". And wait for the record to go:
        // `pluginkit -r` returns before `pkd` acts, just as `-a` does, and the
        // check below would otherwise find the old record and call it done.
        if plan.judged.contains(where: { $0.verdict == .ours }) {
            PluginKit.remove(plan.appex.path(percentEncoded: false))
            guard try waitForRegistration(plan, toBe: false, timeout: timeout, report: report) else {
                throw Failure.didNotUnregister(plan.identifier, at: plan.appex)
            }
            done.append("unregistered \(plan.identifier), to register it again")
        }

        PluginKit.add(plan.appex)

        guard try waitForRegistration(plan, toBe: true, timeout: timeout, report: report) else {
            throw Failure.didNotRegister(plan.identifier, at: plan.appex)
        }
        done.append("registered \(plan.identifier)")
        done.append("  \(plan.appex.path(percentEncoded: false))")

        // **WallpaperAgent does not re-acquire the desktop from the new process
        // on its own** — measured 2026-09-16: the extension was killed above,
        // the desktop went dark grey, and stayed that way until another
        // wallpaper was chosen and this one chosen again. Restarted, the agent
        // comes back under launchd and re-acquires every surface from the store.
        if Shell.killall("WallpaperAgent") { done.append("restarted WallpaperAgent") }
        return done
    }

    /// Polls until `pkd` has, or no longer has, this bundle's record.
    static func waitForRegistration(
        _ plan: Plan,
        toBe wanted: Bool,
        timeout: Duration,
        report: (String) -> Void,
        registrations: () -> [Registration] = { PluginKit.registrations(for: extensionPoint) }
    ) throws -> Bool {
        let ourPath = plan.appex.path(percentEncoded: false)
        func isThere() -> Bool {
            registrations().contains(where: { $0.identifier == plan.identifier && $0.path == ourPath })
        }
        let deadline = ContinuousClock.now + timeout
        var seconds = 0
        while ContinuousClock.now < deadline {
            if isThere() == wanted { return true }
            Thread.sleep(forTimeInterval: 1)
            seconds += 1
            if seconds % 5 == 0 { report("waiting for pkd, \(seconds)s") }
        }
        return isThere() == wanted
    }
}
