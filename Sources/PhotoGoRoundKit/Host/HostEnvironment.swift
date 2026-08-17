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
}

/// Where the storage root came from, so that it is never a mystery.
public enum ContainerOrigin: String, Sendable {
    /// A `--container` or `--database` flag.
    case explicitOverride = "explicit override"
    /// `PGR_CONTAINER` or `PGR_DATABASE`, which is how a launchd plist pins the
    /// production roots.
    case environment
    /// The App Group container, which resolves for sandboxed and unsandboxed
    /// processes alike and is the shipping answer on both platforms.
    case appGroup = "app group container"
    /// `~/Library/Application Support/Photo-Go-Round`, for development builds
    /// with no App Group entitlement.
    case applicationSupport = "application support"
}

/// The Mac agent's environment.
public struct MacHostEnvironment: HostEnvironment {
    public let databaseURL: URL
    public let cacheRoot: URL
    public let preferences: Preferences
    /// Which rung of the ladder supplied the roots. Logged at `.notice` on
    /// startup, because "why is it writing there" should never need a debugger.
    public let origin: ContainerOrigin

    /// The App Group must be team-ID prefixed on macOS — `<TeamID>.com.sydpolk.photogoround`,
    /// not `group.com.sydpolk.photogoround`. Getting it wrong produces a nil
    /// container URL rather than an error, which is a classic afternoon lost.
    /// It is therefore not portable between the Mac and iOS builds, which is
    /// why it lives here rather than in a shared constant.
    public static let appGroupIdentifier = "R5PQPZARC5.com.sydpolk.photogoround"

    /// User-facing name, hyphenated. The hyphens never appear in an identifier.
    public static let directoryName = "Photo-Go-Round"

    public init(
        containerOverride: URL? = nil,
        databaseOverride: URL? = nil,
        cacheOverride: URL? = nil,
        appGroupIdentifier: String? = MacHostEnvironment.appGroupIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let resolved = Self.resolveContainer(
            override: containerOverride,
            appGroupIdentifier: appGroupIdentifier,
            environment: environment
        )
        origin = resolved.origin

        databaseURL =
            databaseOverride
            ?? environment["PGR_DATABASE"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? resolved.container.appending(path: "library.sqlite")

        cacheRoot =
            cacheOverride
            ?? environment["PGR_CACHE"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? resolved.container.appending(path: "cache")

        preferences = Preferences(suiteName: appGroupIdentifier)
    }

    /// Flags beat environment beats App Group beats Application Support.
    ///
    /// A launchd plist sets environment variables far more naturally than it
    /// sets argv, so the production roots can be pinned there while a
    /// development run relocates everything with one flag — which is the whole
    /// point: a background service should never be tied to one path on one
    /// machine.
    static func resolveContainer(
        override: URL?,
        appGroupIdentifier: String?,
        environment: [String: String]
    ) -> (container: URL, origin: ContainerOrigin) {
        if let override {
            return (override, .explicitOverride)
        }
        if let fromEnvironment = environment["PGR_CONTAINER"], !fromEnvironment.isEmpty {
            return (URL(filePath: fromEnvironment), .environment)
        }
        if let appGroupIdentifier,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
            )
        {
            return (container, .appGroup)
        }
        return (
            URL.applicationSupportDirectory.appending(path: Self.directoryName),
            .applicationSupport
        )
    }

    public func announce(_ topic: DarwinNotification.Topic) {
        DarwinNotification.post(topic)
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
