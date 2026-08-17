import Foundation

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
