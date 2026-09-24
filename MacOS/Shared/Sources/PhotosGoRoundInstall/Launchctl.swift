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

    /// The process of a loaded job, or nil when the job is not loaded or is not
    /// running. Read from `launchctl print`, whose `pid = N` line is there only
    /// while the job has a process.
    public static func pid(of label: String) -> Int32? {
        let printed = Shell.run("/bin/launchctl", ["print", "\(userDomain)/\(label)"])
        guard printed.status == 0 else { return nil }
        for line in printed.output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("pid = "), let pid = Int32(text.dropFirst("pid = ".count)) {
                return pid
            }
        }
        return nil
    }

    /// Agents running under a name, with the path each is running from —
    /// **launchd's own among them, despite the name.**
    ///
    /// The caller decides which of these are somebody else's: an install knows
    /// its own binary's path and everything else belongs to whoever started it,
    /// and an uninstall leaves out every process a loaded job owns
    /// (`Uninstall.handStarted`).
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
