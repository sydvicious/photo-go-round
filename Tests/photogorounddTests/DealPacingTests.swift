import CoreGraphics
import Foundation
import Synchronization
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
/// A counter two things share.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@Suite("When a deal is asked for")
struct DealPacingTests {

    private final class Library {
        let directory: URL
        let endpoint: PictureEndpoint
        let cache: PhotoCache
        let sources: SourceStore
        /// How many times the endpoint asked for another deal.
        ///
        /// A class rather than a `Mutex`, because a `Mutex` is non-copyable and
        /// this has to be captured by the endpoint's closure as well as read by
        /// the test.
        let asked = Tally()

        /// `renderable` photographs are real PNGs; the rest are files with a
        /// `.png` extension and nothing decodable inside, which is exactly what
        /// the serve walk skips past.
        /// `onEmpty` is rung when a request finds nothing to show, which is a
        /// different event from a picture being served and wants a different
        /// answer.
        let emptied = Tally()

        init(
            renderable: Int, broken: Int,
            onEmpty: (@Sendable () -> Void)? = nil,
            onServed: (@Sendable () -> Void)? = nil
        ) throws {
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
            endpoint = PictureEndpoint(
                databasePath: path, cacheRoot: cacheRoot,
                preferences: Preferences(defaults: scratchSuite("deal")),
                store: store,
                queueRanShort: { counter.bump(); onServed?() },
                deckCameUpEmpty: { [emptied] in emptied.bump(); onEmpty?() },
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
        #expect(library.asked.value == 1)
    }

    @Test("Photographs skipped on the way do not each buy a fresh card")
    func skipsDoNotDeal() async throws {
        // Every photograph here is unrenderable, so serving skips all three
        // and answers 204. The point is that the three skips ring nothing: a
        // deal follows a picture that reached somebody, and none did.
        //
        // The 204 used to ring a second hook of its own, because a deck full of
        // cards whose bytes were elsewhere needed a different answer from a
        // deck that was merely short. There is no such deck now — the deck
        // deals nothing it cannot show — so an empty answer means an empty
        // pool, and the thing that fixes an empty pool is the cache, which is
        // already refreshing itself.
        let library = try Library(renderable: 0, broken: 3)
        try await library.fill()

        let response = await library.request()

        #expect(response.status == 204)
        #expect(
            library.asked.value == 0,
            "three skipped photographs bought deals they should not have")
    }
}

/// An empty answer has to be able to restart dealing.
///
/// **Observed on the real library, 2026-08-26.** A local source of 8,287
/// photographs was removed, taking the deck with it by cascade. 592 remote
/// photographs were cached and perfectly servable, but nothing dealt them for
/// thirty seconds: no picture was served, so nothing rang the filler, and the
/// heartbeat that would have was stuck behind a network source's 30.9-second
/// walk. Ten consecutive `204`s with a full cache behind them.
///
/// This is a *different* event from the deck running short, and it is answered
/// by its own hook: a served picture is what paces the deck, and an empty
/// answer must refill it without counting as one.
extension DealPacingTests {

    @Test("Answering no photos asks for the deck to be filled")
    func anEmptyAnswerRingsTheFiller() async throws {
        let library = try Library(renderable: 0, broken: 0)
        try await library.fill()

        let response = await library.request()

        #expect(response.status == 204)
        #expect(library.emptied.value == 1, "an empty deck asked nobody to refill it")
        #expect(library.asked.value == 0, "an empty answer must not count as a picture served")
    }
}
