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
        let authorization: LibraryAuthorization
        do {
            authorization = try await library.authorization
        } catch {
            return .unavailable(reason: Self.reason(error))
        }
        guard authorization.canRead else {
            return .unavailable(reason: Self.authorizationReason(authorization))
        }

        let resolved: Bool
        do {
            resolved = try await library.enumerateImages(inCollection: source.locator) { asset in
                try await sink(
                    DiscoveredPhoto(
                        externalID: asset.identifier,
                        // By construction: videos are excluded at the fetch.
                        mediaType: .image,
                        // **Always.** There is no path to reference — a Photos
                        // asset's bytes are ours only once we have copied them.
                        storage: .materialized,
                        // Honestly unknown. `PHAsset` does not report a byte
                        // size, and the only public way to learn one is to fetch
                        // the resource, which is the expensive thing enumeration
                        // exists not to do. The cache accounts for bytes at
                        // materialize time, where the number is real.
                        byteSize: nil
                    ))
            }
        } catch let error as PhotoLibraryError where error.isNoAnswer {
            // **Unavailable, not empty, and not missing.** A library that did
            // not answer has said nothing about this album; treating the silence
            // as an empty enumeration would delete a library's worth of rows,
            // which is the same mistake as reading a switched library as an
            // emptied one.
            return .unavailable(reason: error.sentence)
        }
        guard resolved else {
            return .unavailable(reason: Self.albumMissingReason)
        }
        return .reachable
    }

    /// What to put in front of a person when the library would not answer.
    ///
    /// **The readable form, not the log's.** This lands in a source's
    /// `unavailableReason`, which the Settings panel draws in a column beside
    /// the album's name — so it has to be a sentence rather than the call that
    /// went unanswered and the bound it missed. Those are in the log, once, at
    /// the moment they happened.
    static func reason(_ error: any Error) -> String {
        if let library = error as? PhotoLibraryError { return library.sentence }
        return String(describing: error)
    }

    /// What every question about an album that does not resolve answers, so
    /// that enumerating, checking, and asking after availability all say the
    /// same thing about the same fact.
    static let albumMissingReason = "the album is not in this Photos library"

    // MARK: - Existence

    /// Is this one photograph still in the library?
    ///
    /// **`.absent` is only ever said when the library was readable and the
    /// album resolved.** Answering it while the library cannot be reached would
    /// delete photographs over a permission prompt; answering `.unknown` when
    /// the truth is `.absent` shows a picture somebody deleted, and some
    /// reasons a person deletes a photograph are not benign. The scanner
    /// resolves the tie by asking `availability` next.
    ///
    /// **The album is asked before the photograph.** Until 2026-09-07 only the
    /// library was, and a Photos rebuild that renumbered two albums failed
    /// every stored identifier against a library that was perfectly readable —
    /// so each cached photograph was called absent and deleted as its turn came.
    /// An album that is not there is the same fact `availability` reports as
    /// offline, and it says nothing about the photographs: they are served out
    /// of the cache and their rows stay until the person removes the album.
    /// See `Missing Albums Plan.md`.
    ///
    /// **A library that did not answer is `.unknown`, always.** `.absent`
    /// deletes a photograph and the cached bytes behind it; it is only ever said
    /// when the library was readable, the album resolved, and the asset was
    /// looked for and not found. Every silence on the way there is `.unknown`,
    /// which shows the picture again and costs nothing.
    public func existence(of externalID: String, in source: Source) async -> PhotoExistence {
        do {
            let authorization = try await library.authorization
            guard authorization.canRead else {
                return .unknown(reason: Self.authorizationReason(authorization))
            }
            guard try await library.title(ofCollection: source.locator) != nil else {
                return .unknown(reason: Self.albumMissingReason)
            }
            return try await library.assetExists(externalID) ? .present : .absent
        } catch {
            return .unknown(reason: Self.reason(error))
        }
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
        do {
            let authorization = try await library.authorization
            guard authorization.canRead else {
                return .offline(reason: Self.authorizationReason(authorization))
            }
            guard try await library.title(ofCollection: source.locator) != nil else {
                // `.missing` rather than `.offline` since 2026-09-07. Everything
                // that serves, fetches, or deals treats the two alike; the panel
                // does not, because this is the one a person can act on.
                return .missing(reason: Self.albumMissingReason)
            }
            return .available
        } catch {
            // **`.offline`, and never `.missing`. This is the whole point of the
            // seam being able to say "I did not get an answer".**
            //
            // `.missing` is what puts *Remove missing albums* in front of
            // somebody — a button that removes the source, its photograph rows,
            // and their cached bytes. A library that is slow, rebuilding, or
            // wedged must not be able to reach it. Reading silence as *the album
            // is not there* is precisely how a migration in progress turns into
            // a deletion.
            return .offline(reason: Self.reason(error))
        }
    }

    /// The album's own name, which is the only readable thing about it.
    ///
    /// Computed by the agent because the agent is the only process that can ask
    /// PhotoKit — which is the same reason the source endpoint exists at all
    /// for kinds the app cannot see.
    /// Nil when the library will not answer, which the endpoint reads as *use
    /// the name we stored*. That is the right answer here: the stored name is
    /// what this album was called last time anybody could see it.
    public func title(of source: Source) async -> String? {
        // Authorization first, as everywhere else here: asking an unreadable
        // library what an album is called is a round trip whose answer is
        // already known.
        guard (try? await library.authorization)?.canRead == true,
            let title = try? await library.title(ofCollection: source.locator)
        else { return nil }
        return title.isEmpty ? nil : title
    }

    /// The album's title, kind, and folder path as the library reports them
    /// now, or nil when it does not resolve.
    ///
    /// Two listing calls rather than one lookup, because PhotoKit has no
    /// "this collection's folders" question — the folder tree is walked from
    /// the top. Both are the cheap kind of call the catalog makes on every
    /// picker open: milliseconds, not the half-minute that counting costs.
    /// Nil when the library will not answer, which every caller reads as
    /// *leave the stored description alone*. Overwriting a name and folder path
    /// with what a silent library did not say is how a source loses the only
    /// thing that could later match it to its successor.
    public func describe(_ source: Source) async -> SourceDescription? {
        guard (try? await library.authorization)?.canRead == true else { return nil }
        guard
            let listed = try? await library.collections(),
            let collection = listed.first(where: { $0.identifier == source.locator })
        else { return nil }
        let folders = (try? await library.folderPaths())?[source.locator] ?? []
        return SourceDescription(
            title: collection.title, collectionKind: collection.kind.rawValue, folders: folders)
    }

    // MARK: - Reconnecting

    /// Every collection in the library now that the stored description names,
    /// by `matches(_:folders:to:)`. A source with no description — added
    /// before names were stored — matches nothing, and says so with an empty
    /// list rather than by guessing from an identifier's tail.
    /// Empty when the library will not answer — which reads as *nothing to
    /// reconnect to*, so the panel offers no button rather than a wrong one.
    public func successors(of source: Source) async -> [SourceMatch] {
        guard let description = source.description,
            (try? await library.authorization)?.canRead == true,
            let folders = try? await library.folderPaths(),
            let listed = try? await library.collections()
        else { return [] }
        return listed.compactMap { collection in
            let path = folders[collection.identifier] ?? []
            guard Self.matches(collection, folders: path, to: description) else { return nil }
            return SourceMatch(
                locator: collection.identifier,
                description: SourceDescription(
                    title: collection.title, collectionKind: collection.kind.rawValue, folders: path))
        }
    }

    /// **Exact, or it is not a match.** The kind first, always. For a kind a
    /// library holds one of, that is the whole test — Favorites is Favorites
    /// whatever the system language calls it. For every other kind the title
    /// and the folder path must both be equal, because that is how Photos
    /// itself tells two albums of the same name apart.
    static func matches(
        _ collection: LibraryCollection, folders: [String], to description: SourceDescription
    ) -> Bool {
        guard collection.kind.rawValue == description.collectionKind else { return false }
        if collection.kind.isSingleton { return true }
        return collection.title == description.title && folders == description.folders
    }

    // MARK: - Materialize

    public func materialize(
        externalID: String, from source: Source, to destination: URL
    ) async throws -> MaterializedFile {
        guard try await library.authorization.canRead else {
            throw PhotoLibraryError.notAuthorized
        }
        let resources = try await library.resources(ofAsset: externalID)
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
