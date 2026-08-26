import Foundation
import PhotoGoRoundAgentAPI

/// The system photo library, as much of it as a provider needs.
///
/// **The seam exists because PhotoKit cannot be put in a test.** Exercising it
/// needs a real library, a real TCC grant, and somebody's actual photographs,
/// which between them make every interesting case — an album that vanished, an
/// asset whose original is in iCloud, a Live Photo whose resource list is a trap
/// — either unreachable or destructive to arrange. `FolderSourceProvider` sits
/// behind `FileAccess` for the same reason and this mirrors it deliberately.
///
/// **Nothing here is a PhotoKit type.** The protocol vends values, so a fake can
/// answer it without importing Photos and the provider's logic — which resource
/// to take, what counts as gone, when to refuse to guess — is exercised with no
/// library present at all. A seam that handed back `PHAsset` would move the
/// untestable part one layer up and change nothing.
public protocol PhotoLibrary: Sendable {

    /// What we are allowed to see. Read, never requested: `availability` is
    /// called from the scanner, on a timer, in a background process, and
    /// raising a TCC prompt from there is the unattributed prompt the whole
    /// design avoids. Asking is the service surface's job.
    var authorization: LibraryAuthorization { get async }

    /// The collection's title, or nil if it does not resolve.
    ///
    /// **Nil is not "deleted".** It is equally what a switched system library
    /// looks like, which is why the provider never answers `.gone` from it.
    func title(ofCollection identifier: String) async -> String?

    /// Every image in the collection, one at a time.
    ///
    /// Returns false when the collection does not resolve, which the provider
    /// reports as unavailable rather than empty — an album that lost every
    /// photograph and a library that was switched underneath us look identical
    /// from here and mean opposite things.
    ///
    /// **Videos never arrive.** They are excluded at the fetch by predicate, so
    /// they never enter the row set at all.
    @discardableResult
    func enumerateImages(
        inCollection identifier: String,
        _ body: (LibraryAsset) async throws -> Void
    ) async throws -> Bool

    /// Is this one asset still in the library?
    func assetExists(_ identifier: String) async -> Bool

    /// What an asset is made of, in the order the library lists them.
    ///
    /// Order is preserved because it is part of the hazard: on an edited Live
    /// Photo `.fullSizePairedVideo` sits immediately before `.fullSizePhoto`,
    /// so a rule that scans for the first "full size" anything takes a movie.
    func resources(ofAsset identifier: String) async -> [LibraryResource]

    /// Copies one resource's bytes to `destination` and returns what was
    /// written. Streams: a hundred-megabyte original is never held whole.
    func write(
        _ resource: LibraryResource, ofAsset identifier: String, to destination: URL
    ) async throws -> Int64
}

/// What the library will let us do, mapped off `PHAuthorizationStatus`.
public enum LibraryAuthorization: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case authorized
    /// An iOS concept macOS does not offer, but it is expressible and must not
    /// crash anything. Treated as authorized: a limited grant still returns
    /// whatever it returns.
    case limited

    /// Whether anything can be read at all.
    public var canRead: Bool { self == .authorized || self == .limited }
}

/// One asset, flattened.
///
/// The dimensions are here because they are the only free thing the library
/// tells us about an asset's bytes, and they are what a written original is
/// checked against — the spike's one measurement that could have invalidated
/// the whole design.
public struct LibraryAsset: Sendable, Equatable {
    public let identifier: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(identifier: String, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.identifier = identifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// A resource kind, matched **exactly**.
///
/// `other` carries the raw value rather than dropping it, so a resource type
/// this build has never heard of is visible in a log instead of silently
/// becoming a candidate.
public enum LibraryResourceKind: Sendable, Equatable, Hashable {
    case photo
    case fullSizePhoto
    case adjustmentData
    case pairedVideo
    case fullSizePairedVideo
    case other(Int)
}

public struct LibraryResource: Sendable, Equatable {
    public let kind: LibraryResourceKind
    public let uniformTypeIdentifier: String
    public let originalFilename: String

    public init(
        kind: LibraryResourceKind, uniformTypeIdentifier: String = "", originalFilename: String = ""
    ) {
        self.kind = kind
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.originalFilename = originalFilename
    }
}

public enum PhotoLibraryError: Error, CustomStringConvertible, Sendable {
    case notAuthorized
    case assetMissing(String)
    case noUsableResource(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .notAuthorized: "the Photos library is not readable"
        case .assetMissing(let id): "no asset \(id)"
        case .noUsableResource(let id): "\(id) has no photo resource"
        case .writeFailed(let reason): reason
        }
    }
}
