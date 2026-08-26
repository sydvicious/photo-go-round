import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit
@testable import photogoroundd

/// When the filler is asked for another card.
///
/// **A deal should follow a picture that reached somebody, not a request that
/// arrived.** `markDelivered`'s own comment names the difference: it "fires when
/// the endpoint has a 200 in its hand", and the gap between that and selection
/// is "every photograph the deck believes it showed and nobody saw" — a file
/// that would not decode, a rendering that failed, a source that went away
/// between selection and read.
///
/// Ringing the filler on the wrong side of that gap makes a request that walks
/// past broken photographs deal one fresh card for each of them.
@Suite("When a deal is asked for")
struct DealPacingTests {

    private final class Library {
        let directory: URL
        let endpoint: PictureEndpoint
        let cache: PhotoCache
        let sources: SourceStore
        let asked = Mutex(0)
        /// A walk that went through every card and found none it could serve.
        /// A different event from the queue running short, and it wants a
        /// different answer, so it is counted separately.
        let empties = Mutex(0)

        /// `renderable` photographs are real PNGs; the rest are files with a
        /// `.png` extension and nothing decodable inside, which is exactly what
        /// the serve walk skips past.
        init(renderable: Int, broken: Int) throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-deal-\(UUID().uuidString)")
            let photos = directory.appending(path: "photos")
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            for index in 0..<renderable {
                try Self.png(to: photos.appending(path: "good-\(index).png"))
            }
            for index in 0..<broken {
                try Data("not a picture".utf8)
                    .write(to: photos.appending(path: "broken-\(index).png"))
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
            let counter = asked
            let emptyCounter = empties
            endpoint = PictureEndpoint(
                databasePath: path, cacheRoot: cacheRoot,
                preferences: Preferences(defaults: UserDefaults(suiteName: "pgr.deal.\(UUID())")!),
                store: store,
                queueRanShort: { counter.withLock { $0 += 1 } },
                queueCameUpEmpty: { emptyCounter.withLock { $0 += 1 } },
                log: { _ in })
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func fill() async throws {
            try cache.prepare()
            let folder = directory.appending(path: "photos").path(percentEncoded: false)
            let source = try await sources.add(kind: .folder, locator: folder)
            _ = await sources.refresh(source)
            _ = try await cache.fillCompletely()
        }

        func request() async -> HTTPListener.Response {
            let head = HTTPListener.parse("GET /v1/next?consumer=app&w=200&h=200 HTTP/1.1")!
            return await endpoint.route(head)
        }

        private static func png(to url: URL) throws {
            let width = 64, height = 64
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = context.makeImage()!
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    @Test("A picture that reaches somebody asks for exactly one deal")
    func oneDeliveryOneDeal() async throws {
        let library = try Library(renderable: 1, broken: 0)
        try await library.fill()

        let response = await library.request()

        #expect(response.status == 200)
        #expect(library.asked.withLock { $0 } == 1)
    }

    @Test("Photographs skipped on the way do not each buy a fresh card")
    func skipsDoNotDeal() async throws {
        // Every photograph here is unrenderable, so the walk goes through all
        // three and answers 204. The 204 rings the filler once, deliberately —
        // an empty answer has to be able to restart dealing. What must not
        // happen is the three skips ringing it as well.
        let library = try Library(renderable: 0, broken: 3)
        try await library.fill()

        let response = await library.request()

        #expect(response.status == 204)
        #expect(
            library.asked.withLock { $0 } == 0,
            "three skipped photographs bought deals they should not have")
        #expect(library.empties.withLock { $0 } == 1, "the empty answer rang nothing")
    }
}
