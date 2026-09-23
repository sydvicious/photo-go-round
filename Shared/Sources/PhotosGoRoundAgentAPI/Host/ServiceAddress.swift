import Foundation

/// Where the agent serves, when nobody has said otherwise.
///
/// **A number everybody knows, rather than one everybody has to chase.** Until
/// 2026-09-17 the agent asked the kernel for a free port and published it, and
/// everything that wanted a picture had to read that value first. Syd, that
/// day: "Perhaps we had better actually pick a port and hardcode it. this
/// dynamic port stuff is causing problems." Measured across five reboots the
/// same afternoon, each launch took a different port — 56333, 58192, and so on
/// — and the app showed *waiting for the agent* until it re-read the
/// preference, which from the person's side is indistinguishable from the agent
/// being down.
///
/// **9427, and the constraint that picked it is the ephemeral range.** macOS
/// hands out 49152–65535 to outgoing connections (`net.inet.ip.portrange`), so
/// a fixed port inside it can be held by some other program's socket at the
/// moment the agent starts — and a fixed port that is sometimes stolen is worse
/// than a dynamic one. Below 1024 needs privilege. 9427 is in neither, is not
/// in `/etc/services`, and nothing on Syd's Mac was listening on it. The number
/// carries no other meaning.
///
/// **Loopback only, as it always was.** Nothing off this machine reaches the
/// agent, so this is a local convention rather than an allocation anyone else
/// has to respect.
///
/// `Plans/Service Port Plan.md`.
/// **Three numbers, one per build variant.** Syd, 2026-09-17: "I think each of
/// the three build variants need their own fixed ports", and then, of how the
/// variant is decided: "build-time identity". It is the same three identities
/// the wallpaper extension already has — a release, Syd's Debug, and a build
/// made by an agent — and for the same reason: two of them can be running at
/// once on this Mac, and one fixed port between them would mean the second to
/// start does not start at all.
///
/// The variant comes from the compiler, not from which library a run opens:
/// `Deployment` answers *whose pictures*, and that is a different question from
/// *whose build*. **Since 2026-09-19 that decision lives in `BuildVariant`**,
/// which also owns the LaunchAgent label, the screensaver's bundle name and the
/// wallpaper extension's identifier — the port was the first of four things
/// that vary by build, and a second `#if` beside this one was the wrong answer.
public enum ServiceAddress {
    /// What the agent binds, and what a client tries first.
    public static var port: UInt16 { BuildVariant.current.port }

    /// Which build this is, for the line the agent prints at startup: a port
    /// nobody can account for is worse than no fixed port at all.
    public static var variant: String { BuildVariant.current.description }
}
