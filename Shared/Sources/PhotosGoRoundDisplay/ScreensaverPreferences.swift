import Foundation
import PhotosGoRoundAgentAPI

/// The screensaver's own preferences: one domain per deployment, holding its
/// *Shuffle All* choice.
///
/// **Separate from the wallpaper's, the window's, and the agent's.** Syd,
/// 2026-09-14: "the wallpaper, screensaver, app window, and agents preferences
/// should all be separate." The app writes here from its Settings window; the
/// saver reads, and a new picture window copies what it finds.
public struct ScreensaverPreferences: Sendable, Equatable {

    /// "Screensaver will default to "10 seconds"" — which is also what every
    /// surface showed before this was a preference.
    public static let defaultInterval = ShuffleInterval.tenSeconds

    public let domain: String

    public init(domain: String) {
        self.domain = domain
    }

    /// `com.sydpolk.photosgoround.screensaver.dev` and `.prod`, beside the
    /// wallpaper's, and carrying the build variant for the same reason — and
    /// naming it the same way, since the pair is meant to be read together.
    public init(deployment: Deployment, variant: BuildVariant = .current) {
        self.init(
            domain: "\(Deployment.storageIdentifier(for: variant)).screensaver.\(deployment.domainSuffix)")
    }

    /// **The suite first, the file underneath**, which is `ServicePort`'s route
    /// and for the same measured reason: inside `legacyScreenSaver`'s sandbox
    /// the suite opens cleanly and holds nothing. An unsandboxed reader — the
    /// app — gets its answer from the suite and never touches the file.
    public func read() -> IntervalReading {
        let suite = IntervalReading.parse(
            UserDefaults(suiteName: domain)?.object(forKey: ShuffleInterval.key), from: .suite)
        guard suite == .unset else { return suite }
        return Self.readFile(at: ServicePort.plistURL(forDomain: domain))
    }

    /// The choice, or ten seconds.
    public var interval: ShuffleInterval {
        read().choice(default: Self.defaultInterval)
    }

    /// The Settings window's pop-up. **Only the app writes**: the saver's
    /// sandbox can read this domain's file and cannot write it.
    public func set(_ interval: ShuffleInterval) {
        UserDefaults(suiteName: domain)?.set(interval.rawValue, forKey: ShuffleInterval.key)
    }

    static func readFile(at url: URL) -> IntervalReading {
        switch ServicePort.contents(at: url) {
        case .missing: .unset
        case .unreadable(let reason): .unreadable(reason: reason)
        case .contents(let dictionary): IntervalReading.parse(dictionary[ShuffleInterval.key], from: .file)
        }
    }
}

extension Deployment {
    /// The last component of a surface's own domain and directory: the
    /// wallpaper's and the screensaver's are spelled from this, so the two
    /// cannot disagree about what a deployment is called.
    var domainSuffix: String {
        switch self {
        case .production: "prod"
        case .development: "dev"
        }
    }
}
