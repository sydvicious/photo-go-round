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

    public var isAbsent: Bool { self == .absent }
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

    /// What is in this source right now.
    ///
    /// Must distinguish "I looked and there is nothing" from "I could not look",
    /// because the scanner treats those completely differently: the first is a
    /// mass disappearance, the second is an unavailable source whose photos keep
    /// their deal history.
    func enumerate(_ source: Source) async throws -> SourceEnumeration

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
