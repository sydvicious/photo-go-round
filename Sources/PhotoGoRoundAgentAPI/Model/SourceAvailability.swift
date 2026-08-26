import Foundation

/// Where a source stands right now — **three states, not two**.
///
/// The pair that is usually modelled, reachable and not, cannot express the
/// difference between a drive that is unplugged and a folder that was deleted
/// while its drive sat right there. Those call for opposite behaviour: the first
/// must change nothing, because everything comes back when the drive does, and
/// the second means those photographs are never coming back and their rows and
/// cached bytes are worth nothing.
public enum SourceAvailability: Sendable, Equatable {
    /// There, and readable.
    case available
    /// Cannot be reached. **Says nothing about its contents** — the cached
    /// copies are the most valuable thing we hold, and they keep being served.
    case offline(reason: String)
    /// Confirmed not there, on a volume that is. Its photographs are gone with
    /// it, so their rows and their cached bytes are removed as each is reached.
    case gone(reason: String)
}

extension SourceAvailability {
    /// Where a path stands, asked directly.
    ///
    /// **Public because two very different processes need the same answer about
    /// the same path.** The agent asks it about a source it is about to walk;
    /// the Mac app asks it about a row it is about to draw, because it is
    /// unsandboxed, it already has the path, and a round trip to be told what a
    /// `stat` would say is a round trip for nothing — and an answer that is a
    /// round trip old is exactly the stale one a settings panel is opened to get
    /// away from.
    ///
    /// Only file-backed sources can be asked this way. A Photos or Google album
    /// is a question only the agent can put.
    public static func of(path: String) -> SourceAvailability {
        PathAvailability.availability(of: URL(filePath: path))
    }
}
