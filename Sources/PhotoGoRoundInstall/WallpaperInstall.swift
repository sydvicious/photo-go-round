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

    static let identifierPrefix = "com.sydpolk.photogoround.wallpaper"
    static let identifierSuffix = ".extension"

    /// One record from `pluginkit -m -D -v`.
    public struct Registration: Equatable, Sendable {
        public var identifier: String
        public var path: String
        public init(identifier: String, path: String) {
            self.identifier = identifier
            self.path = path
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
        /// Every Photo-Go-Round wallpaper registration on the Mac, judged.
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

        public init(
            directoryExists: @escaping @Sendable (URL) -> Bool,
            identifierAt: @escaping @Sendable (String) -> String?,
            registrations: @escaping @Sendable () -> [Registration]
        ) {
            self.directoryExists = directoryExists
            self.identifierAt = identifierAt
            self.registrations = registrations
        }

        public static let live = Surroundings(
            directoryExists: { url in
                var isDirectory: ObjCBool = false
                let there = FileManager.default.fileExists(
                    atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
                return there && isDirectory.boolValue
            },
            identifierAt: { path in PluginKit.identifier(ofBundleAt: path) },
            registrations: { PluginKit.registrations(for: extensionPoint) }
        )
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noBundle(URL)
        case notOurExtension(URL, read: String?)
        case didNotRegister(String, at: URL)

        public var description: String {
            switch self {
            case .noBundle(let url):
                "no bundle at \(url.path(percentEncoded: false))"
            case .notOurExtension(let url, let read):
                """
                \(url.lastPathComponent) has no Photo-Go-Round wallpaper identifier \
                (read "\(read ?? "")")
                """
            case .didNotRegister(let identifier, let url):
                """
                \(identifier) did not register from \(url.path(percentEncoded: false)) in time
                  pkd logs the reason: /usr/bin/log show --last 5m --predicate 'process == "pkd"'
                """
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
            return Registration(identifier: identifier, path: path)
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

        PluginKit.add(plan.appex)

        guard try waitForRegistration(plan, timeout: timeout, report: report) else {
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

    static func waitForRegistration(
        _ plan: Plan,
        timeout: Duration,
        report: (String) -> Void,
        registrations: () -> [Registration] = { PluginKit.registrations(for: extensionPoint) }
    ) throws -> Bool {
        let ourPath = plan.appex.path(percentEncoded: false)
        let deadline = ContinuousClock.now + timeout
        var seconds = 0
        while ContinuousClock.now < deadline {
            if registrations().contains(
                where: { $0.identifier == plan.identifier && $0.path == ourPath })
            {
                return true
            }
            Thread.sleep(forTimeInterval: 1)
            seconds += 1
            if seconds % 5 == 0 { report("waiting for pkd, \(seconds)s") }
        }
        return registrations().contains(
            where: { $0.identifier == plan.identifier && $0.path == ourPath })
    }
}
