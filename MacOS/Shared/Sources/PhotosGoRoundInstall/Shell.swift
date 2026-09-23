import Foundation

/// The command-line tools an install cannot avoid.
///
/// **`launchctl`, `pluginkit` and `killall` have no API**, so moving the
/// installs out of shell moved where the logic lives, not which tools do the
/// work. That is the honest claim and it is worth writing down: this module is
/// one implementation of installing, not the end of shelling out.
/// `Plans/Xcode - Separate Build and Run.md`, *Design Decisions*.
enum Shell {

    /// Runs a tool and returns its status and trimmed standard output.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, text)
    }

    /// Whether a process of exactly this name is running.
    ///
    /// `-x` rather than a substring match: every build variant's wallpaper
    /// extension shares a process name, and a loose match has already stopped
    /// somebody else's.
    static func pgrepExact(_ name: String) -> Bool {
        run("/usr/bin/pgrep", ["-x", name]).status == 0
    }

    /// Stops every process of this name, reporting whether there was one.
    static func killall(_ name: String) -> Bool {
        run("/usr/bin/killall", [name]).status == 0
    }
}
