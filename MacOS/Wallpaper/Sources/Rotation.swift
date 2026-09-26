// When each display asks for its next photograph. `Wallpaper Plan.md`, *The real
// extension, inside the app*.
//
// **The interval is read, never written.** Syd, 2026-09-15: "shared domain" — the
// wallpaper's own domain, `com.sydpolk.photosgoround.wallpaper` (`….debug.wallpaper`, `….claude.wallpaper`), which
// the app's Settings window and `pgr_ctl wallpaper set` write and this reads
// through a read-only exception. The next stage — a timing slider in the pane
// itself — replaces the reading, not the writing.

import Foundation
import PhotosGoRoundAgentAPI
import PhotosGoRoundDisplay

enum Rotation {
    /// This build's, the only one it has.
    static var interval: ShuffleInterval {
        let preferences = WallpaperPreferences()
        switch preferences.read() {
        case .set(let choice, _):
            return choice
        case .unset:
            break
        case .unknown(let raw, _):
            wallpaperLog("interval: \(preferences.domain) holds \(raw), which is not a Shuffle All tag; using the default")
        case .unreadable(let reason):
            wallpaperLog("interval: \(preferences.domain) could not be read: \(reason); using the default")
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

    /// What one ask came back with, which decides when to ask again.
    enum Asked: Sendable {
        /// A photograph: the next is due a whole interval from now.
        case picture
        /// The empty state's words, drawn: the agent is answering and has
        /// nothing. **Asked past within `recheck`**, not a whole interval —
        /// Syd's rotation can be twelve hours, and a desktop still saying
        /// *Please Add Photos* half a day after a source was added would be
        /// the stale answer this exists to replace.
        case message
        /// Nothing arrived: no agent, or a bare empty answer.
        case nothing
    }

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
    /// **The body says what arrived**, because the answer decides when to ask
    /// again. Measured 2026-09-18 across two reboots: the extension
    /// woke 5 and 51 seconds before the agent was listening, was refused, and
    /// then waited its whole interval — ten minutes of a stale desktop, or half
    /// a day at `twelveHours`. A refusal now costs ten seconds; see
    /// `RetryAfterSilence`.
    ///
    /// **The first ask is due at once**, which is why `lastAsk` starts an
    /// interval in the past. It used to be made separately by the caller, where
    /// nothing could see whether it worked — the one ask that fails most often.
    ///
    /// **While a message is up, every ask is `recheck` apart**, whatever comes
    /// back short of a photograph: a bare empty answer after one is most often
    /// a source that has just been added and is being scanned, and the desktop
    /// should change as soon as it has something.
    static func run(_ body: @escaping @Sendable () async -> Asked) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            let clock = ContinuousClock()
            var lastInterval = interval
            var lastAsk = clock.now - clamped(lastInterval.duration)
            var retry = RetryAfterSilence()
            var messageUp = false
            while !Task.isCancelled {
                let current = interval
                if current != lastInterval {
                    wallpaperLog("interval now \(current.rawValue), was \(lastInterval.rawValue)")
                    lastInterval = current
                }
                let rotation = clamped(current.duration)
                let due = lastAsk + (messageUp ? min(recheck, rotation) : retry.wait(interval: rotation))
                let remaining = clock.now.duration(to: due)
                if remaining <= .zero {
                    let asked = await body()
                    lastAsk = clock.now
                    switch asked {
                    case .picture, .message:
                        messageUp = asked == .message
                        if retry.answered() { wallpaperLog("the agent is answering again") }
                    case .nothing:
                        if retry.wentQuiet(cap: rotation), !messageUp {
                            wallpaperLog(
                                "no agent; asking again in \(retry.wait(interval: rotation)) "
                                    + "rather than waiting out the \(current.rawValue) rotation")
                        }
                    }
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
