import Foundation

/// The LaunchAgent plist, as a value.
///
/// **A `Codable` rather than a heredoc**, which is what `plutil -lint` used to
/// guard against: an encoder cannot emit malformed XML, so the check it replaced
/// has nothing left to check.
public struct JobDescription: Codable, Equatable, Sendable {

    /// What launchd knows the job by. One job per label per user, which is why
    /// each build configuration has its own. `BuildVariant.swift`.
    public var label: String
    public var programArguments: [String]
    public var runAtLoad: Bool
    public var keepAlive: KeepAlive
    public var processType: String

    /// Restart it when it fails, and leave it alone when it exits cleanly.
    public struct KeepAlive: Codable, Equatable, Sendable {
        public var successfulExit: Bool

        enum CodingKeys: String, CodingKey {
            case successfulExit = "SuccessfulExit"
        }
    }

    enum CodingKeys: String, CodingKey {
        case label = "Label"
        case programArguments = "ProgramArguments"
        case runAtLoad = "RunAtLoad"
        case keepAlive = "KeepAlive"
        case processType = "ProcessType"
    }

    /// **`Adaptive`, not `Background`, since 2026-09-17.** macOS throttles a
    /// Background job's disk I/O, and this agent reads the disk to answer a
    /// person waiting on a picture. Measured over four restarts with
    /// `Background`: about two minutes between the process starting and its
    /// first line of code, then a cache walk of 16 to 39 seconds that takes
    /// 137 ms on a quiet machine, and one-row writes holding the database's
    /// write lock for hundreds of milliseconds — all of it disk, none of it the
    /// agent's own work. Adaptive lets the system lift the throttle when the
    /// process is doing user-visible work. `TODO.md`, *The agent takes about two
    /// minutes from launch to listening after a restart*.
    public static let adaptive = "Adaptive"

    public init(label: String, program: URL) {
        self.label = label
        self.programArguments = [program.path(percentEncoded: false)]
        self.runAtLoad = true
        self.keepAlive = KeepAlive(successfulExit: false)
        self.processType = Self.adaptive
    }

    public func encodedPlist() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(self)
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encodedPlist().write(to: url, options: .atomic)
    }
}
