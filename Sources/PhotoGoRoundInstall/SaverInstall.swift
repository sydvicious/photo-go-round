import Foundation

/// Installing the screensaver: what would happen, and then it happening.
///
/// **Two halves on purpose.** `plan(for:)` is a value describing what an install
/// would do, decided from what it is told rather than from what it does;
/// `apply(_:)` performs one. An install is a change to somebody's Mac and most
/// of it cannot be unit-tested, so the line is drawn at the only place it can
/// be: the judgement is testable, the doing is not. `--dry-run` prints a plan
/// and stops.
///
/// Translated from `Scripts/install-saver.sh`, 2026-09-19, which is deleted.
/// `Plans/Xcode - Separate Build and Run.md`, Phase 2.
public enum SaverInstall {

    /// Where installed screensavers live, per user. Never `/Library`: an install
    /// is the owner's, and two people on one Mac keep their own.
    public static let destinationDirectory = URL.homeDirectory
        .appending(path: "Library/Screen Savers")

    /// The hosts that cache a loaded bundle for the life of the process.
    ///
    /// **They have to be stopped or a rebuild runs the previous build**, which
    /// looks exactly like a change that did nothing and cost a debugging round
    /// once already. Stopping them is not the same as stopping something the
    /// owner started: these are macOS's, and they restart on demand.
    public static let hosts = ["legacyScreenSaver", "ScreenSaverEngine"]

    /// What an install would do.
    public struct Plan: Equatable, Sendable {
        /// The bundle to install, as given.
        public var source: URL
        /// Its own name, without the extension.
        ///
        /// **Read from the bundle, never a constant.** Each build configuration
        /// produces a differently named saver — `Photo-Go-Round Screensaver`,
        /// `… (Debug)`, `… (Claude)` — so a fixed name would remove another
        /// configuration's installed saver and then fail to find the one it
        /// copied. Three can sit in Screen Savers at once and each install
        /// replaces only its own.
        public var name: String
        /// Where it lands.
        public var destination: URL
        /// Whether a bundle of this name is already installed.
        public var replacesExisting: Bool
        /// Which hosts are running and would be stopped.
        public var hostsToStop: [String]

        /// One line per thing that would happen, for `--dry-run` and for the
        /// report an install prints as it goes.
        public var describedSteps: [String] {
            var steps: [String] = []
            if replacesExisting {
                steps.append("replace \(destination.path(percentEncoded: false))")
            } else {
                steps.append("install \(destination.path(percentEncoded: false))")
            }
            for host in hostsToStop {
                steps.append("stop \(host), which is holding a previous build")
            }
            if hostsToStop.isEmpty {
                steps.append("no screensaver host is running, so none needs stopping")
            }
            return steps
        }
    }

    /// What the plan needs to know about the machine, so a test can answer for
    /// it without one.
    public struct Surroundings: Sendable {
        public var directoryExists: @Sendable (URL) -> Bool
        public var isRunning: @Sendable (String) -> Bool

        public init(
            directoryExists: @escaping @Sendable (URL) -> Bool,
            isRunning: @escaping @Sendable (String) -> Bool
        ) {
            self.directoryExists = directoryExists
            self.isRunning = isRunning
        }

        public static let live = Surroundings(
            directoryExists: { url in
                var isDirectory: ObjCBool = false
                let there = FileManager.default.fileExists(
                    atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
                return there && isDirectory.boolValue
            },
            isRunning: { name in Shell.pgrepExact(name) }
        )
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noBundle(URL)
        case notASaverBundle(URL)
        case copyDidNotArrive(URL)

        public var description: String {
            switch self {
            case .noBundle(let url):
                "no bundle at \(url.path(percentEncoded: false))"
            case .notASaverBundle(let url):
                "\(url.lastPathComponent) is not a .saver bundle"
            case .copyDidNotArrive(let url):
                "nothing usable arrived at \(url.path(percentEncoded: false))"
            }
        }
    }

    /// What installing `source` would do, without doing any of it.
    public static func plan(
        for source: URL,
        into directory: URL = destinationDirectory,
        surroundings: Surroundings = .live
    ) throws -> Plan {
        guard source.pathExtension == "saver" else { throw Failure.notASaverBundle(source) }
        guard surroundings.directoryExists(source) else { throw Failure.noBundle(source) }

        let name = source.deletingPathExtension().lastPathComponent
        let destination = directory.appending(path: "\(name).saver")
        return Plan(
            source: source,
            name: name,
            destination: destination,
            replacesExisting: surroundings.directoryExists(destination),
            hostsToStop: hosts.filter(surroundings.isRunning)
        )
    }

