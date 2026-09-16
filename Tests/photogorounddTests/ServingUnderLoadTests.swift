import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit
@testable import photogoroundd

/// The agent while resizes hang.
///
/// **Measured 2026-09-16.** The running agent's `TIMING:` lines had single
/// resizes taking up to 741 seconds, and in those minutes requests could not
/// even start for up to 109 seconds, and a one-second check took 224. A thread
/// sample at 13:31:39 caught a resize waiting on a synchronous call to the
/// system's video decoder, and every other thread in the shared pool stuck
/// behind it. `Agent Performance Overhaul.md`, *What happened on 2026-09-16*.
///
/// **A resize that finishes cannot reproduce that.** A first version of this
/// suite sent waves of real 12-megapixel HEIC resizes through the endpoint while
/// a 30,000-photograph album was re-read and downloads landed; twelve at once
/// took 0.67 s at the median and forty took 1.2 s, because on a quiet machine
/// the system decoder answers. So the resize here blocks on purpose, through
/// `PictureEndpoint.resize`, standing in for the decoder that did not.
///
/// **What must hold is that nothing else waits for it.** A request that asks
/// for no size, and the source list, have nothing to do with a resize; they
/// must answer inside the client's bound while resizes hang.
@Suite("Serving while resizes hang")
struct ServingUnderLoadTests {

    /// Photographs in the folder, and so cards in the queue.
    static let photographs = 60
    /// How long to watch the unrelated requests before letting the resizes go.
    /// Past the client's bound, so a request that is never started fails.
    static let watch = ServiceTiming.pictureReadLimit + .seconds(1)

    /// A resize that does not come back until the test lets it.
    ///
    /// A semaphore rather than anything asynchronous, because the point is to
    /// hold a thread the way a synchronous XPC call to the decoder did.
    final class Hang: Sendable {
        private let entered = Mutex(0)
        private let gate = DispatchSemaphore(value: 0)

        var count: Int { entered.withLock { $0 } }

        func block() {
            entered.withLock { $0 += 1 }
            // Bounded, so a test that fails before releasing cannot hold these
            // threads for the rest of the run.
            _ = gate.wait(timeout: .now() + 60)
        }

        func release(_ waiting: Int) {
            for _ in 0..<waiting { gate.signal() }
        }
    }

    /// When each unrelated request finished, measured from the moment every
    /// resize that could start had started.
    final class Finished: Sendable {
        private let times = Mutex<[String: (took: Duration, status: Int)]>([:])
        func record(_ name: String, _ took: Duration, status: Int) {
            times.withLock { $0[name] = (took, status) }
        }
        var all: [String: (took: Duration, status: Int)] { times.withLock { $0 } }
    }

    /// A folder of small PNGs, dealt and ready, and an endpoint whose resizes
    /// hang on `hang` — on a resizer of its own, so a hang here cannot stall
    /// another suite's resizes on `Resizer.shared`.
    private final class Library {
        let directory: URL
        let path: String
        let bytes: PhotoStore
        let database: Database
        let queued: Int
        let hang = Hang()
        let pictures: PictureEndpoint

        init() async throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-hang-\(UUID().uuidString)")
            let photos = directory.appending(path: "photos")
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            for index in 0..<ServingUnderLoadTests.photographs {
                try ServingUnderLoadTests.writePNG(to: photos.appending(path: "photo-\(index).png"))
            }

            path = directory.appending(path: "photogoround.sqlite").path(percentEncoded: false)
            let root = directory.appending(path: "cache")
            bytes = PhotoStore(root: root)
            database = try Database(path: path)
            try Migrator.migrate(database)
            let sources = SourceStore(database: database, bytes: bytes)
            var cache = PhotoCache(
                database: database, root: root, sources: sources,
                queueSize: ServingUnderLoadTests.photographs, store: bytes)
            cache.log = { _ in }
            try cache.prepare()
            let source = try sources.add(
                kind: .folder, locator: photos.path(percentEncoded: false))
            _ = await sources.refresh(source)
            queued = try await cache.fillCompletely(limit: ServingUnderLoadTests.photographs)

