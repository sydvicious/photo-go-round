import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotoGoRoundKit
@testable import photogoroundd

/// The endpoint's own cache behaviour, driven through `route` rather than
/// through the store beneath it.
///
/// This suite exists because the store's tests passed while the endpoint missed
/// every single time: it was building a fresh `PhotoCache` per request, each
/// with its own empty index, writing renderings and never seeing them again.
/// Nothing below the endpoint could catch that, because everything below it was
/// correct.
///
/// **The library holds one photograph on purpose.** Serving pops the queue, so
/// consecutive requests normally hand out different pictures; with one
/// photograph every request is the same card, which is what makes a hit
/// observable.
@Suite("Endpoint cache")
struct EndpointCacheTests {

    /// Collects what the endpoint said it did, so the records can be read
    /// rather than watched.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [PictureEndpoint.Served] = []

        func record(_ entry: PictureEndpoint.Served) {
            lock.lock()
            entries.append(entry)
            lock.unlock()
        }

        var all: [PictureEndpoint.Served] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private final class Library {
        let directory: URL
        let endpoint: PictureEndpoint
        let cache: PhotoCache
        let sources: SourceStore
        let log = Collector()
        private(set) var sourceIdentifier: Int64 = 0

        init(photographs: Int = 1, size: (width: Int, height: Int) = (1200, 900)) throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-ep-\(UUID().uuidString)")
            let photos = directory.appending(path: "photos")
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            for index in 0..<photographs {
                try Self.write(
                    width: size.width, height: size.height,
                    to: photos.appending(path: "photo-\(index).png"))
            }

            let path = directory.appending(path: "photogoround.sqlite")
                .path(percentEncoded: false)
            let database = try Database(path: path)
            try Migrator.migrate(database)
            sources = SourceStore(database: database)

            let cacheRoot = directory.appending(path: "cache")
            let store = PhotoStore(root: cacheRoot)
            cache = PhotoCache(
                database: database, root: cacheRoot,
                sources: sources, queueSize: 100, store: store)
            let collector = log
            endpoint = PictureEndpoint(
                databasePath: path, cacheRoot: cacheRoot,
                preferences: Preferences(defaults: UserDefaults(suiteName: "pgr.ep.\(UUID())")!),
                store: store, queueRanShort: {}, log: { collector.record($0) })
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func fill() async throws {
            try cache.prepare()
            let folder = directory.appending(path: "photos").path(percentEncoded: false)
            let source = try sources.add(kind: .folder, locator: folder)
            sourceIdentifier = source.id
            _ = await sources.refresh(source)
            while try await cache.produce(forSource: source.id) {}
        }

        /// One request, with the queue topped up first.
        ///
        /// Serving pops the queue, and the agent refills it because serving is
        /// what notices it has run short; here that is explicit, so a test
        /// asking twice is asking twice rather than asking once and then being
        /// told there is nothing left.
        func get(_ query: String, accept: String? = nil) async throws -> HTTPListener.Response {
            while try await cache.produce(forSource: sourceIdentifier) {}
            var request = try #require(HTTPListener.parse("GET /v1/next?\(query) HTTP/1.1"))
            if let accept {
                request = HTTPListener.Request(
                    method: request.method, path: request.path, query: request.query,
                    headers: ["accept": accept], receivedAt: request.receivedAt)
            }
            return await endpoint.route(request)
        }

        func getOriginal() async throws -> HTTPListener.Response {
            while try await cache.produce(forSource: sourceIdentifier) {}
            return await endpoint.route(
                try #require(HTTPListener.parse("GET /v1/next HTTP/1.1")))
        }

        func request(_ target: String) throws -> HTTPListener.Request {
            try #require(HTTPListener.parse("GET \(target) HTTP/1.1"))
        }

        static func write(width: Int, height: Int, to url: URL) throws {
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
    }

    private func headers(_ response: HTTPListener.Response) -> [String: String] {
        response.headers
    }

    // MARK: - Hit and miss

    @Test("The first request for a size renders; the second is served from cache")
    func secondRequestIsAHit() async throws {
        let library = try Library()
        try await library.fill()

        let first = try await library.get("w=100&h=100")
        #expect(first.status == 200)
        #expect(headers(first)["X-PGR-Cache"] == "miss")

        let second = try await library.get("w=100&h=100")
        #expect(second.status == 200)
        #expect(
            headers(second)["X-PGR-Cache"] == "hit",
            "the endpoint rendered again instead of reading what it had just written")
    }

    @Test("Two sizes are held at once, and alternating between them hits both")
    func twoSizesAlternate() async throws {
        let library = try Library()
        try await library.fill()

        // Each size misses once.
        for box in ["w=100&h=100", "w=1000&h=1000"] {
            let response = try await library.get(box)
            #expect(headers(response)["X-PGR-Cache"] == "miss")
        }

        // Then every request hits, whichever order they come in, and each keeps
        // its own pixels — one did not overwrite the other.
        for box in ["w=100&h=100", "w=1000&h=1000", "w=1000&h=1000", "w=100&h=100"] {
            let response = try await library.get(box)
            #expect(headers(response)["X-PGR-Cache"] == "hit", "\(box)")
        }

        let small = try await library.get("w=100&h=100")
        let large = try await library.get("w=1000&h=1000")
        // 1200×900 fitted into each box.
        #expect(headers(small)["X-PGR-Pixels"] == "100x75")
        #expect(headers(large)["X-PGR-Pixels"] == "1000x750")
    }

    @Test("A different size is a different entry, not a hit on the wrong pixels")
    func sizesDoNotCollide() async throws {
        let library = try Library()
        try await library.fill()

        _ = try await library.get("w=100&h=100")
        let other = try await library.get("w=101&h=101")
        #expect(headers(other)["X-PGR-Cache"] == "miss")
        // The decoder truncates the short edge where `fit` rounds it, so this is
        // 75 rather than 76 — see `PhotoRenderer.fit`.
        #expect(headers(other)["X-PGR-Pixels"] == "101x75")
    }

    @Test("The index survives a new process, so nothing is rendered twice")
    func cacheSurvivesARestart() async throws {
        let library = try Library()
        try await library.fill()
        _ = try await library.get("w=100&h=100")

        // A second endpoint over the same directories, with nothing in memory —
        // which is what a restart is.
        let store = PhotoStore(root: library.cache.root)
        let restarted = PictureEndpoint(
            databasePath: library.directory.appending(path: "photogoround.sqlite")
                .path(percentEncoded: false),
            cacheRoot: library.cache.root,
            preferences: Preferences(defaults: UserDefaults(suiteName: "pgr.ep.\(UUID())")!),
            store: store, queueRanShort: {}, log: { _ in })
        try PhotoCache(
            database: try Database(
                path: library.directory.appending(path: "photogoround.sqlite")
                    .path(percentEncoded: false)),
            root: library.cache.root, sources: library.sources, store: store
        ).indexCache()

        // Top the queue up first: serving popped it, and this endpoint has no
        // agent behind it to notice.
        while try await library.cache.produce(forSource: library.sourceIdentifier) {}
        let response = await restarted.route(
            try #require(HTTPListener.parse("GET /v1/next?w=100&h=100 HTTP/1.1")))
        #expect(headers(response)["X-PGR-Cache"] == "hit")
    }

    // MARK: - What comes back

    @Test("Asking for no size returns the original, uncached and unmodified")
    func noSizeReturnsTheOriginal() async throws {
        let library = try Library()
        try await library.fill()

        let response = try await library.getOriginal()
        #expect(response.status == 200)
        #expect(headers(response)["X-PGR-Pixels"] == nil)
        #expect(headers(response)["X-PGR-Cache"] == nil)
        #expect(headers(response)["Content-Type"] == "image/png")
    }

    // MARK: - What it says it did

    @Test("A served picture is logged with its card, its deal, and its bytes")
    func servedPictureIsLogged() async throws {
        let library = try Library()
        try await library.fill()

        let response = try await library.get("w=200&h=200")
        let entry = try #require(library.log.all.last)

        #expect(entry.status == 200)
        #expect(entry.width == "200")
        #expect(entry.height == "200")
        #expect(entry.card != nil)
        // The deal ordinal is assigned when the picture is handed over, so a
        // logged record of a served picture always has one.
        #expect(entry.deal != nil)
        #expect(entry.bytes > 0)
        #expect(entry.detail.hasSuffix(".png"))
        #expect(entry.milliseconds >= 0)

        // The record describes the same picture the client was handed.
        #expect(String(entry.card ?? 0) == headers(response)["X-PGR-Card"])
        #expect(String(entry.deal ?? 0) == headers(response)["X-PGR-Deal"])
    }

    @Test("A hit is logged as well as a miss, and reports the bytes it sent")
    func cacheHitsAreLogged() async throws {
        let library = try Library()
        try await library.fill()

        _ = try await library.get("w=200&h=200")
        _ = try await library.get("w=200&h=200")

        let records = library.log.all.suffix(2)
        #expect(records.count == 2)
        // Both are ordinary served pictures as far as the record is concerned —
        // a client cannot tell, and neither should the log's shape.
        #expect(records.allSatisfy { $0.status == 200 })
        #expect(records.allSatisfy { $0.bytes > 0 })
        #expect(records.allSatisfy { $0.card == records.first?.card })
    }

    @Test("One record per request, and no record for work that was skipped")
    func oneRecordPerRequest() async throws {
        let library = try Library()
        try await library.fill()

        for _ in 0..<4 { _ = try await library.get("w=100&h=100") }
        #expect(library.log.all.count == 4)
    }

    @Test("`Accept` decides the format, and the cache keeps them apart")
    func acceptChoosesTheFormat() async throws {
        let library = try Library()
        try await library.fill()

        var jpeg = try library.request("/v1/next?w=200&h=200")
        jpeg = HTTPListener.Request(
            method: jpeg.method, path: jpeg.path, query: jpeg.query,
            headers: ["accept": "image/jpeg"], receivedAt: jpeg.receivedAt)

        let response = await library.endpoint.route(jpeg)
        #expect(headers(response)["Content-Type"] == "image/jpeg")
    }
}
