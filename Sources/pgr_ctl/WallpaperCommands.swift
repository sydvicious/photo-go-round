import Console
import Foundation
import PhotoGoRoundDisplay

/// Reading and writing the wallpaper's own preferences.
///
/// **A different domain from the agent's**, which is what `get` and `set` reach:
/// the wallpaper's is `com.sydpolk.photogoround.wallpaper.{dev|prod}`, written by
/// the app's Settings window and read by the wallpaper wherever it runs. Syd,
/// 2026-09-15: "add wallpaper prefs and command to pgr_ctl", so that a Mac whose
/// app is never opened can still be set from a terminal.
///
/// Raw `defaults write` on that domain stays as valid as it ever was. This exists
/// so nobody has to know which domain a deployment uses, and so a value that is
/// not a `ShuffleInterval` tag is refused here rather than silently ignored by
/// whatever reads it.
enum WallpaperCommands {

    /// What can be read and written. `displays` is the wallpaper's record of what
    /// each display is showing and when it last changed; it is written by the
    /// wallpaper as it runs, and is readable here rather than settable.
    enum Key: String, CaseIterable {
        case enabled
        case interval
        case displays

        var isWritable: Bool { self != .displays }
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
    /// wallpaper would use, which is the question nearly always being asked;
    /// `displays` has no default and reports how many displays are recorded.
    static func value(of key: Key, in defaults: UserDefaults?) -> String {
        switch key {
        case .enabled:
            guard let stored = defaults?.object(forKey: key.rawValue) as? Bool else { return "false" }
            return stored ? "true" : "false"
        case .interval:
            guard let stored = defaults?.object(forKey: key.rawValue) as? String,
                let choice = ShuffleInterval(rawValue: stored)
            else { return Wallpaper.defaultInterval.rawValue }
            return choice.rawValue
        case .displays:
            guard let stored = defaults?.dictionary(forKey: key.rawValue), !stored.isEmpty else {
                return "none recorded"
            }
            return stored.keys.sorted().joined(separator: ", ")
        }
    }

    static func set(key: String, value: String, domain: String) throws {
        guard let match = Key(rawValue: key) else { throw unknown(key) }
        guard match.isWritable else {
            Console.failure("\(key) is written by the wallpaper itself and cannot be set here")
            throw ExitCode(1)
        }
        guard let defaults = UserDefaults(suiteName: domain) else {
            Console.failure("the domain \(domain) would not open")
            throw ExitCode(1)
        }

        switch match {
        case .enabled:
            guard let wanted = Bool(value) else {
                Console.failure("enabled takes true or false")
                throw ExitCode(1)
            }
            defaults.set(wanted, forKey: match.rawValue)
            Console.note("enabled \(wanted) in \(domain)")
        case .interval:
            guard let choice = ShuffleInterval(rawValue: value) else {
                Console.failure(
                    "interval takes one of: "
                        + ShuffleInterval.allCases.map(\.rawValue).joined(separator: ", "))
                throw ExitCode(1)
            }
            defaults.set(choice.rawValue, forKey: match.rawValue)
            Console.note("interval \(choice.rawValue) in \(domain) — \(choice.title)")
        case .displays:
            // Refused above; `isWritable` and this switch would have to disagree.
            throw ExitCode(1)
        }
    }

    private static func unknown(_ key: String) -> ExitCode {
        Console.failure(
            "unknown wallpaper preference \(key). Valid keys: "
                + Key.allCases.map(\.rawValue).joined(separator: ", "))
        return ExitCode(1)
    }
}
