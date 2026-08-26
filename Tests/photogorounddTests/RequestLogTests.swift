import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd
@testable import PhotoGoRoundAgentAPI

/// What the service says it did.
///
/// The records go to `os_log`, which a test cannot query — they land in the
/// system's log store and are read back with `log show`, long after anything
/// could assert on them. So the endpoint writes through an injected sink, and
/// these tests collect the values instead of watching a terminal.
@Suite("Request logging")
struct RequestLogTests {

    private final class Collector: @unchecked Sendable {
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

    /// An endpoint over an empty but migrated library, which is enough to answer
    /// every request with something and therefore to log every request.
    private func endpoint(_ collector: Collector) throws -> (PictureEndpoint, () -> Void) {
        let directory = URL.temporaryDirectory.appending(path: "pgr-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "photogoround.sqlite").path(percentEncoded: false)
        try Migrator.migrate(Database(path: path))

        let cacheRoot = directory.appending(path: "cache")
        var endpoint = PictureEndpoint(
            databasePath: path,
            cacheRoot: cacheRoot,
            preferences: Preferences(defaults: UserDefaults(suiteName: "pgr.log.\(UUID())")!),
            store: PhotoStore(root: cacheRoot),
            queueRanShort: {}
        )
        endpoint.log = { collector.record($0) }
        return (endpoint, { try? FileManager.default.removeItem(at: directory) })
    }

    private func request(_ head: String) throws -> HTTPListener.Request {
        try #require(HTTPListener.parse(head))
    }

    // MARK: - Every request is accounted for

    @Test("Every request produces exactly one record, including the ones that fail")
    func oneRecordPerRequest() async throws {
        let collector = Collector()
        let (endpoint, cleanup) = try endpoint(collector)
        defer { cleanup() }

        _ = await endpoint.route(try request("GET /v1/next?consumer=a&w=1&h=1 HTTP/1.1"))
        _ = await endpoint.route(try request("GET /nope HTTP/1.1"))
        _ = await endpoint.route(try request("POST /v1/next HTTP/1.1"))

        #expect(collector.all.count == 3)
        #expect(collector.all.map(\.status) == [204, 404, 405])
    }

    @Test("A record carries who asked and what they asked for")
    func recordCarriesTheRequest() async throws {
        let collector = Collector()
        let (endpoint, cleanup) = try endpoint(collector)
        defer { cleanup() }

        _ = await endpoint.route(
            try request("GET /v1/next?consumer=screensaver&w=3840&h=2160 HTTP/1.1"))

        let entry = try #require(collector.all.first)
        #expect(entry.consumer == "screensaver")
        #expect(entry.width == "3840")
        #expect(entry.height == "2160")
        // Nothing was served, so there is no card, no deal, and no bytes.
        #expect(entry.card == nil)
        #expect(entry.deal == nil)
        #expect(entry.bytes == 0)
        #expect(entry.milliseconds >= 0)
    }

    @Test("A client that does not name itself is recorded as anonymous")
    func unnamedConsumer() async throws {
        let collector = Collector()
        let (endpoint, cleanup) = try endpoint(collector)
        defer { cleanup() }

        _ = await endpoint.route(try request("GET /v1/next HTTP/1.1"))
        #expect(collector.all.first?.consumer == "anonymous")
    }

    // MARK: - What the line says

    @Test("A served picture reports its deal, its size, and its latency")
    func servedSummary() {
        let entry = PictureEndpoint.Served(
            status: 200, detail: "IMG_2481.HEIC", consumer: "wallpaper",
            width: "3840", height: "2160", card: 4821, deal: 91043,
            bytes: 4_200_000, milliseconds: 12.3)

        // Byte formatting is the system's, so assert the parts rather than
        // pinning a locale's rendering of them.
        #expect(entry.summary.hasPrefix("wallpaper · 3840x2160 · deal #91043 · "))
        #expect(entry.summary.hasSuffix(" · 12.3ms"))
        #expect(entry.summary.contains("MB"))
    }

    @Test("An empty answer reports no deal and no bytes")
    func emptySummary() {
        let entry = PictureEndpoint.Served(
            status: 204, detail: "no photos available", consumer: "screensaver",
            width: "1920", height: "1080", card: nil, deal: nil,
            bytes: 0, milliseconds: 0.4)

        #expect(entry.summary == "screensaver · 1920x1080 · 0.4ms")
    }

    @Test("A request with no size asked for says so by omission")
    func summaryWithoutASize() {
        let entry = PictureEndpoint.Served(
            status: 404, detail: "no such endpoint", consumer: "anonymous",
            width: nil, height: nil, card: nil, deal: nil,
            bytes: 0, milliseconds: 0.1)

        #expect(entry.summary == "anonymous · 0.1ms")
    }
}
