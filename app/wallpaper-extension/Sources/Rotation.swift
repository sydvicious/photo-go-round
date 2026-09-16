// When each display asks for its next photograph. `Wallpaper Plan.md`, *The real
// extension, inside the app*.
//
// **The interval is read, never written.** Syd, 2026-09-15: "shared domain" — the
// wallpaper's own domain, `com.sydpolk.photogoround.wallpaper.{dev|prod}`, which
// the app's Settings window and `pgr_ctl wallpaper set` write and this reads
// through a read-only exception. The next stage — a timing slider in the pane
// itself — replaces the reading, not the writing.

import Foundation
import PhotoGoRoundAgentAPI
import PhotoGoRoundDisplay

enum Rotation {
    /// Both domains, development first, matching `AgentPicture`: a developer's
    /// Mac has both and only one agent.
    static var interval: ShuffleInterval {
        for deployment in AgentPicture.deployments {
            let preferences = WallpaperPreferences(deployment: deployment)
            switch preferences.read() {
            case .set(let choice, _):
                return choice
            case .unset:
                continue
            case .unknown(let raw, _):
                wallpaperLog("interval: \(preferences.domain) holds \(raw), which is not a Shuffle All tag; using the default")
            case .unreadable(let reason):
                wallpaperLog("interval: \(preferences.domain) could not be read: \(reason); using the default")
            }
        }
        return WallpaperPreferences.defaultInterval
    }

    /// The rotation never sleeps longer than this, so a changed interval is
    /// noticed within it rather than at the next photograph — the cap the app's
    /// own loop had, for the same reason, at a third of its thirty seconds.
    /// Syd: "how about a 10-second recheck?" It is the shortest *Shuffle All*
    /// choice, so no picture is ever late by more than one of its own ticks,
    /// and the cost is one preference read per display every ten seconds.
    ///
    /// **Measured 2026-09-16, without it:** the interval was set from one hour
    /// to ten seconds at 08:13:30 and nothing happened, because the wait had
    /// been fixed at 08:02:42 for an hour; set from ten seconds to ten minutes
    /// at 08:14:54, the next tick still fired at 08:14:58. Syd: "changing the
    /// setting in the app is NOT updating the setting for the wallpaper."
    static let recheck = Duration.seconds(10)

    /// One rotation per desktop surface, cancelled when that surface goes.
    ///
    /// **A due time, re-read every slice, rather than a wait computed once**,
    /// because the interval can change under a running extension: the app and
    /// `pgr_ctl` write the domain and nothing tells us. So the next photograph
    /// is due `interval` after the last one, and the task sleeps at most
    /// `recheck` before looking at the interval again. Shortening it asks
    /// within ten seconds if the picture is already older than the new
    /// interval; lengthening it leaves the picture up for the new interval,
    /// counted from when it appeared.
    static func run(_ body: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            let clock = ContinuousClock()
            var lastAsk = clock.now
            var lastInterval = interval
            while !Task.isCancelled {
                let current = interval
                if current != lastInterval {
                    wallpaperLog("interval now \(current.rawValue), was \(lastInterval.rawValue)")
                    lastInterval = current
                }
                let due = lastAsk + clamped(current.duration)
                let remaining = clock.now.duration(to: due)
                if remaining <= .zero {
                    body()
                    lastAsk = clock.now
                    continue
                }
                do {
                    try await Task.sleep(for: min(remaining, recheck))
                } catch {
                    return
                }
            }
        }
    }

    /// Ten seconds at the fastest — the shortest *Shuffle All* choice — and a day
    /// at the slowest.
    static func clamped(_ wait: Duration) -> Duration {
        min(max(wait, .seconds(10)), .seconds(24 * 60 * 60))
    }
}
