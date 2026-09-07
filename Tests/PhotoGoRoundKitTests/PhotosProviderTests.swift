import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// The Photos provider, exercised with no Photos library and no TCC grant.
///
/// Every case here is one PhotoKit makes expensive or impossible to arrange for
/// real: an album that vanished because somebody switched system libraries, a
/// grant that was refused, a Live Photo whose resource list has a movie sitting
/// where the photograph should be. That is what the `PhotoLibrary` seam is for.
@Suite("The Photos collection provider")
struct PhotosProviderTests {

    private let album = "DAD90FB7-1F24-463E-8688-A8504D7283C7/L0/040"

    private func library(
        authorization: LibraryAuthorization = .authorized,
        images: Int = 3,
        resources: [String: [LibraryResource]] = [:]
    ) -> FakePhotoLibrary {
        FakePhotoLibrary(
            authorization: authorization,
            titles: [album: "Favorites"],
            assets: [
                album: (0..<images).map {
                    LibraryAsset(identifier: "ASSET-\($0)/L0/001", pixelWidth: 4032, pixelHeight: 3024)
                }
            ],
            resources: resources
        )
    }

    // MARK: - Enumerate

    @Test("Every image arrives, materialized, with no byte size claimed")
    func enumerationStreamsTheAlbum() async throws {
        let provider = PhotosCollectionSourceProvider(library: library(images: 4))
        var found: [DiscoveredPhoto] = []
        let reach = try await provider.enumerate(photosSource(locator: album)) { found.append($0) }

        #expect(reach == .reachable)
        #expect(found.count == 4)
        #expect(found.allSatisfy { $0.mediaType == .image })
        // There is no path to reference; the bytes are ours only once copied.
        #expect(found.allSatisfy { $0.storage == .materialized })
        // `PHAsset` does not report one, and the only public way to learn it is
        // the fetch enumeration exists not to do. Nil is honest, not lazy.
        #expect(found.allSatisfy { $0.byteSize == nil })
        #expect(found.first?.externalID == "ASSET-0/L0/001")
    }

    @Test("An album that does not resolve is unavailable, never empty")
    func aVanishedAlbumIsUnavailable() async throws {
        // **The whole source goes dark as a unit.** Switching system libraries
        // fails every stored identifier at once, and reporting that as an empty
        // album would delete a library's worth of rows over it.
        let provider = PhotosCollectionSourceProvider(library: library())
        var found: [DiscoveredPhoto] = []
        let reach = try await provider.enumerate(photosSource(locator: "GONE/L0/040")) {
            found.append($0)
        }

        #expect(found.isEmpty)
        #expect(reach != .reachable)
        #expect(reach.unavailableReason != nil)
    }

    @Test("Without a grant nothing is enumerated and nothing is concluded")
    func refusedAccessIsUnavailable() async throws {
        for status in [LibraryAuthorization.denied, .restricted, .notDetermined] {
            let provider = PhotosCollectionSourceProvider(library: library(authorization: status))
            var found: [DiscoveredPhoto] = []
            let reach = try await provider.enumerate(photosSource(locator: album)) {
                found.append($0)
            }
            #expect(found.isEmpty)
            #expect(reach.unavailableReason != nil, "\(status) should not read as reachable")
        }
    }

