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

    /// What the agent binds, and what a client tries first: this build's base
    /// plus a hash of the user's short name.
    ///
    /// **Per user, since 2026-09-21.** Syd: "use three different base addresses
    /// based on build variants, and then add a hash of the user name to it to
    /// come up with the port. If there is a collision, let the agent pick one,
    /// and we fall back to the existing mechanim." Two people logged in to one
    /// Mac each run an agent, and a fixed 9427 went to whoever started first.
    /// The fallback is the one `Plans/Service Port Plan.md` built: a port the
    /// agent cannot have is taken from the kernel and published.
    ///
    /// **Below the ephemeral range.** macOS hands out 49152–65535 to outgoing
    /// connections, so a port inside it can be held by another program's socket
    /// at the moment the agent starts. The three spans — 20000, 23000 and
    /// 26000, each 3000 wide — never overlap, so no two builds share a port for
    /// one user. `/etc/services` lists names across all of them, as it does
    /// across any span that wide; none is a service a Mac runs.
    public var port: UInt16 { port(forUser: NSUserName()) }

    public func port(forUser user: String) -> UInt16 {
        portBase + UInt16(Self.fnv1a(user) % UInt32(Self.portSpan))
    }

    static let portSpan: UInt16 = 3000

    var portBase: UInt16 {
        switch self {
        case .release: 20000
        case .debug: 23000
        case .claude: 26000
        }
    }

    /// FNV-1a, 32 bits, over the name's UTF-8.
    ///
    /// **Not Swift's `Hasher`, which is seeded afresh in every process**: the
    /// agent, the app, the screensaver and the wallpaper extension each compute
    /// this for themselves and must all get the same number.
    static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    /// What launchd knows this build's agent by, and the name of its plist in
    /// `~/Library/LaunchAgents`. One job per label per user, so a shared label
    /// would mean one installed agent rather than three.
    ///
    /// The bundle identifier deliberately does *not* vary: TCC grants hang off
    /// it, and Syd, 2026-09-19, chose "label per configuration" so Photos is
    /// answered once rather than once per configuration.
    public var agentLabel: String { "com.sydpolk.photosgoround.server" + identifierSuffix }

    /// The screensaver bundle's name, which is also its filename in
    /// `~/Library/Screen Savers` and what System Settings lists.
    public var saverBundleName: String { "Photos-Go-Round Screensaver" + nameSuffix }

    /// The wallpaper extension's bundle identifier, which is what `pluginkit`
    /// registers and what an install must never remove on another build's
    /// behalf. `Plans/Wallpaper Plan.md`, *Debug builds under their own
    /// identity*.
    public var wallpaperExtensionIdentifier: String {
        "com.sydpolk.photosgoround.wallpaper\(identifierSuffix).extension"
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
