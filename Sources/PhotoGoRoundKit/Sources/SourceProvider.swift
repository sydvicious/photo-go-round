import Foundation

/// Whether a photo is still in its source — asked at the moment it matters.
///
/// Three values, not two, and the third is the whole point. "I could not find
/// it" and "it is not there" are completely different facts: the first is a
/// drive that is not plugged in, and answering it as *absent* would throw away
/// a library every time somebody undocked.
public enum PhotoExistence: Sendable, Equatable {
    /// Definitely still there.
    case present
    /// Definitely gone. The user deleted it, and they must never see it again.
    case absent
    /// Cannot be determined right now — the volume is not mounted, the share is
    /// down, the network is unreachable. Says nothing about the photo.
    case unknown(reason: String)
}

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
        FileClassifier.availability(of: URL(filePath: path))
    }
}

/// Everything a source kind has to be able to do.
///
/// Exactly two questions: *what identifiers are in you right now*, and *give me
/// the bytes for this identifier*. Enumeration and materialization, nothing
/// more. A provider knows nothing about the deck, the cache budget, or the
/// display side, which is what makes a new source kind additive.
///
/// Both operations are `async` even though the folder provider never suspends.
/// PhotoKit and the Google Photos API both will, and the kit's API is shaped by
/// constraints that arrive later on purpose — retrofitting them is the
/// expensive mistake.
public protocol SourceProvider: Sendable {
    var kind: SourceKind { get }

    /// What is in this source right now, handed over one photo at a time.
    ///
    /// **A provider must never build a collection of its whole source.** A
    /// hundred-thousand-photo library costs about 7 KB per photo to hold as
    /// values, and the only photos this system keeps in memory are the ones in
    /// the queue. Everything else lives in the database — which is what the
    /// database is for. So enumeration pushes into `sink` as it walks and keeps
    /// nothing.
    ///
    /// The return value must distinguish "I looked and there is nothing" from
    /// "I could not look", because the scanner treats those completely
    /// differently: the first is a mass disappearance, the second is an
    /// unavailable source whose photos keep their deal history. Reaching that
    /// conclusion before streaming anything is normal — an unmounted volume is
    /// known to be unreachable before a single entry is produced.
    ///
    /// **The sink is `async` because it writes.** The scanner's sink batches
    /// what it is handed into database transactions, and a walk of a network
    /// folder does that thousands of times. Done synchronously from an async
    /// task, every contended batch parks a cooperative-pool thread — and four
    /// concurrent walks were enough to stop the agent answering picture requests
    /// at all on 2026-08-25. Suspending gives the thread back.
    func enumerate(
        _ source: Source,
        into sink: (DiscoveredPhoto) async throws -> Void
    ) async throws -> SourceReachability

    /// Is this one photo still in this source?
    ///
    /// **This is what guarantees a deleted photo is never shown again.** The
    /// periodic refresh would get there eventually, but "eventually" is up to a
    /// scan interval, and a user who has just deleted a picture specifically so
    /// they stop seeing it will not accept seeing it once more. Some reasons a
    /// person removes a photo are benign and some are not, and the ones that are
    /// not are the ones that matter.
    ///
    /// **Take the time to be right.** This is called on the path about to
    /// display a photo, but that path has a generous latency budget: nobody
    /// perceives variation in how long a picture takes to change, so a network
    /// round trip is an acceptable price for a correct answer. A provider should
    /// never return `.unknown` merely because answering properly would be slow —
    /// `.unknown` means the question genuinely cannot be settled right now,
    /// which is a claim about reachability rather than about effort.
    ///
    /// Answering `.unknown` when the truth is `.absent` is the expensive
    /// mistake, because it shows the photo.
    func existence(of externalID: String, in source: Source) async -> PhotoExistence

    /// Where the *source* stands, asked when one of its photographs could not be
    /// confirmed — which is the moment the answer changes what happens next.
    ///
    /// **A provider that cannot tell must never answer `.gone`.** Saying so
    /// deletes rows and bytes, and the cost of being wrong is a library thrown
    /// away over a permission prompt. The default below answers `.available`
    /// precisely because it is the answer that changes nothing.
    func availability(of source: Source) async -> SourceAvailability

    /// Writes the bytes for one photo to `destination`.
    ///
    /// Only called for photos whose storage is `.materialized`. A referenced
    /// photo is read in place, because copying a file that is always there is
    /// pure waste.
    func materialize(
        externalID: String,
        from source: Source,
        to destination: URL
    ) async throws -> MaterializedFile
}

/// Whether a source could be looked at, which is a different question from
/// whether it had anything in it.
public enum SourceReachability: Sendable, Equatable {
    case reachable
    /// The source itself is gone — volume unmounted, folder deleted, Photos
    /// library changed, permission revoked. Its photos keep their history.
    case unavailable(reason: String)

    public var unavailableReason: String? {
        switch self {
        case .reachable: nil
        case .unavailable(let reason): reason
        }
    }
}

extension SourceProvider {
    /// The answer that changes nothing, for a provider that has not been taught
    /// to tell the two kinds of missing apart.
    public func availability(of source: Source) async -> SourceAvailability { .available }

    /// The whole source as one array.
    ///
    /// A convenience for tests and for callers that already know the source is
    /// small. **Not for the scanner** — materialising the library is the thing
    /// the streaming form exists to avoid.
    public func enumerate(_ source: Source) async throws -> SourceEnumeration {
        var photos: [DiscoveredPhoto] = []
        let reachability = try await enumerate(source) { photo in photos.append(photo) }
        return SourceEnumeration(photos: photos, unavailableReason: reachability.unavailableReason)
    }
}

/// What materialization produced.
public struct MaterializedFile: Sendable, Equatable {
    public let url: URL
    public let byteSize: Int64

    public init(url: URL, byteSize: Int64) {
        self.url = url
        self.byteSize = byteSize
    }
}

public enum SourceProviderError: Error, CustomStringConvertible, Sendable {
    case wrongProvider(expected: SourceKind, got: SourceKind)
    case photoMissing(externalID: String)
    case notMaterializable(externalID: String)

    public var description: String {
        switch self {
        case .wrongProvider(let expected, let got):
            "provider for \(expected) was handed a \(got) source"
        case .photoMissing(let externalID):
            "no file for \(externalID)"
        case .notMaterializable(let externalID):
            "\(externalID) cannot be materialized"
        }
    }
}