    @Test("A source of the wrong kind is refused rather than mishandled")
    func wrongKindIsRefused() async {
        let provider = PhotosCollectionSourceProvider(library: library())
        let folder = Source(
            id: 2, uuid: "S2", kind: .folder, locator: "/tmp/x/",
            addedAt: Date(timeIntervalSince1970: 0))
        await #expect(throws: (any Error).self) {
            try await provider.enumerate(folder) { _ in }
        }
    }

    // MARK: - Existence

    @Test("A photograph that is there is present, and one that is not is absent")
    func existenceIsDefiniteWhenReadable() async {
        let provider = PhotosCollectionSourceProvider(library: library())
        let source = photosSource(locator: album)
        #expect(await provider.existence(of: "ASSET-1/L0/001", in: source) == .present)
        #expect(await provider.existence(of: "ASSET-99/L0/001", in: source) == .absent)
    }

    @Test("Without a grant, existence is unknown rather than absent")
    func existenceNeverGuessesAbsent() async {
        // **This is the one that costs somebody their photographs.** `.absent`
        // deletes the row and the cached bytes; saying it because the library
        // could not be read would throw away a library over a permission
        // prompt.
        let provider = PhotosCollectionSourceProvider(library: library(authorization: .denied))
        let answer = await provider.existence(of: "ASSET-1/L0/001", in: photosSource(locator: album))
        guard case .unknown = answer else {
            Issue.record("denied access answered \(answer) instead of unknown")
            return
        }
    }

    @Test("An album that does not resolve makes existence unknown, not absent")
    func existenceIsUnknownWhenTheAlbumIsMissing() async {
        // **The 2026-09-07 rebuild.** Photos renumbered two albums; every
        // stored identifier failed against a library that was perfectly
        // readable, and the answer was `.absent` for each — which deleted the
        // cached copies one at a time as they came up to be shown. The album
        // not resolving says nothing about its photographs: it is the same
        // fact `availability` calls offline, and it has to be *unknown* here.
        // Whether the asset happens to resolve on its own does not change that.
        let library = FakePhotoLibrary(
            titles: [:],
            assets: [album: [LibraryAsset(identifier: "ASSET-1/L0/001")]])
        let provider = PhotosCollectionSourceProvider(library: library)
        let source = photosSource(locator: album)

        for asset in ["ASSET-1/L0/001", "ASSET-99/L0/001"] {
            let answer = await provider.existence(of: asset, in: source)
            guard case .unknown(let reason) = answer else {
                Issue.record("a missing album answered \(answer) for \(asset) instead of unknown")
                continue
            }
            #expect(reason == "the album is not in this Photos library")
        }
    }

    // MARK: - Availability

    @Test("A resolvable album on a readable library is available")
    func availabilityIsPlain() async {
        let provider = PhotosCollectionSourceProvider(library: library())
        #expect(await provider.availability(of: photosSource(locator: album)) == .available)
    }

    @Test("An album that does not resolve is missing; a library that cannot be read is offline")
    func missingIsNotOffline() async {
        // The two are alike to everything that serves, fetches, or deals, and
        // unlike to a person: an album that is not there can be removed or
        // reconnected from the panel, a permission prompt cannot. So the
        // provider says which, and the reason is the one it gives everywhere.
        let readable = PhotosCollectionSourceProvider(library: library())
        #expect(
            await readable.availability(of: photosSource(locator: "GONE/L0/040"))
                == .missing(reason: "the album is not in this Photos library"))

        let denied = PhotosCollectionSourceProvider(library: library(authorization: .denied))
        guard case .offline = await denied.availability(of: photosSource(locator: album)) else {
            Issue.record("a denied library was not offline"); return
        }
    }

    // MARK: - Description

    @Test("An album describes itself by title, kind, and folders")
    func describeAnswersTheThreeFacts() async {
        let fake = FakePhotoLibrary(
            titles: [album: "Kids 2019"],
            collections: [
                LibraryCollection(identifier: album, title: "Kids 2019", kind: .userAlbum)
            ],
            folders: [album: ["Family", "Trips"]])
        let provider = PhotosCollectionSourceProvider(library: fake)

        #expect(
            await provider.describe(photosSource(locator: album))
                == SourceDescription(
                    title: "Kids 2019", collectionKind: "userAlbum", folders: ["Family", "Trips"]))
    }

    @Test("A smart album at the top level has no folders, and says so with an empty list")
    func describeSmartAlbum() async {
        let fake = FakePhotoLibrary(
            titles: [album: "Favorites"],
            collections: [LibraryCollection(identifier: album, title: "Favorites", kind: .favorites)])
        let provider = PhotosCollectionSourceProvider(library: fake)

        #expect(
            await provider.describe(photosSource(locator: album))
                == SourceDescription(title: "Favorites", collectionKind: "favorites", folders: []))
    }

    // MARK: - Successors

    private static let renumbered = "REBUILT-0000-0000-0000-000000000000/L0/041"

    /// A library after a rebuild: the album this suite's sources name is gone,
    /// and one or more albums stand where it was.
    private func rebuilt(_ collections: [LibraryCollection], folders: [String: [String]] = [:])
        -> PhotosCollectionSourceProvider
    {
        PhotosCollectionSourceProvider(
            library: FakePhotoLibrary(
                titles: Dictionary(uniqueKeysWithValues: collections.map { ($0.identifier, $0.title) }),
                collections: collections, folders: folders))
    }

    private func missingSource(_ description: SourceDescription) -> Source {
        Source(
            id: 1, uuid: "SOURCE-1", kind: .photosCollection, locator: album,
            description: description, addedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("A user album's successor is the one with its title in its folders, and nothing else")
    func aUserAlbumMatchesOnTitleAndFolders() async {
        let stored = SourceDescription(
            title: "Kids 2019", collectionKind: "userAlbum", folders: ["Family"])
        let provider = rebuilt(
            [
                LibraryCollection(identifier: Self.renumbered, title: "Kids 2019", kind: .userAlbum),
                LibraryCollection(identifier: "OTHER/L0/042", title: "Kids 2019", kind: .userAlbum),
                LibraryCollection(identifier: "OTHER/L0/043", title: "Kids 2020", kind: .userAlbum),
            ],
            folders: [Self.renumbered: ["Family"], "OTHER/L0/042": ["Archive"]])

        let found = await provider.successors(of: missingSource(stored))
        #expect(found.map(\.locator) == [Self.renumbered])
        #expect(
            found.first?.description
                == SourceDescription(title: "Kids 2019", collectionKind: "userAlbum", folders: ["Family"]))
    }

    @Test("Two albums of the same name in the same folder are two successors, and a person decides")
    func sameNameSamePlaceIsAmbiguous() async {
        let stored = SourceDescription(title: "Kids 2019", collectionKind: "userAlbum")
        let provider = rebuilt([
            LibraryCollection(identifier: "A/L0/1", title: "Kids 2019", kind: .userAlbum),
            LibraryCollection(identifier: "B/L0/2", title: "Kids 2019", kind: .userAlbum),
        ])

        #expect(await provider.successors(of: missingSource(stored)).count == 2)
    }

    @Test("Favorites is found by kind alone, whatever the system calls it")
    func aSingletonMatchesOnKind() async {
        // Apple names it, and the name follows the system language. There is
        // one per library, so the kind is the whole identity.
        let stored = SourceDescription(title: "Favorites", collectionKind: "favorites")
        let provider = rebuilt([
            LibraryCollection(identifier: "FAV/L0/9", title: "Favoriten", kind: .favorites),
            LibraryCollection(identifier: "USER/L0/1", title: "Favorites", kind: .userAlbum),
        ])

        #expect(await provider.successors(of: missingSource(stored)).map(\.locator) == ["FAV/L0/9"])
    }

    @Test("A media-type smart album is many per kind, so its title still decides")
    func mediaTypeMatchesOnTitle() async {
        let stored = SourceDescription(title: "Panoramas", collectionKind: "mediaType")
        let provider = rebuilt([
            LibraryCollection(identifier: "M/L0/1", title: "Live Photos", kind: .mediaType),
            LibraryCollection(identifier: "M/L0/2", title: "Panoramas", kind: .mediaType),
        ])

        #expect(await provider.successors(of: missingSource(stored)).map(\.locator) == ["M/L0/2"])
    }

    @Test("A source with no stored name has no successor, and an unreadable library offers none")
    func noDescriptionNoSuccessor() async {
        let provider = rebuilt([
            LibraryCollection(identifier: Self.renumbered, title: "040", kind: .userAlbum)
        ])
        // The two albums that started this: added before names were stored.
        // Their identifier's tail is not a name and must not be matched as one.
        #expect(await provider.successors(of: photosSource(locator: album)).isEmpty)

        let denied = PhotosCollectionSourceProvider(
            library: FakePhotoLibrary(
                authorization: .denied,
                titles: [Self.renumbered: "Kids 2019"],
                collections: [
                    LibraryCollection(identifier: Self.renumbered, title: "Kids 2019", kind: .userAlbum)
                ]))
        let stored = SourceDescription(title: "Kids 2019", collectionKind: "userAlbum")
        #expect(await denied.successors(of: missingSource(stored)).isEmpty)
    }

    @Test("An album that does not resolve has no description, and neither does an unreadable library")
    func describeAnswersNothingItCannotSee() async {
        let provider = PhotosCollectionSourceProvider(library: library())
        #expect(await provider.describe(photosSource(locator: "GONE/L0/040")) == nil)

        let denied = PhotosCollectionSourceProvider(library: library(authorization: .denied))
        #expect(await denied.describe(photosSource(locator: album)) == nil)
    }

    @Test("Nothing this provider can be asked ever answers gone")
    func availabilityIsNeverGone() async {
        // Telling a deleted album from a switched library needs to know *which*
        // library we are talking to, which has no public answer — so the
        // expensive mistake is unavailable to us by construction, and this is
        // the assertion that keeps it that way.
        let cases: [FakePhotoLibrary] = [
            library(),
            library(authorization: .denied),
            library(authorization: .restricted),
            library(authorization: .notDetermined),
            library(authorization: .limited),
        ]
        for fake in cases {
            let provider = PhotosCollectionSourceProvider(library: fake)
            for locator in [album, "GONE/L0/040"] {
                let answer = await provider.availability(of: photosSource(locator: locator))
                if case .gone = answer {
                    Issue.record(
                        "answered gone for \(locator) at \((try? await fake.authorization) as Any)")
                }
            }
        }
    }

    @Test("A limited grant reads like an authorized one")
    func limitedIsUsable() async {
        // An iOS concept macOS does not offer, but it is expressible and a
        // limited grant still returns whatever it returns.
        let provider = PhotosCollectionSourceProvider(library: library(authorization: .limited))
        #expect(await provider.availability(of: photosSource(locator: album)) == .available)
    }

    // MARK: - What to call it

    @Test("An album is named by the library, because nothing else can name it")
    func theAlbumNamesItself() async {
        // `A1B2C3D4-.../L0/040` renders as `040` under a last-path-component
        // rule, which is worse than the raw identifier because it looks like it
        // means something. Only the agent can ask what an album is called.
        let provider = PhotosCollectionSourceProvider(library: library())
        #expect(await provider.title(of: photosSource(locator: album)) == "Favorites")
    }

    @Test("An album that does not resolve has no name to give")
    func aVanishedAlbumIsNameless() async {
        let provider = PhotosCollectionSourceProvider(library: library())
        #expect(await provider.title(of: photosSource(locator: "GONE/L0/040")) == nil)
    }

    @Test("Without a grant there is no name either")
    func anUnreadableLibraryNamesNothing() async {
        let provider = PhotosCollectionSourceProvider(library: library(authorization: .denied))
        #expect(await provider.title(of: photosSource(locator: album)) == nil)
    }

    @Test("A path names itself, so a folder provider offers nothing")
    func fileBackedProvidersDoNotName() async {
        // The default on the protocol, and the reason it is nil rather than the
        // leaf: a folder is named by its last component and nothing the agent
        // could add would improve on it.
        let provider = FolderSourceProvider(fileAccess: UnsandboxedFileAccess())
        let folder = Source(
            id: 3, uuid: "S3", kind: .folder, locator: "/tmp/pictures/",
            addedAt: Date(timeIntervalSince1970: 0))
        #expect(await provider.title(of: folder) == nil)
    }

    // MARK: - Materialize, and the resource that must never be taken

    private func materialize(
        _ resources: [LibraryResource]
    ) async throws -> (FakePhotoLibrary, MaterializedFile) {
        let fake = library(resources: ["ASSET-0/L0/001": resources])
        let provider = PhotosCollectionSourceProvider(library: fake)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "pgr-materialize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let file = try await provider.materialize(
            externalID: "ASSET-0/L0/001", from: photosSource(locator: album), to: destination)
        return (fake, file)
    }

    @Test("An edited photograph gives up its edited render")
    func editedTakesFullSizePhoto() async throws {
        let (fake, file) = try await materialize([
            LibraryResource(kind: .photo, originalFilename: "014_14.JPG"),
            LibraryResource(kind: .adjustmentData, originalFilename: "Adjustments.plist"),
            LibraryResource(kind: .fullSizePhoto, originalFilename: "FullSizeRender.jpeg"),
        ])
        #expect(fake.written.map(\.resource.kind) == [.fullSizePhoto])
        #expect(file.byteSize == 1024)
    }

    @Test("An unedited photograph gives up its original")
    func uneditedTakesPhoto() async throws {
        let (fake, _) = try await materialize([
            LibraryResource(kind: .photo, originalFilename: "IMG_0023.JPG")
        ])
        #expect(fake.written.map(\.resource.kind) == [.photo])
    }

    @Test("An edited Live Photo does not hand back a movie")
    func theLivePhotoTrap() async throws {
        // The list PhotoKit actually returned on 2026-08-25. Two of the five
        // resources are QuickTime movies, and `.fullSizePairedVideo` sits
        // immediately before `.fullSizePhoto` and is called `FullSizeRender.mov`
        // against the photograph's `FullSizeRender.heic`. Scanning for the first
        // "full size" anything, taking the last resource, or matching a filename
        // all yield the movie.
        let (fake, _) = try await materialize(FakePhotoLibrary.editedLivePhoto)
        let taken = try #require(fake.written.first?.resource)
        #expect(taken.kind == .fullSizePhoto)
        #expect(taken.originalFilename == "FullSizeRender.heic")
        #expect(taken.uniformTypeIdentifier == "public.heic")
    }

    @Test("An unedited Live Photo takes the still, not the paired video")
    func uneditedLivePhotoTakesTheStill() async throws {
        let (fake, _) = try await materialize(FakePhotoLibrary.uneditedLivePhoto)
        #expect(fake.written.map(\.resource.kind) == [.photo])
    }

    @Test("Nothing photographic means a refusal, not a movie")
    func noPhotoResourceIsAnError() async {
        await #expect(throws: (any Error).self) {
            _ = try await materialize([
                LibraryResource(kind: .pairedVideo, originalFilename: "IMG.MOV"),
                LibraryResource(kind: .fullSizePairedVideo, originalFilename: "FullSizeRender.mov"),
                LibraryResource(kind: .adjustmentData, originalFilename: "Adjustments.plist"),
                LibraryResource(kind: .other(9), originalFilename: "mystery"),
            ])
        }
    }

    @Test("The rule is order-independent, so a reshuffled list picks the same one")
    func orderDoesNotDecide() {
        // The real list is ordered, and the current order is what makes the trap
        // dangerous. The *rule* must not depend on it either way.
        let shuffled = FakePhotoLibrary.editedLivePhoto.reversed()
        let chosen = PhotosCollectionSourceProvider.preferredResource(in: Array(shuffled))
        #expect(chosen?.kind == .fullSizePhoto)
    }
}