    /// What is at an installed saver's path, without following a link.
    public enum Installed: Equatable, Sendable {
        case nothing
        /// A symlink, and the path it names.
        case link(to: String)
        /// A real bundle — a copy, as `pgr_install saver` lays down.
        case bundle
    }

    public static func installed(at url: URL) -> Installed {
        let path = url.path(percentEncoded: false)
        let manager = FileManager.default
        guard let type = (try? manager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
        else { return .nothing }
        if type == .typeSymbolicLink {
            return .link(to: (try? manager.destinationOfSymbolicLink(atPath: path)) ?? "")
        }
        return .bundle
    }

    /// Whether this saver is the one installed, as a link to it.
    ///
    /// **An app installs its saver as a symlink back into itself**, never a
    /// copy — Syd, 2026-09-21: "the binaries should NOT be copied out of the
    /// app bundle", and the saver and wallpaper "should lay down symlinks back
    /// to the app bundle". So current means exactly that: a link at this
    /// saver's name, naming this saver. A copy of the same name — what
    /// `pgr_install saver` lays down from a build directory — differs.
    ///
    /// **Measured 2026-09-21: a symlinked saver loads.** Linked from
    /// `~/Library/Screen Savers` into a Claude-built app, it was listed in
    /// System Settings and its preview ran.
    public static func standing(
        of source: URL,
        into directory: URL = destinationDirectory,
        surroundings: Surroundings = .live,
        installed: @Sendable (URL) -> Installed = { SaverInstall.installed(at: $0) }
    ) throws -> Standing {
        let plan = try plan(for: source, into: directory, surroundings: surroundings)
        switch installed(plan.destination) {
        case .nothing:
            return .missing
        case .link(let target) where target == plan.source.path(percentEncoded: false):
            return .current
        case .link(let target):
            return .differs("linked to \(target)")
        case .bundle:
            return .differs("a copy is installed, not a link")
        }
    }

    /// Installs a plan as a symlink to its source, for an app installing the
    /// saver it carries.
    ///
    /// Whatever is at the name goes first — a copy, or a link to another copy
    /// of the app — and **is looked for without following a link**, since a
    /// link into a deleted app dangles and reads as absent to anything that
    /// follows it, and then the new link cannot be made.
    @discardableResult
    public static func applyLink(_ plan: Plan) throws -> [String] {
        var done: [String] = []
        let manager = FileManager.default

        try manager.createDirectory(
            at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if installed(at: plan.destination) != .nothing {
            try manager.removeItem(at: plan.destination)
        }
        try manager.createSymbolicLink(at: plan.destination, withDestinationURL: plan.source)
        guard installed(at: plan.destination) == .link(to: plan.source.path(percentEncoded: false))
        else { throw Failure.copyDidNotArrive(plan.destination) }
        done.append("linked \(plan.name).saver")
        done.append("  \(plan.destination.path(percentEncoded: false)) → \(plan.source.path(percentEncoded: false))")

        for host in plan.hostsToStop where Shell.killall(host) {
            done.append("stopped \(host), which was holding a previous build")
        }
        return done
    }

    /// Performs a plan, returning what it did, a line at a time.
    ///
    /// The copy is verified rather than assumed: a `cp` that silently produced
    /// nothing used to be indistinguishable from an install that worked.
    @discardableResult
    public static func apply(_ plan: Plan) throws -> [String] {
        var done: [String] = []
        let manager = FileManager.default

        try manager.createDirectory(
            at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Not `fileExists`: it follows a link, and a link the app laid down
        // into a since-deleted app would read as absent and block the copy.
        if installed(at: plan.destination) != .nothing {
            try manager.removeItem(at: plan.destination)
        }
        try manager.copyItem(at: plan.source, to: plan.destination)

        var isDirectory: ObjCBool = false
        guard
            manager.fileExists(
                atPath: plan.destination.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw Failure.copyDidNotArrive(plan.destination) }
        done.append("installed \(plan.name).saver")
        done.append("  \(plan.destination.path(percentEncoded: false))")

        for host in plan.hostsToStop where Shell.killall(host) {
            done.append("stopped \(host), which was holding a previous build")
        }
        return done
    }
}
