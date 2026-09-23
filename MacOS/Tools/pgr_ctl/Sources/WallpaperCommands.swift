import Console
import Foundation
import PhotosGoRoundAgentAPI
import PhotosGoRoundDisplay

/// Reading and writing the wallpaper's own preferences.
///
/// **A different domain from the agent's**, which is what `get` and `set` reach:
/// the wallpaper's is `com.sydpolk.photosgoround.wallpaper.{dev|prod}`, written by
/// the app's Settings window and read by the wallpaper extension. Syd,
/// 2026-09-15: "add wallpaper prefs and command to pgr_ctl", so that a Mac whose
/// app is never opened can still be set from a terminal.
///
/// Raw `defaults write` on that domain stays as valid as it ever was. This exists
/// so nobody has to know which domain a deployment uses, and so a value that is
/// not a `ShuffleInterval` tag is refused here rather than silently ignored by
/// whatever reads it.
///
/// **One key.** `enabled` and `displays` went with the app's own wallpaper loop
/// on 2026-09-16; the extension is on or off by being chosen in System Settings,
/// and keeps its own record of what it showed.
enum WallpaperCommands {

    enum Key: String, CaseIterable {
        case interval
    }

    /// The domain `get` and `set` address, from the two axes the flags name:
    /// the deployment (`--prod`) and the build configuration (`--debug`,
    /// `--claude`).
    ///
    /// **Here rather than inline at the two call sites.** Until 2026-09-19 both
    /// spelled `WallpaperPreferences(deployment:)`, which takes the running
    /// build's variant — so `--debug` reached the agent's Debug library and the
    /// *wallpaper's* Claude domain, silently. `Documentation/pgr_ctl.md`,
    /// `wallpaper get`.
    static func domain(deployment: Deployment, variant: BuildVariant) -> String {
        WallpaperPreferences(deployment: deployment, variant: variant).domain
    }

    static func get(key: String?, domain: String) throws {
        let defaults = UserDefaults(suiteName: domain)

        if let key {
            guard let match = Key(rawValue: key) else { throw unknown(key) }
            // Bare, so a script can read it without parsing.
            print(value(of: match, in: defaults))
            return
        }

        Console.note("domain \(domain)")
        for wanted in Key.allCases {
            Console.note(
                "\(wanted.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                    + value(of: wanted, in: defaults))
        }
    }

    /// What `get` prints for one key. An unset preference reports the value the
    /// wallpaper would use, which is the question nearly always being asked.
    static func value(of key: Key, in defaults: UserDefaults?) -> String {
        switch key {
        case .interval:
            guard let stored = defaults?.object(forKey: key.rawValue) as? String,
                let choice = ShuffleInterval(rawValue: stored)
            else { return WallpaperPreferences.defaultInterval.rawValue }
            return choice.rawValue
        }
    }

    static func set(key: String, value: String, domain: String) throws {
        guard let match = Key(rawValue: key) else { throw unknown(key) }

        switch match {
        case .interval:
            guard let choice = ShuffleInterval(rawValue: value) else {
                Console.failure(
                    "interval takes one of: "
                        + ShuffleInterval.allCases.map(\.rawValue).joined(separator: ", "))
                throw ExitCode(1)
            }
            WallpaperPreferences(domain: domain).set(choice)
            Console.note("interval \(choice.rawValue) in \(domain) — \(choice.title)")
        }
    }

    private static func unknown(_ key: String) -> ExitCode {
        Console.failure(
            "unknown wallpaper preference \(key). Valid keys: "
                + Key.allCases.map(\.rawValue).joined(separator: ", "))
        return ExitCode(1)
    }
}
