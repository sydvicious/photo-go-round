// When each display asks for its next photograph. `Wallpaper Plan.md`, *The real
// extension, inside the app*.
//
// **The interval is read, never written.** Syd, 2026-09-15: "shared domain" — the
// wallpaper's own domain, `com.sydpolk.photogoround.wallpaper.{dev|prod}`, which
// the app's Settings window writes and this reads through a read-only exception.
// So one pop-up times the app's wallpaper and this one alike, and the next stage
// — a timing slider in the pane itself — replaces the reading, not the writing.

import Foundation
import PhotoGoRoundAgentAPI
import PhotoGoRoundDisplay

enum Rotation {
    /// Both domains, development first, matching `AgentPicture`: a developer's
    /// Mac has both and only one agent.
    static var interval: ShuffleInterval {
        for deployment in AgentPicture.deployments {
            let domain = WallpaperHome(deployment: deployment).domain
            guard let stored = UserDefaults(suiteName: domain)?.object(forKey: ShuffleInterval.key) as? String
            else { continue }
            guard let choice = ShuffleInterval(rawValue: stored) else {
                wallpaperLog("interval: \(domain) holds \(stored), which is not a Shuffle All tag; using the default")
                continue
            }
            return choice
        }
        return Wallpaper.defaultInterval
    }

    /// One timer per surface, cancelled when that surface goes.
    ///
    /// **A timer rather than a deadline computed once**, because the interval can
    /// change under a running extension: the app writes the domain and nothing
    /// tells us, so each tick reads it again and the next tick follows the new
    /// value. The wait is clamped, so a preference nobody validated cannot spin
    /// this or park it forever.
    static func every(_ wait: Duration, _ body: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            var next = wait
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: next)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                body()
                next = clamped(interval.duration)
            }
        }
    }

    /// Ten seconds at the fastest — the shortest *Shuffle All* choice — and a day
    /// at the slowest.
    static func clamped(_ wait: Duration) -> Duration {
        min(max(wait, .seconds(10)), .seconds(24 * 60 * 60))
    }
}
