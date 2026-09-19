import Foundation
import PhotoGoRoundAgentAPI

/// The wallpaper's own preferences: one domain per deployment, holding its
/// *Shuffle All* choice.
///
/// **Separate from the screensaver's, the window's, and the agent's.** Syd,
/// 2026-09-10: "give the wallpaper its own domain. Actually two" —
/// `com.sydpolk.photogoround.wallpaper.dev` and `.prod`. The app writes here
/// from its Settings window and `pgr_ctl wallpaper set` from a terminal; the
/// wallpaper extension reads, through a read-only sandbox exception, and times
/// each display's next photograph by it.
///
/// **The wallpaper itself is the extension, not the app.** Until 2026-09-16 the
/// app ran a wallpaper loop of its own, `Wallpaper`, behind an *Also set
/// wallpapers* checkbox, and this domain held its record of every display. Syd:
/// "remove the whole in-app loop; we might need it later for sandboxed app, but
/// for now it is gone." The loop is in git; what is left is the preference the
/// extension reads.
public struct WallpaperPreferences: Sendable, Equatable {

    /// The interval when nothing has chosen one. **One hour.** Syd, 2026-09-14:
    /// "wallpaper will default to "1 hour"." It was thirty minutes from
    /// 2026-09-13, sixty seconds from 2026-09-10, and thirty minutes before
    /// that, which is what `Wallpaper Plan.md` was written around.
    public static let defaultInterval = ShuffleInterval.oneHour

    public let domain: String

    public init(domain: String) {
        self.domain = domain
    }

    /// `com.sydpolk.photogoround.wallpaper.dev` and `.prod`, beside the
    /// screensaver's — and carrying the build variant, so a Debug wallpaper and
    /// a release one do not share an interval. `BuildVariant.swift`.
    public init(deployment: Deployment) {
        self.init(domain: "\(Deployment.storageIdentifier()).wallpaper.\(deployment.domainSuffix)")
    }

    /// **The suite first, the file underneath**, as `ScreensaverPreferences`
    /// reads: a sandboxed reader may find the suite open and empty, and the
    /// extension is granted the plist as well as the domain.
    public func read() -> IntervalReading {
        let suite = IntervalReading.parse(
            UserDefaults(suiteName: domain)?.object(forKey: ShuffleInterval.key), from: .suite)
        guard suite == .unset else { return suite }
        return ScreensaverPreferences.readFile(at: ServicePort.plistURL(forDomain: domain))
    }

    /// The choice, or an hour.
    public var interval: ShuffleInterval {
        read().choice(default: Self.defaultInterval)
    }

    /// The Settings window's pop-up, and `pgr_ctl wallpaper set interval`.
    /// Written as the tag; the extension reads it again at every tick, so a
    /// change applies by the next photograph and nothing needs a restart.
    public func set(_ interval: ShuffleInterval) {
        UserDefaults(suiteName: domain)?.set(interval.rawValue, forKey: ShuffleInterval.key)
    }
}
