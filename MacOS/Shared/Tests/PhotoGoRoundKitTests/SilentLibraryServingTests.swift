import Foundation
import Synchronization
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// Serving a photograph we already hold, while Photos will not answer.
///
/// **Measured 2026-09-16.** `photolibraryd` stopped answering the agent at about
/// 12:15 and every question — `authorization`, `title`, `assetExists` — waited
/// out its ten-second bound. Serving asks those questions about the one card
/// going out, so a request whose head card was a Photos photograph took tens of
/// seconds (one took 58) against a client that gives up at five. The app and the
/// screensaver both said *the agent on 52133 said nothing within 5 seconds*,
/// about an agent holding hundreds of cached pictures it could have shown.
///
/// The bounds here are the agent's own, not shortened ones, because the fault is
/// the relationship between them and the client's.
@Suite("Serving while Photos will not answer")
struct SilentLibraryServingTests {

    /// What a picture client waits before deciding nobody is home.
    static let clientGivesUp = ServiceTiming.pictureReadLimit

    private let album = "DAD90FB7-1F24-463E-8688-A8504D7283C7/L0/040"
    private let asset = "ASSET-0/L0/001"

    /// A library that answers until it is told to stop, and then answers nothing.
    final class GoesSilent: PhotoLibrary, @unchecked Sendable {
        private let answering: FakePhotoLibrary
        private let silent = Mutex(false)

        init(_ answering: FakePhotoLibrary) { self.answering = answering }

        func silence() { silent.withLock { $0 = true } }

        private func hangIfSilent() async throws {
            guard silent.withLock({ $0 }) else { return }
            try await Task.sleep(for: .seconds(300))
        }

        var authorization: LibraryAuthorization {
            get async throws {
                try await hangIfSilent()
                return try await answering.authorization
            }
        }
        func requestAuthorization() async -> LibraryAuthorization {
            try? await hangIfSilent()
            return await answering.requestAuthorization()
        }
        func collections() async throws -> [LibraryCollection] {
            try await hangIfSilent()
            return try await answering.collections()
        }
        func folderPaths() async throws -> [String: [String]] {
            try await hangIfSilent()
            return try await answering.folderPaths()
        }
        func imageCount(ofCollection identifier: String) async throws -> Int? {
            try await hangIfSilent()
            return try await answering.imageCount(ofCollection: identifier)
        }
        func title(ofCollection identifier: String) async throws -> String? {
            try await hangIfSilent()
            return try await answering.title(ofCollection: identifier)
        }
        func assetExists(_ identifier: String) async throws -> Bool {
            try await hangIfSilent()
            return try await answering.assetExists(identifier)
        }
        func resources(ofAsset identifier: String) async throws -> [LibraryResource] {
            try await hangIfSilent()
            return try await answering.resources(ofAsset: identifier)
        }
        @discardableResult
        func enumerateImages(
            inCollection identifier: String, _ body: (LibraryAsset) async throws -> Void
        ) async throws -> Bool {
            try await hangIfSilent()
            return try await answering.enumerateImages(inCollection: identifier, body)
        }
        func write(
            _ resource: LibraryResource, ofAsset identifier: String, to destination: URL
        ) async throws -> Int64 {
            try await hangIfSilent()
            return try await answering.write(resource, ofAsset: identifier, to: destination)
        }
    }

    @Test("A cached Photos picture goes out before the client gives up")
    func aHeldPictureIsServedInTime() async throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-silent-serve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let photos = GoesSilent(
            FakePhotoLibrary(
                titles: [album: "Favorites"],
                assets: [album: [LibraryAsset(identifier: asset)]],
                resources: [asset: [LibraryResource(kind: .photo, originalFilename: "IMG_0042.HEIC")]]))
        let library = try TestLibrary()
        let root = directory.appending(path: "cache")
        let bytes = PhotoStore(root: root)
        let sources = SourceStore(
            database: library.database,
            providers: [PhotosCollectionSourceProvider(library: BoundedPhotoLibrary(photos))],
            bytes: bytes)
        let cache = PhotoCache(database: library.database, root: root, sources: sources, store: bytes)
        try await cache.prepare()

        let source = try sources.add(kind: .photosCollection, locator: album)
        _ = await sources.refresh(source)
        await #expect(try cache.deal())
        let card = try #require(try cache.queue.peek().first)
        #expect(try await cache.cache(photoID: card.id), "the picture is held before Photos goes quiet")

        photos.silence()

        let clock = ContinuousClock()
        let started = clock.now
        let served = try await cache.serve()
        let took = clock.now - started

        #expect(served?.card.id == card.id, "the held picture is the one that goes out")
        #expect(
            took < Self.clientGivesUp,
            "serving took \(took) against a client that gives up at \(Self.clientGivesUp)")
    }

    /// **The picture is kept, not dropped.** Running out the budget is
    /// *unknown*, and the row, the bytes, and the log line all say so.
    @Test("A picture served unchecked stays in the pool and says why")
    func anUncheckedPictureIsKeptAndNamed() async throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-silent-serve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let photos = GoesSilent(
            FakePhotoLibrary(
                titles: [album: "Favorites"],
                assets: [album: [LibraryAsset(identifier: asset)]],
                resources: [asset: [LibraryResource(kind: .photo, originalFilename: "IMG_0042.HEIC")]]))
        let library = try TestLibrary()
        let root = directory.appending(path: "cache")
        let bytes = PhotoStore(root: root)
        let sources = SourceStore(
            database: library.database,
            providers: [PhotosCollectionSourceProvider(library: BoundedPhotoLibrary(photos))],
            bytes: bytes)
        var cache = PhotoCache(database: library.database, root: root, sources: sources, store: bytes)
        let heard = ServeWalkTests.Heard()
        cache.log = heard.log
        try await cache.prepare()

        let source = try sources.add(kind: .photosCollection, locator: album)
        _ = await sources.refresh(source)
        await #expect(try cache.deal())
        let card = try #require(try cache.queue.peek().first)
        #expect(try await cache.cache(photoID: card.id))

        photos.silence()
        _ = try await cache.serve()

        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 1)
        await #expect(try cache.residentURL(forPhoto: card.id) != nil, "the cached bytes are still held")
        #expect(
            heard.lines.contains { $0.contains("unconfirmed (\(PhotoCache.checkUnanswered))") },
            "the SERVE: line did not say why: \(heard.lines)")
    }
}