            let hang = hang
            var pictures = PictureEndpoint(
                databasePath: path, cacheRoot: root,
                preferences: Preferences(defaults: scratchSuite("hang")),
                store: bytes, queueRanShort: {}, log: { _ in })
            pictures.resize = { _, _, _, format in
                hang.block()
                return PhotoRenderer.Rendered(bytes: Data([0]), format: format, width: 1, height: 1)
            }
            pictures.resizer = Resizer()
            self.pictures = pictures
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    @Test("A request with no size and the source list answer while resizes hang")
    func unrelatedRequestsAnswerWhileResizesHang() async throws {
        let library = try await Library()
        let hang = library.hang
        let pictures = library.pictures
        let queued = library.queued
        let listing = SourceEndpoint(
            databasePath: library.path, preferences: Preferences(defaults: scratchSuite("hang")),
            bytes: library.bytes, log: { _ in })

        // More hanging resizes than the machine has cores, so every thread the
        // shared pool has is offered one.
        let hanging = ProcessInfo.processInfo.activeProcessorCount + 4
        #expect(queued > hanging + 2, "the queue must outlast the hanging requests")
        let endpoint = pictures
        let stuck = (0..<hanging).map { index in
            Task {
                await endpoint.route(
                    HTTPListener.parse("GET /v1/next?consumer=hang-\(index)&w=2560&h=1440 HTTP/1.1")!)
                    .status
            }
        }

        // Watched from a thread of its own, since the pool this test runs on is
        // the thing being filled.
        let finished = Finished()
        let entered: Int = await withCheckedContinuation { continuation in
            Thread {
                // Until no more resizes start: every thread that will pick one
                // up has.
                var seen = -1
                var looked = 0
                while (hang.count != seen || hang.count == 0) && looked < 30 {
                    seen = hang.count
                    looked += 1
                    Thread.sleep(forTimeInterval: 1)
                }
                let clock = ContinuousClock()
                let started = clock.now
                Task {
                    let response = await endpoint.route(
                        HTTPListener.parse("GET /v1/next?consumer=unsized HTTP/1.1")!)
                    finished.record(
                        "GET /v1/next with no size", clock.now - started, status: response.status)
                }
                Task {
                    let response = await listing.route(
                        HTTPListener.parse("GET \(SourceEndpoint.path) HTTP/1.1")!)
                    finished.record(
                        "GET \(SourceEndpoint.path)", clock.now - started, status: response.status)
                }
                while finished.all.count < 2, clock.now - started < Self.watch {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                hang.release(hanging)
                continuation.resume(returning: seen)
            }.start()
        }
        for task in stuck { _ = await task.value }
        // The unrelated requests are recorded when they finish, which after the
        // release they do; wait for both so the assertion reads their times.
        while finished.all.count < 2 { try await Task.sleep(for: .milliseconds(10)) }

        let times = finished.all
        print("\(entered) of \(hanging) resizes hanging; \(times)")
        #expect(entered > 0, "no resize ever started, so nothing was hanging")
        for (request, result) in times.sorted(by: { $0.key < $1.key }) {
            let took = result.took
            #expect(result.status == 200, "\(request) answered \(result.status)")
            #expect(
                took < ServiceTiming.pictureReadLimit,
                "\(request) took \(took) while \(entered) resizes hung, against a client that gives up at \(ServiceTiming.pictureReadLimit)")
        }
    }

    /// **A resize that stalls is given up on, and the original goes instead.**
    /// Syd, 2026-09-16: "just serve the original image if the resizer stalls."
    /// The resizer had taken 89 s over one HEIC decode at 17:02, and the
    /// wallpaper and the app waited 92 s and 93 s behind it.
    ///
    /// Two requests: one whose resize hangs, and one queued behind it. Both get
    /// the original inside the budget; the queued resize never runs, because
    /// nobody is waiting for it; and neither photograph is charged a render
    /// failure, since a stalled decoder says nothing about the file.
    @Test("A request whose resize stalls gets the original, and the resize queued behind it is skipped")
    func stalledResizeServesTheOriginal() async throws {
        let library = try await Library()
        let pictures = library.pictures
        let clock = ContinuousClock()

        func sized(_ consumer: String) async -> (HTTPListener.Response, Duration) {
            let started = clock.now
            let response = await pictures.route(
                HTTPListener.parse("GET /v1/next?consumer=\(consumer)&w=2560&h=1440 HTTP/1.1")!)
            return (response, clock.now - started)
        }
        async let first = sized("first")
        // The second asks once the first is inside its resize, so it is
        // queued behind a resize that is already hanging.
        while library.hang.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        async let second = sized("second")
        let answers = await [first, second]

        for (response, took) in answers {
            #expect(response.status == 200)
            #expect(response.headers["Content-Type"] == "image/png", "the original's own type")
            #expect(response.headers["X-PGR-Pixels"] == nil, "nothing was resized to measure")
            #expect(took >= ServiceTiming.resizeBudget)
            #expect(
                took < ServiceTiming.pictureReadLimit,
                "took \(took) against a client that gives up at \(ServiceTiming.pictureReadLimit)")
        }

        // Let the hanging resize finish, then wait for the resizer to reach the
        // one queued behind it.
        library.hang.release(1)
        _ = try await pictures.resizer.run {}
        #expect(library.hang.count == 1, "the queued resize ran though nobody was waiting for it")
        #expect(
            try library.database.scalarInt("SELECT SUM(render_failures) FROM photo;") == 0,
            "a stalled decoder was charged to the photograph")
    }

    static func writePNG(to url: URL) throws {
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
