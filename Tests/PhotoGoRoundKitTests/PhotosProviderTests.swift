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

    // MARK: - Availability

    @Test("A resolvable album on a readable library is available")
    func availabilityIsPlain() async {
        let provider = PhotosCollectionSourceProvider(library: library())
        #expect(await provider.availability(of: photosSource(locator: album)) == .available)
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
                    Issue.record("answered gone for \(locator) at \(await fake.authorization)")
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
