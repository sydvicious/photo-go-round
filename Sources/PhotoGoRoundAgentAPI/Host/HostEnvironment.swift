import Foundation

/// Everything that differs between the platforms and the surfaces the kit runs
/// inside.
///
/// The kit owns policy; the hosts own scheduling and storage. There are no
/// timers here, no run loop, and no opinion about when anything is called — the
/// Mac agent drives it from a continuous loop, an iOS widget will drive it from
/// a timeline provider, and the enormous difference between those two lives
/// entirely on this side of the boundary.
///
/// The kit never constructs a path from a hardcoded root. That is what lets the
/// same code run against `~/Library/Application Support`, an App Group
/// container, and — if the Phase 6 spike needs it — the `legacyScreenSaver`
/// container, without knowing which it got.
public protocol HostEnvironment: Sendable {
    var databaseURL: URL { get }
    var cacheRoot: URL { get }
    var preferences: Preferences { get }

    /// Tells the other processes to go look. Darwin notifications on the Mac,
    /// `WidgetCenter.reloadTimelines` on iOS: same method, unrelated
    /// implementations.
    func announce(_ topic: DarwinNotification.Topic)

    /// This library's bells, scoped so that another library's do not ring here.
    var doorbells: DarwinNotification.Doorbells { get }
}

/// Which library a run is talking to.
///
/// **Development is the default, and that is deliberate.** Running the binary
/// with no arguments cannot touch a real library: it writes into `.build`, which
/// is gitignored and is already the directory you delete for a clean slate.
/// Reaching the real one takes `--prod`, typed on purpose.
///
/// The inverse default would make every casual `swift run` one typo away from a
/// library that took hours to fetch, and every test of a delete path a live-fire
/// exercise.
public enum Deployment: String, Sendable {
    case development
    case production

    /// The bundle identifier, which is also the preference domain and the last
    /// path component of both production directories.
    static let identifier = "com.sydpolk.photogoround"

    /// The database's name inside the storage root, in every deployment. Public
    /// because the hosts name it in their usage text as well as opening it.
    public static let databaseFilename = "photogoround.sqlite"
}

/// Where the storage root came from, so that it is never a mystery.
public enum ContainerOrigin: String, Sendable {
    /// A `--container` or `--database` flag.
    case explicitOverride = "explicit override"
    /// `PGR_CONTAINER` or `PGR_DATABASE`, which is how a launchd plist pins the
    /// roots without touching the command line.
    case environment
    /// `--prod`: `~/Library/Containers`, alongside `~/Library/Caches` and the
    /// real preference domain.
    case production
    /// The default: two directories under the repository's `.build`.
    case development = "development (.build)"
}

/// The Mac agent's environment.
public struct MacHostEnvironment: HostEnvironment {
    public let databaseURL: URL
    public let cacheRoot: URL
    public let preferences: Preferences
    /// Which rung of the ladder supplied the roots. Logged at `.notice` on
    /// startup, because "why is it writing there" should never need a debugger.
    public let origin: ContainerOrigin
    /// Whether `PGR_PREFS_SUITE` named the preference domain, rather than it
    /// following from the deployment.
    ///
    /// **The third thing `--container` does not move.** A caller that relocated
    /// the storage has to know whether the preferences came with it before it
    /// writes anything to them — see `RunCommand.mayWriteFoldersThrough`.
    public let preferencesArePinned: Bool
    public let doorbells: DarwinNotification.Doorbells

    /// User-facing name, hyphenated. The hyphens never appear in an identifier.
    public static let directoryName = "Photo-Go-Round"

    /// Which library this run is talking to.
    public let deployment: Deployment

