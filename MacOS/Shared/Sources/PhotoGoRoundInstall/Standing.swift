import Foundation

/// Whether what an app carries is already what this Mac has installed.
///
/// **The question an archived app asks at every launch**, before it installs
/// anything. Syd, 2026-09-21: install "only when it differs". A relaunch of an
/// unchanged app must change nothing on the system, so each product answers
/// this first and an install follows only from `.missing` or `.differs`.
/// `Plans/Release App Installer.md`, Phase 3.
///
/// **Never decided by version number.** A rebuild keeps its version, so a
/// version check would call a changed build current. Each product compares
/// what actually runs: the saver by its code signature, the agent by its job
/// description and by when its binary last changed, the extension by where it
/// is registered from.
public enum Standing: Equatable, Sendable, CustomStringConvertible {
    /// Installed, and the same as what is carried. Nothing to do.
    case current
    /// Not installed at all.
    case missing
    /// Installed, but not what is carried — and why, for the log line.
    case differs(String)
    /// Installed from exactly what is carried, but before it last changed on
    /// disk: a rebuild, or an app replaced at the same path. The wallpaper's,
    /// because `pkd` drops a running extension whose bundle changes and
    /// `WallpaperAgent` does not start it again — measured 2026-09-21.
    case stale(String)

    public var needsInstall: Bool { self != .current }

    public var description: String {
        switch self {
        case .current: "same, nothing to do"
        case .missing: "not installed"
        case .differs(let why): "differs: \(why)"
        case .stale(let why): "stale: \(why)"
        }
    }
}
