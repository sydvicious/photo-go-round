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
/// **Which one a run uses is the build's, since 2026-09-24.** A Release agent is
/// production however it is started — Syd: "a release build should always
/// install and use a release agent, period, no matter how it is launched." A
/// Debug or Claude agent is development unless given `--prod`, so running a
/// development build with no arguments still cannot touch a real library: every
/// casual run, and every test of a delete path, lands in a container of its own.
/// `Deployment.current`.
///
/// **Both deployments live under the user's home directory, since 2026-09-19.**
/// Syd: "all of the datafiles have to run in the users home directory so that
/// this will work for two different users on the same machine." Development
/// wrote into `<repo>/.build` until then, which two users sharing a checkout
/// would have shared — and which was not a generated-artifacts directory at all.
/// `pgr_ctl` is the exception to the default: it is never shipped, and defaults
/// to production so it can be pointed at any configuration.
public enum Deployment: String, Sendable {
    case development
    case production

    /// The deployment this build's app, screensaver and installed agent share:
    /// production in a Release build, development in Debug and Claude.
    ///
    /// **Since 2026-09-23, for the first Developer ID build.** Syd: "switch
    /// Release to production." Until then every surface asked for
    /// `.development` by name, so a Release handed to somebody else would have
    /// kept its settings and library under the development names, and moving
    /// them later would have lost them. The agent's own default is unchanged —
    /// a bare run is still development — and its installed plist passes
    /// `--prod` when this is `.production`. `JobDescription`.
    public static let current: Deployment = BuildVariant.current == .release ? .production : .development

    /// The bundle identifier, which is also the preference domain and the last
    /// path component of both production directories.
    ///
    /// Public so the wallpaper's own domains are spelled from this rather than
    /// from a second copy of it — see `WallpaperPreferences`.
    public static let identifier = "com.sydpolk.photosgoround"

    /// The database's name inside the storage root, in every deployment. Public
    /// because the hosts name it in their usage text as well as opening it.
    public static let databaseFilename = "photosgoround.sqlite"

    /// The identifier that names this build's storage — its container, its
    /// cache and its preference domain — which is the bundle identifier plus
    /// the build variant's suffix.
    ///
    /// **Not the bundle identifier.** That stays one value across all three
    /// configurations because TCC grants hang off it, and Syd, 2026-09-19,
    /// asked for Photos to be answered once rather than once per build. This is
    /// the other half of the same decision: the three can run at the same time,
    /// so they cannot share one database. `BuildVariant.swift`.
    /// Defaults to the build that is asking. `pgr_ctl` passes another — it is
    /// never shipped, and Syd, 2026-09-19: "it should be able to completely
    /// control any of the three configurations."
    public static func storageIdentifier(for variant: BuildVariant = .current) -> String {
        identifier + variant.identifierSuffix
    }
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
    /// The default: a development container and cache beside the production
    /// pair, under the user's own `~/Library`.
    case development
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
    public static let directoryName = "Photos-Go-Round"

    /// Which library this run is talking to.
    public let deployment: Deployment

    public init(
        deployment: Deployment = .development,
        variant: BuildVariant = .current,
        containerOverride: URL? = nil,
        databaseOverride: URL? = nil,
        cacheOverride: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.deployment = deployment
        let resolved = Self.resolveContainer(
            deployment: deployment,
            override: containerOverride,
            environment: environment,
            variant: variant
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
                deployment: deployment, container: resolved.container, origin: resolved.origin,
                variant: variant)

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
            suiteName: pinnedDomain ?? Self.preferenceDomain(for: deployment, variant: variant)
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
        variant: BuildVariant = .current
    ) -> (container: URL, origin: ContainerOrigin) {
        if let override {
            return (override, .explicitOverride)
        }
        if let fromEnvironment = environment["PGR_CONTAINER"], !fromEnvironment.isEmpty {
            return (URL(filePath: fromEnvironment), .environment)
        }
        // One directory name for all three of container, cache and preference
        // domain, so a person reading any of them can find the other two.
        let name = preferenceDomain(for: deployment, variant: variant)
        return (
            URL.homeDirectory.appending(path: "Library/Containers/\(name)"),
            deployment == .production ? .production : .development
        )
    }

    static func defaultCacheRoot(
        deployment: Deployment, container: URL, origin: ContainerOrigin,
        variant: BuildVariant = .current
    ) -> URL {
        // An explicit container takes the cache with it, because somebody who
        // named one directory means both. Otherwise the deployment decides, and
        // the two land in genuinely different places.
        guard origin == .production || origin == .development else {
            return container.appending(path: "cache")
        }
        return URL.homeDirectory.appending(
            path: "Library/Caches/\(preferenceDomain(for: deployment, variant: variant))")
    }

    /// The preference domain, which also names the container and cache
    /// directories. Public so that the surfaces — the screensaver, the wallpaper
    /// extension — reach the agent's domain through this rather than spelling it
    /// again.
    public static func preferenceDomain(
        for deployment: Deployment, variant: BuildVariant = .current
    ) -> String {
        let identifier = Deployment.storageIdentifier(for: variant)
        return switch deployment {
        case .production: identifier
        case .development: "\(identifier).dev"
        }
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
