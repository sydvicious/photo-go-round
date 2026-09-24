import Foundation
import PhotosGoRoundAgentAPI

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
    /// The app this job belongs to, which is what System Settings files it
    /// under.
    ///
    /// **Without it the job is listed under the signing certificate's name.**
    /// Checked 2026-09-23 with `sfltool dumpbtm`: macOS tracks this per-user
    /// plist as a legacy agent, enabled and allowed, with `Parent Identifier:
    /// Sydney Polk` — so *Allow in the Background* showed it under Syd's name,
    /// and nothing called Photos-Go-Round was anywhere in Login Items. This key
    /// names the app, and the plist stays per user in `~/Library/LaunchAgents`,
    /// as decided 2026-09-10.
    ///
    /// **It has not changed the listing yet.** Checked the same night: macOS
    /// read the key — `dumpbtm` shows `Assoc. Bundle IDs: [
    /// com.sydpolk.photosgoround ]` — and still filed the item under `Sydney
    /// Polk`, across a logout, for a build signed with an Apple Development
    /// certificate. Kept because it is the documented way to name the owning
    /// app and costs nothing; whether a Developer ID build honours it is not
    /// known.
    ///
    /// The app's identifier is the same in every build configuration, so every
    /// configuration's agent is filed under the one app.
    ///
    /// **Optional only so an older plist still decodes.** One written before
    /// this key existed reads as a different job, which is what makes the next
    /// app launch write it again. Every plist this writes carries it.
    public var associatedBundleIdentifiers: [String]?

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
        case associatedBundleIdentifiers = "AssociatedBundleIdentifiers"
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

    /// `--prod` for a production deployment. **Redundant for a Release agent
    /// since 2026-09-24**, which is production however it starts, and kept so
    /// the job says what it runs. `Deployment.current`.
    public init(label: String, program: URL, deployment: Deployment = .current) {
        self.label = label
        self.programArguments =
            [program.path(percentEncoded: false)] + (deployment == .production ? ["--prod"] : [])
        self.runAtLoad = true
        self.keepAlive = KeepAlive(successfulExit: false)
        self.processType = Self.adaptive
        self.associatedBundleIdentifiers = [Deployment.identifier]
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
