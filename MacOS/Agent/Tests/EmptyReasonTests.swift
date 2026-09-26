import Foundation
import Testing

@testable import PhotosGoRoundAgentAPI
@testable import PhotosGoRoundKit
@testable import PhotosGoRoundServer

/// What an empty answer says about why it is empty.
///
/// A bare `204` means *nothing right now*, and a client waits a streak of them
/// before it says anything. When the agent knows the answer outright it says
/// so on the header, and the surface puts its words up at once. Syd,
/// 2026-09-26: *Please Add Photos* with no sources, and *No Photos Available*
/// when there is truly nothing to show — offline sources contributing what the
/// cache holds of them, and nothing else.
@Suite("Why an answer is empty", .timeLimit(.minutes(2)))
struct EmptyReasonTests {

    private final class Library {
        let directory: URL
        let endpoint: PictureEndpoint
        let database: Database
        let sources: SourceStore

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-empty-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory.appending(path: "photos"), withIntermediateDirectories: true)
            let path = directory.appending(path: "photosgoround.sqlite").path(percentEncoded: false)
            database = try Database(path: path)
            try Migrator.migrate(database)
            sources = SourceStore(database: database)
            let cacheRoot = directory.appending(path: "cache")
            endpoint = PictureEndpoint(
                databasePath: path, cacheRoot: cacheRoot,
                preferences: Preferences(defaults: scratchSuite("empty")),
                store: PhotoStore(root: cacheRoot),
                queueRanShort: {},
                log: { _ in }
            ).awaitingResizes()
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        var photos: URL { directory.appending(path: "photos") }

        /// The folder as a source, holding whatever has been written into it.
        func addFolder() throws -> Source {
            try sources.add(kind: .folder, locator: photos.path(percentEncoded: false))
        }

        /// A file the folder walk will take for a photograph. Nothing decodes
        /// it, which does not matter: nothing here is served.
        func addPhotoFile() throws {
            try Data("not a picture".utf8).write(to: photos.appending(path: "one.png"))
        }

        func request() async -> HTTPListener.Response {
            await endpoint.route(
                HTTPListener.parse("GET /v1/next?consumer=app&w=200&h=200 HTTP/1.1")!)
        }
    }

    // MARK: - No sources

    @Test("With no sources the empty answer says so")
    func noSourcesIsSaid() async throws {
        let library = try Library()

        let response = await library.request()

        #expect(response.status == 204)
        #expect(response.headers[EmptyReason.headerField] == EmptyReason.noSources.rawValue)
    }

    /// Nothing is selected when every source is turned off.
    @Test("Sources that are all disabled count as no sources")
    func disabledSourcesAreNoSources() async throws {
        let library = try Library()
        let source = try library.addFolder()
        try library.sources.setEnabled(false, for: source.id)

        let response = await library.request()

        #expect(response.headers[EmptyReason.headerField] == EmptyReason.noSources.rawValue)
    }

    // MARK: - No photos

    /// **Not known yet.** A source that is there and has not finished a scan
    /// may be about to produce photographs.
    @Test("A source not yet scanned is a bare empty answer")
    func unscannedIsNotKnown() async throws {
        let library = try Library()
        _ = try library.addFolder()

        let response = await library.request()

        #expect(response.status == 204)
        #expect(response.headers[EmptyReason.headerField] == nil)
    }

    @Test("A scanned source with nothing in it is no photos")
    func scannedAndEmptyIsNoPhotos() async throws {
        let library = try Library()
        let source = try library.addFolder()
        await library.sources.refresh(source)

        let response = await library.request()

        #expect(response.status == 204)
        #expect(response.headers[EmptyReason.headerField] == EmptyReason.noPhotos.rawValue)
    }

    /// Syd, 2026-09-26: "if everything is offline, and there is nothing in the
    /// cache, then display *No Photos Available*." The photograph is in the
    /// pool; nothing of it is held, and its source is not there to fetch it.
    @Test("Everything offline with nothing cached is no photos")
    func offlineAndUncachedIsNoPhotos() async throws {
        let library = try Library()
        try library.addPhotoFile()
        let source = try library.addFolder()
        await library.sources.refresh(source)
        #expect(try PhotoPool(database: library.database).size(forSource: source.id) == 1)
        try library.sources.markUnavailable(sourceID: source.id, reason: "unplugged")

        let response = await library.request()

        #expect(response.status == 204)
        #expect(response.headers[EmptyReason.headerField] == EmptyReason.noPhotos.rawValue)
    }

    // MARK: - The rule itself

    /// Syd, 2026-09-26: "If there is an offline source, but there are photos
    /// in the cache from it, we use the cache." Those photographs are in the
    /// deck's pool, so a pool of any size is not *no photos*.
    @Test("An offline source with anything cached is not no photos")
    func offlineWithACacheIsNotNoPhotos() async throws {
        let library = try Library()
        let source = try library.addFolder()
        try library.sources.markUnavailable(sourceID: source.id, reason: "unplugged")

        let reason = PictureEndpoint.emptyReason(
            enabled: try library.sources.enabled(), poolSize: { 1 })

        #expect(reason == nil)
    }

    /// Photographs dealt and still being fetched are a cold start, not an
    /// empty library.
    @Test("A scanned source with photographs still coming is not no photos")
    func photographsStillComingIsNotNoPhotos() async throws {
        let library = try Library()
        let source = try library.addFolder()
        await library.sources.refresh(source)

        let reason = PictureEndpoint.emptyReason(
            enabled: try library.sources.enabled(), poolSize: { 3 })

        #expect(reason == nil)
    }

    /// The count is the expensive half, and it is not needed while a source is
    /// still being scanned.
    @Test("The pool is not counted while a source is unscanned")
    func noCountWhileUnscanned() throws {
        let library = try Library()
        _ = try library.addFolder()
        var counted = false

        let reason = PictureEndpoint.emptyReason(
            enabled: try library.sources.enabled(), poolSize: { counted = true; return 0 })

        #expect(reason == nil)
        #expect(!counted)
    }
}
