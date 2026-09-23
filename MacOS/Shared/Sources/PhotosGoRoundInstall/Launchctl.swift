import Foundation

/// `launchctl`, which has no API.
///
/// Everything is scoped to `gui/$UID` — the per-user domain — because the agent
/// is a LaunchAgent and not a daemon: Photos access is per-user TCC and needs a
/// user session, so a system daemon could not reach the library at all.
public enum Launchctl {

    static var userDomain: String { "gui/\(getuid())" }

    /// Whether launchd knows this label.
    public static func isLoaded(_ label: String) -> Bool {
        Shell.run("/bin/launchctl", ["print", "\(userDomain)/\(label)"]).status == 0
    }

    /// Stops the job's process, if it has one, and starts it again.
    ///
    /// `-k` is what makes it a restart: without it `kickstart` leaves a
    /// running job alone.
    @discardableResult
    public static func kickstart(_ label: String) -> Bool {
        Shell.run("/bin/launchctl", ["kickstart", "-k", "\(userDomain)/\(label)"]).status == 0
    }

    /// Removes the job. Failing is ordinary — there may be no job yet — so the
    /// status is deliberately ignored; `AgentInstall` waits for the label to go
    /// rather than trusting this to have finished.
    public static func bootout(_ label: String) {
        Shell.run("/bin/launchctl", ["bootout", "\(userDomain)/\(label)"])
    }

    public static func bootstrap(_ plist: URL) {
        Shell.run("/bin/launchctl", ["bootstrap", userDomain, plist.path(percentEncoded: false)])
    }

    /// Agents running under a name, with the path each is running from.
    ///
    /// The caller decides which of these are somebody else's: an install knows
    /// its own binary's path and everything else belongs to whoever started it.
    ///
    /// **Matched as the last component of the executable's path.** The name has
    /// a space in it since 2026-09-22, when `photogoroundd` became `Photos-Go-Round
    /// Server`, and the bare name is also the scheme's: an `xcodebuild -scheme
    /// "Photos-Go-Round Server"` would otherwise read as an agent running.
    public static func agentsOutsideLaunchd(named name: String) -> [AgentInstall.ForeignAgent] {
        let found = Shell.run("/usr/bin/pgrep", ["-f", "/\(name)( |$)"])
        guard found.status == 0 else { return [] }
        return found.output.split(separator: "\n").compactMap { line in
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else { return nil }
            let path = Shell.run("/bin/ps", ["-o", "comm=", "-p", String(pid)]).output
            guard !path.isEmpty else { return nil }
            return AgentInstall.ForeignAgent(pid: pid, path: path)
        }
    }
}
