import Foundation

/// Where a path stands, and why it cannot be reached.
///
/// **Separate from the folder provider's classifier on purpose.** Deciding
/// whether a file is a photograph, how big it is, and whether its volume can
/// evict it is the scanner's business and lives with the scanner. Deciding
/// whether a path is *there* is asked by two processes — the agent before it
/// walks a source, and the app before it draws a row — so it lives where both
/// can reach it without the app linking a database.
public enum PathAvailability {
    /// **Public because two very different processes need the same answer.** The
    /// agent asks it about a source it is about to walk; the app asks it about a
    /// row it is about to draw, because it is unsandboxed, it knows the path, and
    /// a round trip to be told what a `stat` would say is a round trip for
    /// nothing.
    ///
    /// The conservative step is the third case. A folder the caller has not been
    /// granted access to is indistinguishable from one that is not there — the
    /// `stat` fails either way — so the parent has to be readable before an
    /// absence is allowed to mean *gone*. Getting that wrong deletes a library
    /// over a permission prompt.
    public static func availability(of url: URL) -> SourceAvailability {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return .available
        }
        guard volumeIsMounted(for: url) else { return .offline(reason: "volume not mounted") }
        let parent = url.deletingLastPathComponent().path(percentEncoded: false)
        guard FileManager.default.isReadableFile(atPath: parent) else {
            return .offline(reason: "not readable")
        }
        return .gone(reason: "no longer at this path")
    }

    /// Why a path could not be reached, phrased for a person reading
    /// `pgr source list` in red.
    ///
    /// The distinction that matters is an unplugged drive versus a deleted
    /// folder: the first is temporary and must not cost anyone their deal
    /// history, and the second is the user's own doing.
    public static func unavailableReason(for url: URL) -> String {
        if !volumeIsMounted(for: url) { return "volume not mounted" }
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return "not readable"
        }
        return "no longer at this path"
    }

    public static func volumeIsMounted(for url: URL) -> Bool {
        guard
            let mounted = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil, options: []
            )
        else { return true }

        let path = url.standardizedFileURL.path(percentEncoded: false)
        return volumeIsMounted(
            path: path,
            mountPoints: mounted.map { $0.standardizedFileURL.path(percentEncoded: false) }
        )
    }

    /// Split out so the awkward part is testable without mounting anything.
    ///
    /// The subtlety is that `/` prefixes every path, so a naive "does any mount
    /// point contain this" is always true and the answer is always "the file was
    /// deleted". The volume a path lives on is the *deepest* mount point
    /// containing it — and a path under `/Volumes` whose deepest match is the
    /// root volume is a path on a volume that is not there.
    public static func volumeIsMounted(path: String, mountPoints: [String]) -> Bool {
        let containing = mountPoints.filter { mount in
            path == mount || path.hasPrefix(mount.hasSuffix("/") ? mount : mount + "/")
        }
        guard let deepest = containing.max(by: { $0.count < $1.count }) else { return false }
        if deepest == "/", path.hasPrefix("/Volumes/") { return false }
        return true
    }
}
