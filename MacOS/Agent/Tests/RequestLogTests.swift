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
@Suite("Request logging", .timeLimit(.minutes(2)))
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
            preferences: Preferences(defaults: scratchSuite("log")),
            store: PhotoStore(root: cacheRoot),
            queueRanShort: {}
        ).awaitingResizes()
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

    /// Consumers are keyed on `(kind, display)`, so two displays of one surface
    /// are two consumers — and the line has to say which, or they read as one.
    @Test("A record carries the display it was asked for, and none when it names none")
    func recordCarriesTheDisplay() async throws {
        let collector = Collector()
        let (endpoint, cleanup) = try endpoint(collector)
        defer { cleanup() }

        _ = await endpoint.route(
            try request(
                "GET /v1/next?consumer=wallpaper&display=37D8832A-2D66-02CA-B9F7-8F30A301B230&w=3600&h=2338 HTTP/1.1"))
        _ = await endpoint.route(try request("GET /v1/next?consumer=app&w=1&h=1 HTTP/1.1"))

        #expect(collector.all.map(\.display) == ["37D8832A-2D66-02CA-B9F7-8F30A301B230", nil])
    }

    @Test("A client that does not name itself is recorded as anonymous")
    func unnamedConsumer() async throws {
        let collector = Collector()
        let (endpoint, cleanup) = try endpoint(collector)
        defer { cleanup() }

        _ = await endpoint.route(try request("GET /v1/next HTTP/1.1"))
        #expect(collector.all.first?.consumer == "anonymous")
    }

    /// An empty library still opens, registers, and looks at the queue, and a
    /// slow empty answer needs placing as much as a slow picture does.
    @Test("An empty answer is timed too")
    func emptyAnswerIsTimed() async throws {
        let collector = Collector()
        let (endpoint, cleanup) = try endpoint(collector)
        defer { cleanup() }

        _ = await endpoint.route(try request("GET /v1/next?consumer=app&w=1&h=1 HTTP/1.1"))

        let stages = try #require(collector.all.first?.stages)
        #expect(stages.stages.map(\.name) == ["waited", "open", "register", "queue"])
    }

    /// A request refused before any step ran has nothing to time, and says
    /// nothing rather than a line of zeros.
    @Test("A refused request has no timing line")
    func refusedRequestIsNotTimed() async throws {
        let collector = Collector()
        let (endpoint, cleanup) = try endpoint(collector)
        defer { cleanup() }

        _ = await endpoint.route(try request("POST /v1/next HTTP/1.1"))

        #expect(collector.all.first?.timing == nil)
    }

    // MARK: - What the line says

    @Test("The RESIZE line says how long it waited, which photograph, and that the original went")
    func resizeGaveUpLine() {
        #expect(
            PictureEndpoint.resizeGaveUp(
                name: "IMG_0327.HEIC (B5E295AD-B306-4E08-9876-135BBF49E2AA/L0/001)", card: 6921,
                deal: 84642, after: .seconds(1))
                == "RESIZE: gave up after 1000ms on IMG_0327.HEIC (B5E295AD-B306-4E08-9876-135BBF49E2AA/L0/001) · card 6921 · deal #84642; serving the original")
    }

    /// **The man page names the number, so the number has to be checked.**
    /// `Documentation/photogoroundd.md` tells a client that a resize over 1.5
    /// seconds returns the original and that the console says `RESIZE: gave up
    /// after 1500ms on …`. Nothing above ties that to `ServiceTiming`, because
    /// the test beside this one passes its own duration to check the shape of
    /// the sentence. So this one checks the shipped budget, and fails when it
    /// moves — which is the moment the man page needs editing.
    ///
    /// The budget itself is the p95 of 3,573 measured renders, 2026-09-19;
    /// `Plans/Agent Performance Overhaul.md`, *The budget was measuring its own
    /// wall*.
    @Test("The budget the man page documents is the budget that ships")
    func theDocumentedBudget() {
        #expect(ServiceTiming.resizeBudget == .milliseconds(1500))
        #expect(
            PictureEndpoint.resizeGaveUp(
                name: "IMG_0327.HEIC", card: 1, deal: nil,
                after: ServiceTiming.resizeBudget)
                == "RESIZE: gave up after 1500ms on IMG_0327.HEIC · card 1; serving the original")
    }

    @Test("The timing line names the consumer, the status, the deal, each step, and the total")
    func timingLine() {
        let start = ContinuousClock.now
        var stages = StageTimes(from: start)
        stages.lap("waited", now: start + .milliseconds(3))
        stages.lap("check", now: start + .milliseconds(1003))
        stages.lap("shown", now: start + .milliseconds(29_003))

        let entry = PictureEndpoint.Served(
            status: 200, detail: "IMG_2481.HEIC", consumer: "app",
            width: "1280", height: "673", card: 4821, deal: 83911,
            bytes: 164_000, milliseconds: 29_012.4, stages: stages)

        #expect(
            entry.timing
                == "TIMING: app · 200 · deal #83911 · waited 3ms · check 1000ms · shown 28000ms · total 29012ms")
    }

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

    @Test("The display follows the consumer on the line")
    func summaryNamesTheDisplay() {
        let entry = PictureEndpoint.Served(
            status: 204, detail: "no photos available", consumer: "wallpaper",
            display: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
            width: "3600", height: "2338", card: nil, deal: nil,
            bytes: 0, milliseconds: 0.4)

        #expect(entry.summary
            == "wallpaper · display 37D8832A-2D66-02CA-B9F7-8F30A301B230 · 3600x2338 · 0.4ms")
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

