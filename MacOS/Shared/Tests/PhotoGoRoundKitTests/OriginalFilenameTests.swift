import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// A Photos photograph's name, recorded when its original is fetched and
/// carried on every card dealt of it afterwards.
///
/// Through `PhotoCache.cache` rather than the provider alone, because the
/// provider knowing the name was never the problem: it always did, and threw it
/// away. What this pins is that the fetch keeps it, and that the card a request
/// serves next is the one that says it.
@Suite("A Photos photograph's name")
struct OriginalFilenameTests {

    private let album = "DAD90FB7-1F24-463E-8688-A8504D7283C7/L0/040"
    private let asset = "ASSET-0/L0/001"

    private struct Fixture {
        let directory: URL
        let library: TestLibrary
        let cache: PhotoCache
        let heard = ServeWalkTests.Heard()

        init(album: String, asset: String, resources: [LibraryResource]) async throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-name-\(UUID().uuidString)")
            library = try TestLibrary()
            let photos = FakePhotoLibrary(
                titles: [album: "Holiday"],
                assets: [album: [LibraryAsset(identifier: asset)]],
                resources: [asset: resources])
            let root = directory.appending(path: "cache")
            let bytes = PhotoStore(root: root)
            let sources = SourceStore(
                database: library.database,
                providers: [PhotosCollectionSourceProvider(library: photos)],
                bytes: bytes)
            var cache = PhotoCache(
                database: library.database, root: root, sources: sources, store: bytes)
            cache.log = heard.log
            try await cache.prepare()
            self.cache = cache

            let source = try sources.add(kind: .photosCollection, locator: album)
            _ = await sources.refresh(source)
            await #expect(try cache.deal())
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }

        var head: DeckCard? { try? cache.queue.peek().first }
    }

    @Test("Fetching a Photos original records its name, and the card dealt of it says so")
    func fetchRecordsTheName() async throws {
        let fixture = try await Fixture(
            album: album, asset: asset,
            resources: [
                LibraryResource(kind: .photo, originalFilename: "IMG_0042.HEIC"),
                LibraryResource(kind: .fullSizePhoto, originalFilename: "FullSizeRender.heic"),
            ])
        defer { fixture.cleanUp() }

        let before = try #require(fixture.head)
        #expect(before.storage == .materialized)
        #expect(before.originalFilename == nil, "nothing has been fetched, so nothing is known")

        #expect(try await fixture.cache.cache(photoID: before.id))

        let after = try #require(fixture.head)
        #expect(after.originalFilename == "IMG_0042.HEIC")
        #expect(after.spokenName == "IMG_0042.HEIC (\(asset))")
        // The fetch's own line names it, from what the fetch just learned.
        #expect(
            fixture.heard.lines.contains { $0.hasPrefix("CACHE: IMG_0042.HEIC (\(asset)) (source ") },
            "the CACHE: line did not name the photograph: \(fixture.heard.lines)")
    }

    @Test("A photograph Photos gives no name is still named by its identifier after the fetch")
    func unnamedStaysAnIdentifier() async throws {
        let fixture = try await Fixture(
            album: album, asset: asset, resources: [LibraryResource(kind: .photo)])
        defer { fixture.cleanUp() }

        let card = try #require(fixture.head)
        #expect(try await fixture.cache.cache(photoID: card.id))

        #expect(fixture.head?.originalFilename == nil)
        #expect(fixture.head?.spokenName == asset)
    }
}
