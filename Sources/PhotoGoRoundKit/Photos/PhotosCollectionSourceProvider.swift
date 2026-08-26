import Foundation
import PhotoGoRoundAgentAPI

/// An album or smart album from the system Photos library.
///
/// The first source kind that is not a path, which is most of why it exists:
/// every architectural claim this project has made about a non-file source —
/// that a new kind is a new provider rather than a migration, that the source
/// endpoint exists for kinds the app cannot see — was unproven until one did.
///
/// **All four operations are decided here and none of them touch PhotoKit.**
/// What the library can answer is behind `PhotoLibrary`; what those answers
/// *mean* is this file, and it is the part that can be wrong in ways that cost
/// somebody their photographs.
public struct PhotosCollectionSourceProvider: SourceProvider {
    public let kind = SourceKind.photosCollection
    private let library: any PhotoLibrary

    public init(library: any PhotoLibrary) {
        self.library = library
    }

    // MARK: - Enumerate

    /// Streams the collection's images into the sink.
    ///
    /// **An empty result is the library-switch case, not an empty album.**
    /// Switching system libraries fails every stored identifier at once, and
    /// treating that as "the album is empty" would delete a library's worth of
    /// rows over it. So a collection that does not resolve is `.unavailable`
    /// and the source goes dark as a unit, which is what `PLAN.md` requires.
    public func enumerate(
        _ source: Source,
        into sink: (DiscoveredPhoto) async throws -> Void
    ) async throws -> SourceReachability {
        guard source.kind == kind else {
            throw SourceProviderError.wrongProvider(expected: kind, got: source.kind)
        }
        guard await library.authorization.canRead else {
            return .unavailable(reason: Self.authorizationReason(await library.authorization))
        }

        let resolved = try await library.enumerateImages(inCollection: source.locator) { asset in
            try await sink(
                DiscoveredPhoto(
                    externalID: asset.identifier,
                    // By construction: videos are excluded at the fetch.
                    mediaType: .image,
                    // **Always.** There is no path to reference — a Photos
                    // asset's bytes are ours only once we have copied them.
                    storage: .materialized,
                    // Honestly unknown. `PHAsset` does not report a byte size,
                    // and the only public way to learn one is to fetch the
                    // resource, which is the expensive thing enumeration exists
                    // not to do. The cache accounts for bytes at materialize
                    // time, where the number is real.
                    byteSize: nil
                ))
        }
        guard resolved else {
            return .unavailable(reason: "the album is not in this Photos library")
        }
        return .reachable
    }

    // MARK: - Existence

    /// Is this one photograph still in the library?
    ///
    /// **`.absent` is only ever said when the library was readable.** Answering
    /// it while the library cannot be reached would delete photographs over a
    /// permission prompt; answering `.unknown` when the truth is `.absent`
    /// shows a picture somebody deleted, and some reasons a person deletes a
    /// photograph are not benign. The scanner resolves the tie by asking
    /// `availability` next.
    public func existence(of externalID: String, in source: Source) async -> PhotoExistence {
        let authorization = await library.authorization
        guard authorization.canRead else {
            return .unknown(reason: Self.authorizationReason(authorization))
        }
        return await library.assetExists(externalID) ? .present : .absent
    }

    // MARK: - Availability

    /// **`.gone` is never returned, and that is total.**
    ///
    /// The only thing that would justify it is knowing an album was deleted
    /// while the library was demonstrably present — and telling that apart from
    /// a switched library needs to know *which* library we are talking to,
    /// which has no public answer. So the expensive mistake is unavailable to
    /// us by construction, which is a good place to be.
    public func availability(of source: Source) async -> SourceAvailability {
        let authorization = await library.authorization
        guard authorization.canRead else {
            return .offline(reason: Self.authorizationReason(authorization))
        }
        guard await library.title(ofCollection: source.locator) != nil else {
            return .offline(reason: "the album is not in this Photos library")
        }
        return .available
    }

    /// The album's own name, which is the only readable thing about it.
    ///
    /// Computed by the agent because the agent is the only process that can ask
    /// PhotoKit — which is the same reason the source endpoint exists at all
    /// for kinds the app cannot see.
    public func title(of source: Source) async -> String? {
        guard await library.authorization.canRead else { return nil }
        let title = await library.title(ofCollection: source.locator)
        return (title?.isEmpty ?? true) ? nil : title
    }

    // MARK: - Materialize

    public func materialize(
        externalID: String, from source: Source, to destination: URL
    ) async throws -> MaterializedFile {
        guard await library.authorization.canRead else { throw PhotoLibraryError.notAuthorized }
        let resources = await library.resources(ofAsset: externalID)
        guard !resources.isEmpty else { throw PhotoLibraryError.assetMissing(externalID) }
        guard let chosen = Self.preferredResource(in: resources) else {
            throw PhotoLibraryError.noUsableResource(externalID)
        }
        let bytes = try await library.write(chosen, ofAsset: externalID, to: destination)
        return MaterializedFile(url: destination, byteSize: bytes)
    }

    /// `.fullSizePhoto` when present, `.photo` otherwise, **matched on exact
    /// kind and nothing else**.
    ///
    /// The first is the edited render, the second the original. The rule looks
    /// obvious and the way to get it wrong is not: an edited Live Photo's
    /// resources are
    ///
    ///     .photo · .adjustmentData · .pairedVideo · .fullSizePairedVideo · .fullSizePhoto
    ///
    /// so `.fullSizePairedVideo` sits **immediately before** the one we want and
    /// is called `FullSizeRender.mov` against the photo's `FullSizeRender.heic`.
    /// Any rule that scans for a "full size" variant, takes the last resource,
    /// picks the largest, or matches on a filename takes a QuickTime movie.
    ///
    /// What that costs is worth stating, because it is not a visible failure:
    /// the movie lands in the cache under a key the renderer hands to
    /// `CGImageSourceCreateThumbnailAtIndex`, which returns nil, which retires
    /// the photograph as unrenderable after three attempts. The symptom is
    /// photographs quietly disappearing, three deals at a time, with nothing in
    /// the log pointing at Live Photos.
    static func preferredResource(in resources: [LibraryResource]) -> LibraryResource? {
        resources.first { $0.kind == .fullSizePhoto } ?? resources.first { $0.kind == .photo }
    }

    private static func authorizationReason(_ status: LibraryAuthorization) -> String {
        switch status {
        case .authorized, .limited: "readable"
        case .notDetermined: "Photos access has not been granted yet"
        case .denied: "Photos access was denied — System Settings › Privacy & Security › Photos"
        case .restricted: "Photos access is restricted on this Mac"
        }
    }
}