extension RequestLogTests {

    /// **`miss of 5.17 GB` read as though 5.17 GB had been missed.** They are
    /// two unrelated facts — how these pixels were produced, and how much the
    /// cache holds altogether — and joining them with "of" invented a
    /// relationship between them.
    ///
    /// The logs are the first place a problem shows itself, so a line that has
    /// to be decoded before it can be read is a real cost.
    @Test("What the cache holds reads as a size, not as an amount missed")
    func cacheSizeReadsAsASize() {
        let entry = PictureEndpoint.Served(
            status: 200,
            detail: "2018 Rice Homecoming.jpeg",
            consumer: "app",
            width: "1570",
            height: "1066",
            card: 41,
            deal: 3205,
            sourceID: 12,
            bytes: 87_000,
            milliseconds: 56,
            cacheBytes: 5_170_000_000,
            queued: 19
        )

        // The wording this guards against is `miss of 5.17 GB`, which read as
        // though 5.17 GB had been missed. The `hit`/`miss` half went with the
        // resize cache on 2026-09-06; what is left has to keep saying what it
        // is on its own.
        #expect(!entry.summary.contains("of 5.17 GB"))
        #expect(entry.summary.contains("· cache 5.17 GB ·"))
        #expect(!entry.summary.contains("miss"))
    }

    /// The row id is what `pgr_ctl` answers to; the name is what somebody
    /// reading an installed agent's log recognises.
    @Test("A served picture names its source beside the row id")
    func summaryNamesTheSource() {
        let entry = PictureEndpoint.Served(
            status: 200, detail: "IMG_0042.HEIC (C3D4/L0/001)", consumer: "app",
            sourceID: 6, sourceName: "Photos › Trips › Holiday",
            bytes: 0, milliseconds: 1)

        #expect(entry.summary == "app · source 6 (Photos › Trips › Holiday) · 1.0ms")
    }

    @Test("A request that asked for no size reports no cache size")
    func noSizeMeansNoCacheField() {
        // The original went out as it is, so nothing consulted the cache's
        // totals and there is no number to print.
        let entry = PictureEndpoint.Served(
            status: 200, detail: "a.jpg", consumer: "cli",
            bytes: 100, milliseconds: 1
        )

        #expect(!entry.summary.contains("cache "))
    }
}