    public init(
        deployment: Deployment = .development,
        containerOverride: URL? = nil,
        databaseOverride: URL? = nil,
        cacheOverride: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = nil
    ) {
        self.deployment = deployment
        let resolved = Self.resolveContainer(
            deployment: deployment,
            override: containerOverride,
            environment: environment,
            executableURL: executableURL
        )
        origin = resolved.origin

        databaseURL =
            databaseOverride
            ?? environment["PGR_DATABASE"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? resolved.container.appending(path: Deployment.databaseFilename)

        cacheRoot =
            cacheOverride
            ?? environment["PGR_CACHE"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? Self.defaultCacheRoot(
                deployment: deployment, container: resolved.container, origin: resolved.origin)

        // Preferences move with the deployment, and this is the part that is
        // not deducible: relocating the storage root does *not* relocate them,
        // so a run that pointed only the container at scratch space would still
        // read and write the real source list. Two of the three are obviously
        // per-deployment and the third silently is not, which is exactly why one
        // flag moves all three.
        // Keyed on the database rather than the container: the two can be
        // pointed apart, and the library a process belongs to is the one it has
        // open.
        doorbells = DarwinNotification.Doorbells(database: databaseURL)

        let pinnedDomain = environment["PGR_PREFS_SUITE"].flatMap { $0.isEmpty ? nil : $0 }
        preferencesArePinned = pinnedDomain != nil
        var resolvedPreferences = Preferences(
            suiteName: pinnedDomain ?? Self.preferenceDomain(for: deployment)
        )
        resolvedPreferences.doorbells = doorbells
        preferences = resolvedPreferences
    }

    /// Flags beat environment beats App Group beats Application Support.
    ///
    /// A launchd plist sets environment variables far more naturally than it
    /// sets argv, so the production roots can be pinned there while a
    /// development run relocates everything with one flag — which is the whole
    /// point: a background service should never be tied to one path on one
    /// machine.
    static func resolveContainer(
        deployment: Deployment,
        override: URL?,
        environment: [String: String],
        executableURL: URL? = nil
    ) -> (container: URL, origin: ContainerOrigin) {
        if let override {
            return (override, .explicitOverride)
        }
        if let fromEnvironment = environment["PGR_CONTAINER"], !fromEnvironment.isEmpty {
            return (URL(filePath: fromEnvironment), .environment)
        }
        switch deployment {
        case .production:
            return (
                URL.homeDirectory.appending(path: "Library/Containers/\(Deployment.identifier)"),
                .production
            )
        case .development:
            return (buildDirectory(executableURL: executableURL).appending(path: "pgr-container"),
                .development)
        }
    }

    static func defaultCacheRoot(
        deployment: Deployment, container: URL, origin: ContainerOrigin
    ) -> URL {
        // An explicit container takes the cache with it, because somebody who
        // named one directory means both. Otherwise the deployment decides, and
        // the two land in genuinely different places.
        guard origin == .production || origin == .development else {
            return container.appending(path: "cache")
        }
        return switch deployment {
        case .production:
            URL.homeDirectory.appending(path: "Library/Caches/\(Deployment.identifier)")
        case .development:
            buildDirectory(executableURL: nil).appending(path: "pgr-cache")
        }
    }

    static func preferenceDomain(for deployment: Deployment) -> String {
        switch deployment {
        case .production: Deployment.identifier
        case .development: "\(Deployment.identifier).dev"
        }
    }

    /// Where this file was compiled from, which is the one thing a development
    /// build always knows about its own checkout. Evaluated here rather than as
    /// a defaulted argument so it names *this* file no matter who calls.
    private static let sourceFilePath = #filePath

    /// The repository's `.build`, found by walking up from the executable.
    ///
    /// A SwiftPM binary lives at `<repo>/.build/<triple>/<config>/photogoroundd`,
    /// so the directory is right there in its own path — which means a
    /// development run finds it whether it was started by `swift run`, by the
    /// wrapper script, or by hand.
    ///
    /// **Xcode is the case that path cannot cover.** It builds into DerivedData,
    /// which is nowhere near the checkout, so the walk finds nothing and the old
    /// fallback — the working directory — resolved to `/.build` and failed on a
    /// read-only volume. Debugging the agent in Xcode has to work without a
    /// scheme argument, so the second rung is the source tree this binary was
    /// compiled from: `#filePath` is a compile-time constant pointing into the
    /// checkout, which is exactly the right answer for a development default and
    /// is never consulted for `--prod`.
    static func buildDirectory(executableURL: URL?) -> URL {
        var url = executableURL ?? URL(filePath: CommandLine.arguments.first ?? "").standardizedFileURL
        while url.pathComponents.count > 1 {
            if url.lastPathComponent == ".build" { return url }
            url = url.deletingLastPathComponent()
        }

        var source = URL(filePath: sourceFilePath).deletingLastPathComponent()
        while source.pathComponents.count > 1 {
            let manifest = source.appending(path: "Package.swift")
            if FileManager.default.fileExists(atPath: manifest.path(percentEncoded: false)) {
                return source.appending(path: ".build")
            }
            source = source.deletingLastPathComponent()
        }

        // A binary copied away from both, with the checkout gone. "Wherever you
        // are standing" is the only honest answer left.
        return URL(filePath: FileManager.default.currentDirectoryPath).appending(path: ".build")
    }

    public func announce(_ topic: DarwinNotification.Topic) {
        doorbells.post(topic)
    }

    /// Creates the directories the agent is about to write into, and says where
    /// they are.
    public func prepare() throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        Log.prefs.notice(
            "storage root from \(origin.rawValue, privacy: .public); database \(databaseURL.path(percentEncoded: false), privacy: .private)"
        )
    }
}
