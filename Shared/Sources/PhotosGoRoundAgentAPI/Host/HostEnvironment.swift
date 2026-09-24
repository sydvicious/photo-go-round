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

/// Where a build keeps what is its own: one name, used for its container, its
/// cache and its preference domain.
///
/// **One set per build, and no other.** Syd, 2026-09-24: "They should be
/// completely separate builds with completely separate assets", after "a
/// release build should always install and use a release agent, period, no
/// matter how it is launched." Release, Debug and Claude each have exactly one
/// library — `com.sydpolk.photosgoround`, `….debug`, `….claude` — and no flag,
/// launch path or environment reaches another's. Until then a second axis,
/// development and production, sat inside every build: a `.dev` library beside
/// the real one, and `--prod` choosing between them.
///
/// **Under the user's home directory, since 2026-09-19.** Syd: "all of the
/// datafiles have to run in the users home directory so that this will work for
/// two different users on the same machine."
public enum Storage {
    /// The bundle identifier, and the root every build's storage name grows
    /// from. Public so the surfaces' own domains are spelled from this rather
    /// than from a second copy of it — see `WallpaperPreferences`.
    public static let identifier = "com.sydpolk.photosgoround"

    /// The database's name inside the storage root. Public because the hosts
    /// name it in their usage text as well as opening it.
    public static let databaseFilename = "photosgoround.sqlite"

    /// The name of a build's storage — its container, its cache and its
    /// preference domain — which is the bundle identifier plus the build
    /// variant's suffix.
    ///
    /// **Not the bundle identifier.** That stays one value across all three
    /// configurations because TCC grants hang off it, and Syd, 2026-09-19,
    /// asked for Photos to be answered once rather than once per build. This is
    /// the other half of the same decision: the three can run at the same time,
    /// so they cannot share one database. `BuildVariant.swift`.
    ///
    /// Defaults to the build that is asking. `pgr_ctl` passes another — it is
    /// never shipped, and Syd, 2026-09-19: "it should be able to completely
    /// control any of the three configurations."
    public static func name(for variant: BuildVariant = .current) -> String {
        identifier + variant.identifierSuffix
    }
}

/// Where the storage root came from, so that it is never a mystery.
public enum ContainerOrigin: String, Sendable {
    /// A `--container` or `--database` flag.
    case explicitOverride = "explicit override"
    /// `PGR_CONTAINER` or `PGR_DATABASE`, which pins the roots without touching
    /// the command line.
    case environment
    /// The build's own: `~/Library/Containers/<name>`, beside
    /// `~/Library/Caches/<name>` and the preference domain `<name>`.
    case build = "the build's own"
}

public struct MacHostEnvironment: HostEnvironment {
    public let databaseURL: URL
    public let cacheRoot: URL
    public let preferences: Preferences
    /// Which rung of the ladder supplied the roots. Logged at `.notice` on
    /// startup, because "why is it writing there" should never need a debugger.
    public let origin: ContainerOrigin
    /// Whether `PGR_PREFS_SUITE` named the preference domain, rather than it
    /// being the build's own.
    ///
    /// **The third thing `--container` does not move.** A caller that relocated
    /// the storage has to know whether the preferences came with it before it
    /// writes anything to them — see `RunCommand.mayWriteFoldersThrough`.
    public let preferencesArePinned: Bool
    public let doorbells: DarwinNotification.Doorbells

    /// User-facing name, hyphenated. The hyphens never appear in an identifier.
    public static let directoryName = "Photos-Go-Round"

    public init(
        variant: BuildVariant = .current,
        containerOverride: URL? = nil,
        databaseOverride: URL? = nil,
        cacheOverride: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let resolved = Self.resolveContainer(
            override: containerOverride,
            environment: environment,
            variant: variant
        )
        origin = resolved.origin

        databaseURL =
            databaseOverride
            ?? environment["PGR_DATABASE"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? resolved.container.appending(path: Storage.databaseFilename)

        cacheRoot =
            cacheOverride
            ?? environment["PGR_CACHE"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? Self.defaultCacheRoot(
                container: resolved.container, origin: resolved.origin, variant: variant)

        // Preferences belong to the build, and this is the part that is not
        // deducible: relocating the storage root does *not* relocate them, so a
        // run that pointed only the container at scratch space would still read
        // and write the build's real source list. `PGR_PREFS_SUITE` moves them.
        // Keyed on the database rather than the container: the two can be
        // pointed apart, and the library a process belongs to is the one it has
        // open.
        doorbells = DarwinNotification.Doorbells(database: databaseURL)

        let pinnedDomain = environment["PGR_PREFS_SUITE"].flatMap { $0.isEmpty ? nil : $0 }
        preferencesArePinned = pinnedDomain != nil
        var resolvedPreferences = Preferences(
            suiteName: pinnedDomain ?? Self.preferenceDomain(variant: variant)
        )
        resolvedPreferences.doorbells = doorbells
        preferences = resolvedPreferences
    }

    /// Flags beat environment beats the build's own.
    ///
    /// A scratch run relocates its storage with one flag or one variable — a
    /// background service should never be tied to one path on one machine —
    /// while an ordinary run, however it was started, uses its build's.
    static func resolveContainer(
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
        let name = preferenceDomain(variant: variant)
        return (URL.homeDirectory.appending(path: "Library/Containers/\(name)"), .build)
    }

    static func defaultCacheRoot(
        container: URL, origin: ContainerOrigin, variant: BuildVariant = .current
    ) -> URL {
        // An explicit container takes the cache with it, because somebody who
        // named one directory means both. Otherwise it is the build's own.
        guard origin == .build else { return container.appending(path: "cache") }
        return URL.homeDirectory.appending(path: "Library/Caches/\(preferenceDomain(variant: variant))")
    }

    /// The preference domain, which also names the container and cache
    /// directories. Public so that the surfaces — the screensaver, the wallpaper
    /// extension — reach the agent's domain through this rather than spelling it
    /// again.
    public static func preferenceDomain(variant: BuildVariant = .current) -> String {
        Storage.name(for: variant)
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
