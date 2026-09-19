import Foundation

/// Which build this is, decided by the compiler rather than by anything a run
/// discovers.
///
/// **Three configurations, all fully supported.** Syd, 2026-09-19: "There are
/// three configurations, debug, release, claude. all fully supported." A
/// release, Syd's Debug, and a build made by an agent — each with its own port,
/// its own LaunchAgent label, its own screensaver bundle name and its own
/// wallpaper extension identifier, so that all three can be installed and
/// running on one Mac at once and none can be mistaken for another.
///
/// The variant is a different question from `Deployment`, which answers *whose
/// pictures*. This answers *whose build*. `PGR_AGENT_CLAUDE` is set by the
/// `Claude` build configuration and by `swift build -Xswiftc
/// -DPGR_AGENT_CLAUDE`; `DEBUG` is what an Xcode or SwiftPM debug build defines
/// for itself. `Claude` defines both, and is checked first.
///
/// **The suffixes below are stated twice, and cannot be stated once.** Xcode
/// needs them as build settings — `SAVER_NAME_SUFFIX`, `SERVER_LABEL_SUFFIX`,
/// `WALLPAPER_ID_SUFFIX` at project level in `project.pbxproj` — because they
/// shape product names and `Info.plist` values before any Swift runs, and Swift
/// cannot read an `.xcconfig` at runtime. The two must agree. Anything that can
/// read the built bundle should prefer what the bundle carries:
/// `PGRLaunchAgentLabel` in the agent's `Info.plist` is the label that install
/// actually used, and is the truth for a bundle in hand.
///
/// `Plans/Xcode - Separate Build and Run.md`, *The build variant, compiled in*.
public enum BuildVariant: String, Sendable, CaseIterable {
    case release
    case debug
    case claude

    /// This build's variant. The project's one `#if` on build identity.
    public static let current: BuildVariant = {
        #if PGR_AGENT_CLAUDE
            .claude
        #elseif DEBUG
            .debug
        #else
            .release
        #endif
    }()

    /// What the agent binds, and what a client tries first.
    ///
    /// **9427, and the constraint that picked it is the ephemeral range.** macOS
    /// hands out 49152–65535 to outgoing connections, so a fixed port inside it
    /// can be held by another program's socket at the moment the agent starts.
    /// Below 1024 needs privilege. 9427 is in neither and is not in
    /// `/etc/services`; 9428 and 9429 follow it. `Plans/Service Port Plan.md`.
    public var port: UInt16 {
        switch self {
        case .release: 9427
        case .debug: 9428
        case .claude: 9429
        }
    }

    /// What launchd knows this build's agent by, and the name of its plist in
    /// `~/Library/LaunchAgents`. One job per label per user, so a shared label
    /// would mean one installed agent rather than three.
    ///
    /// The bundle identifier deliberately does *not* vary: TCC grants hang off
    /// it, and Syd, 2026-09-19, chose "label per configuration" so Photos is
    /// answered once rather than once per configuration.
    public var agentLabel: String { "com.sydpolk.photogoround.server" + identifierSuffix }

    /// The screensaver bundle's name, which is also its filename in
    /// `~/Library/Screen Savers` and what System Settings lists.
    public var saverBundleName: String { "Photo-Go-Round Screensaver" + nameSuffix }

    /// The wallpaper extension's bundle identifier, which is what `pluginkit`
    /// registers and what an install must never remove on another build's
    /// behalf. `Plans/Wallpaper Plan.md`, *Debug builds under their own
    /// identity*.
    public var wallpaperExtensionIdentifier: String {
        "com.sydpolk.photogoround.wallpaper\(identifierSuffix).extension"
    }

    /// For the line the agent prints at startup: a port nobody can account for
    /// is worse than no fixed port at all.
    public var description: String {
        switch self {
        case .release: "release build"
        case .debug: "debug build"
        case .claude: "Claude's build"
        }
    }

    /// Mirrors `SAVER_ID_SUFFIX`, `SERVER_LABEL_SUFFIX` and
    /// `WALLPAPER_ID_SUFFIX` in `project.pbxproj`.
    var identifierSuffix: String {
        switch self {
        case .release: ""
        case .debug: ".debug"
        case .claude: ".claude"
        }
    }

    /// Mirrors `SAVER_NAME_SUFFIX` and `WALLPAPER_NAME_SUFFIX` in
    /// `project.pbxproj`. A leading space: it reads as a name, not a tag.
    var nameSuffix: String {
        switch self {
        case .release: ""
        case .debug: " (Debug)"
        case .claude: " (Claude)"
        }
    }
}
