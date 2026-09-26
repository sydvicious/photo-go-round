import Foundation

/// Why `GET /v1/next` answered `204`, when the agent knows for certain.
///
/// **A bare `204` still means *nothing right now*.** A queue turning over, a
/// source still on its first scan, and a library with nothing in it look alike
/// from inside a request, so the client waits out a streak of them before it
/// says anything. This names only what the agent can state on the first answer
/// without guessing, and a surface that meets it says so at once — Syd,
/// 2026-09-26.
public enum EmptyReason: String, Sendable, Equatable {
    /// No source is enabled: none has been added, or every one is turned off.
    case noSources = "no-sources"
    /// Sources are enabled and none of them has a photograph that could be
    /// shown, and nothing is still being looked for.
    ///
    /// **Offline is not unknown when nothing of it is cached.** Syd,
    /// 2026-09-26: an offline source serves what the cache holds of it, and
    /// "if everything is offline, and there is nothing in the cache, then
    /// display *No Photos Available*". What makes it unknown is a source that
    /// is there and has not finished a scan yet.
    case noPhotos = "no-photos"

    /// The response header that carries it.
    public static let headerField = "X-PGR-Empty"
}
