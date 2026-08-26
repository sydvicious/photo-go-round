import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotoGoRoundKit
@testable import photogoroundd
@testable import PhotoGoRoundAgentAPI

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

        func fill(materialized: Bool = false) async throws {
            try cache.prepare()
            let folder = directory.appending(path: "photos").path(percentEncoded: false)
            let source = try await sources.add(kind: .folder, locator: folder)
            sourceIdentifier = source.id
            _ = await sources.refresh(source)
            // Materialized means the bytes are copied into the cache, which is
            // the only arrangement where the *original* can be evicted out from
            // under a rendering. A referenced photograph's original is the file
            // on the boot volume, and that is never ours to evict.
            if materialized {
                try sources.database.run("UPDATE photo SET storage = 'materialized';")
            }
            _ = try await cache.fillCompletely()
        }

        /// Deletes the cached original and re-indexes the byte store from the
        /// filesystem, leaving the rendering and the queue entry alone.
        ///
        /// `rebuild` rather than `PhotoCache.indexCache`, and the difference is
        /// the point: `indexCache` *also* drops any queued card whose original
        /// is missing, so calling it here would remove the very photograph this
        /// is arranging to ask for.
        func evictTheOriginal() throws {
            let uuid = try #require(
                try sources.database.scalarString("SELECT uuid FROM photo LIMIT 1;"))
            let original = try #require(cache.store.url(for: PhotoStore.Key(photoUUID: uuid)))
            try FileManager.default.removeItem(at: original)

            var owners: [String: String] = [:]
            try sources.database.query(
                "SELECT p.uuid AS photo_uuid, s.uuid AS source_uuid"
                    + " FROM photo p JOIN source s ON s.id = p.source_id;"
            ) { row in
                owners[try row.string("photo_uuid")] = try row.string("source_uuid")
            }
            _ = cache.store.rebuild(photos: owners)
        }

        /// One request, with the queue topped up first.
        ///
        /// Serving pops the queue, and the agent refills it because serving is
        /// what notices it has run short; here that is explicit, so a test
        /// asking twice is asking twice rather than asking once and then being
        /// told there is nothing left.
        func get(
            _ query: String, accept: String? = nil, toppingUp: Bool = true
        ) async throws -> HTTPListener.Response {
            // Off for the eviction tests, and that is the whole of why it is an
            // option: producing re-materializes the original, so a test that
            // topped up after evicting it would be asserting against a cache it
            // had just refilled.
            if toppingUp { _ = try await cache.fillCompletely() }
            var request = try #require(HTTPListener.parse("GET /v1/next?\(query) HTTP/1.1"))
            if let accept {
                request = HTTPListener.Request(
                    method: request.method, path: request.path, query: request.query,
                    headers: ["accept": accept], receivedAt: request.receivedAt)
            }
            return await endpoint.route(request)
        }

        /// Tops the queue up without serving anything, so a test can arrange a
        /// queued photograph and *then* change what the cache is holding.
        func topUp() async throws {
            _ = try await cache.fillCompletely()
        }

        func getOriginal(toppingUp: Bool = true) async throws -> HTTPListener.Response {
            if toppingUp { _ = try await cache.fillCompletely() }
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

    @Test("A delivered picture is counted, and counted once per request")
    func deliveryIsCounted() async throws {
        let library = try Library()
        try await library.fill()

        func delivered() throws -> Int {
            try library.sources.database.scalarInt(
                "SELECT IFNULL(SUM(times_delivered), 0) FROM photo;") ?? 0
        }
        #expect(try delivered() == 0)

        #expect(try await library.get("w=100&h=100").status == 200)
        #expect(try delivered() == 1)

        // A hit counts too — the question this column answers is how many
        // photographs reached a client, not how many were rendered for one.
        #expect(try await library.get("w=100&h=100").status == 200)
        #expect(try delivered() == 2)
    }

    @Test("Being chosen is counted separately from being delivered")
    func shownAndDeliveredAreDifferentNumbers() async throws {
        let library = try Library()
        try await library.fill()
        #expect(try await library.get("w=100&h=100").status == 200)

        // Equal here because nothing failed, and that is the point: the two
        // columns are only allowed to diverge when a photograph was chosen and
        // then could not be handed over. `times_shown` is incremented by the
        // deck when serving picks a card — before any rendering has been
        // attempted — so a file that will not decode raises it and delivers
        // nothing. Somewhere to look when a library shows fewer pictures than
        // the deck says it is showing.
        let shown =
            try library.sources.database.scalarInt("SELECT SUM(times_shown) FROM photo;") ?? 0
        let handed =
            try library.sources.database.scalarInt("SELECT SUM(times_delivered) FROM photo;") ?? 0
        #expect(shown == 1)
        #expect(handed == 1)
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
        _ = try await library.cache.fillCompletely()
        let response = await restarted.route(
            try #require(HTTPListener.parse("GET /v1/next?w=100&h=100 HTTP/1.1")))
        #expect(headers(response)["X-PGR-Cache"] == "hit")
    }

    // MARK: - When the original is gone and the rendering is not

    /// The case `PhotoStore.evictIfNeeded` documents as a feature — "a client
    /// asking again at a size already held never needs the original back" — and
    /// which did not work, because serving insisted on finding the original
    /// before it would part with anything.
    @Test("A rendering is served after its original has been evicted")
    func aRenderingOutlivesItsOriginal() async throws {
        let library = try Library()
        try await library.fill(materialized: true)

        let first = try await library.get("w=200&h=200")
        #expect(first.status == 200)
        #expect(headers(first)["X-PGR-Cache"] == "miss")

        // Queue it *before* evicting, and do not top up afterwards — producing
        // would copy the original back in and there would be nothing to prove.
        try await library.topUp()
        try library.evictTheOriginal()

        let second = try await library.get("w=200&h=200", toppingUp: false)
        #expect(
            second.status == 200,
            "the photograph was skipped, though we were holding exactly the pixels asked for")
        #expect(headers(second)["X-PGR-Cache"] == "hit")
        #expect(headers(second)["X-PGR-Pixels"] == "200x150")
    }

    @Test("A size nobody rendered is not invented from one that was")
    func anotherSizeIsNotServedFromTheWrongRendering() async throws {
        let library = try Library()
        try await library.fill(materialized: true)
        _ = try await library.get("w=200&h=200")
        try await library.topUp()
        try library.evictTheOriginal()

        // 300×300 was never rendered and the original is gone, so there is
        // nothing to make it from. Answering with the 200-wide file would be
        // handing over pixels the client did not ask for.
        let response = try await library.get("w=300&h=300", toppingUp: false)
        #expect(response.status == 204)
    }

    @Test("Asking for the original when only a rendering is held serves nothing")
    func theOriginalIsNotFakedFromARendering() async throws {
        let library = try Library()
        try await library.fill(materialized: true)
        _ = try await library.get("w=200&h=200")
        try await library.topUp()
        try library.evictTheOriginal()

        // No box at all means the original bytes, untouched. We do not have
        // them, and a rendering is not them.
        let response = try await library.getOriginal(toppingUp: false)
        #expect(response.status == 204)
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
        // Which source it came from, because a name alone does not say: two
        // folders can both hold `Image_001.jpg`. The row id, which is what
        // `pgr_ctl sources list` prints — a person reads this line.
        #expect(entry.sourceID != nil)
        #expect(entry.summary.contains("source \(entry.sourceID ?? 0)"))
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

    @Test("The console line says hit or miss, which is what a miss costs is read against")
    func theRecordSaysHitOrMiss() async throws {
        let library = try Library()
        try await library.fill()

        _ = try await library.get("w=200&h=200")
        _ = try await library.get("w=200&h=200")
        _ = try await library.getOriginal()

        let records = library.log.all.suffix(3)
        #expect(records.map(\.cache) == [.miss, .hit, nil])
        // The size of the cache beside the hit or miss: a miss is ordinary while
        // it is filling and worth looking at once it is not, and the two are
        // only readable together.
        // The cache size beside the hit or miss, and how deep the queue was —
        // a miss is ordinary while the cache fills, and the queue depth says
        // whether the walk is outrunning the deck.
        #expect(try #require(records.first).cacheBytes != nil)
        #expect(try #require(records.first).queued != nil)
        #expect(try #require(records.first).summary.contains("miss of "))
        #expect(try #require(records.first).summary.contains(" queued"))
        // A miss is the one worth reading, so it has to be in the words a
        // person sees rather than only in the header a client sees.
        #expect(try #require(records.first).summary.contains("miss"))
        // Asking for the original is neither: nothing was decoded to produce it.
        #expect(try #require(records.last).summary.contains("hit") == false)
        #expect(try #require(records.last).summary.contains("miss") == false)
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

    @Test("`Accept` decides the format when a rendering is produced")
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

    @Test("A held rendering the client cannot accept is re-rendered, and the replacement takes its place")
    func unacceptableHeldFormatIsReplaced() async throws {
        let library = try Library()
        try await library.fill()

        // A HEIC rendering is held at this size.
        let first = try await library.get("w=100&h=100")
        #expect(headers(first)["Content-Type"] == "image/heic")

        let uuid = try #require(
            try library.sources.database.scalarString("SELECT uuid FROM photo LIMIT 1;"))
        let key = PhotoStore.Key(photoUUID: uuid, size: .init(width: 100, height: 100))
        let heic = try #require(library.cache.store.url(for: key))
        #expect(heic.pathExtension == "heic")

        // A client that accepts only JPEG must not be handed those bytes: the
        // contract is that the format comes from `Accept`, and before this test
        // it held only on the miss path.
        let second = try await library.get("w=100&h=100", accept: "image/jpeg")
        #expect(second.status == 200)
        #expect(headers(second)["Content-Type"] == "image/jpeg")

        // One rendering per (photo, size): the JPEG replaced the HEIC, and the
        // old file is gone rather than stranded on disk where no index entry
        // can ever name it again.
        let replaced = try #require(library.cache.store.url(for: key))
        #expect(replaced.pathExtension == "jpeg")
        #expect(!FileManager.default.fileExists(atPath: heic.path(percentEncoded: false)))

        // A permissive client then hits the JPEG — acceptable is the test, not
        // identical to what negotiation would have picked fresh.
        let third = try await library.get("w=100&h=100", accept: "image/heic, image/jpeg")
        #expect(headers(third)["Content-Type"] == "image/jpeg")
        #expect(headers(third)["X-PGR-Cache"] == "hit")
    }

    @Test("An Accept admitting neither format is refused with 406, and costs no card")
    func unproducibleAcceptIsRefused() async throws {
        let library = try Library()
        try await library.fill()
        try await library.topUp()
        let queued = try library.cache.queue.size()

        let response = try await library.get(
            "w=100&h=100", accept: "image/png", toppingUp: false)
        #expect(response.status == 406)
        // Refused before the pop: a request that cannot be answered in any
        // format must not spend a card finding that out.
        #expect(try library.cache.queue.size() == queued)
    }

    @Test("With the original evicted, an unacceptable held rendering goes out rather than nothing")
    func heldRenderingServesWhenOriginalIsGone() async throws {
        let library = try Library()
        try await library.fill(materialized: true)

        _ = try await library.get("w=100&h=100")  // HEIC rendering kept
        try await library.topUp()
        try library.evictTheOriginal()

        // Nothing to re-render from, so the bytes we hold go out with the
        // reason logged — a format preference is not worth answering a client
        // with nothing.
        let response = try await library.get(
            "w=100&h=100", accept: "image/jpeg", toppingUp: false)
        #expect(response.status == 200)
        #expect(headers(response)["Content-Type"] == "image/heic")
    }

    // MARK: - What a 200 carries

    @Test("A 200 names the photograph's source and storage, rendered or original")
    func headersCarrySourceAndStorage() async throws {
        // Two folders can hold `Image_001.jpg`; when something is wrong with
        // one source, which one is serving is the first question. These two
        // headers are the answer, and nothing daemon-side pinned them before —
        // dropping either from `PictureEndpoint.headers(for:)` passed the
        // whole suite.
        let library = try Library()
        try await library.fill()

        let rendered = try await library.get("consumer=test&w=100&h=100")
        #expect(headers(rendered)["X-PGR-Source"] == String(library.sourceIdentifier))
        #expect(headers(rendered)["X-PGR-Storage"] == "referenced")

        let original = try await library.getOriginal()
        #expect(headers(original)["X-PGR-Source"] == String(library.sourceIdentifier))
        #expect(headers(original)["X-PGR-Storage"] == "referenced")
        #expect(headers(original)["X-PGR-Card"] != nil)
        #expect(headers(original)["X-PGR-Deal"] != nil)
        // The original was not decoded, so there is no size to report.
        #expect(headers(original)["X-PGR-Pixels"] == nil)
    }

    @Test("A 200's bytes survive the file being deleted after the answer is decided")
    func servedBytesSurviveDeletion() async throws {
        // Serving pops the card, which removes the photograph's eviction
        // protection at the moment it goes out. The body is an open handle for
        // exactly this reason: whatever deletes the file afterwards —
        // maintenance, a removal, a source delete — the promised bytes are
        // already safe.
        let library = try Library()
        try await library.fill()

        let response = try await library.getOriginal()
        #expect(response.status == 200)
        guard case .file(let stream) = response.body else {
            Issue.record("expected a streaming body")
            return
        }

        let source = library.directory.appending(path: "photos/photo-0.png")
        let expected = try Data(contentsOf: source)
        try FileManager.default.removeItem(at: source)

        let delivered = try stream.handle.readToEnd() ?? Data()
        #expect(Int64(delivered.count) == stream.byteCount)
        #expect(delivered == expected)
    }

    // MARK: - Photographs that will not render

    @Test("A photograph that will not render costs the request a skip, then retires")
    func unrenderablePhotographIsSkippedAndRetired() async throws {
        let library = try Library()
        // A file the scanner accepts and the decoder cannot open, beside a
        // good one. The deck half of retirement is pinned in `DeckTests`; this
        // is the endpoint half — the catch-skip-continue loop that hands the
        // client the next photograph rather than an error.
        FileManager.default.createFile(
            atPath: library.directory.appending(path: "photos/broken.png")
                .path(percentEncoded: false),
            contents: Data(repeating: 0x00, count: 128))
        try await library.fill()

        func failures() throws -> Int {
            try library.sources.database.scalarInt(
                "SELECT render_failures FROM photo WHERE external_id = 'broken.png';") ?? 0
        }

        // Serve until the bad file has burned its three attempts. Every answer
        // along the way is a 200 with the good photograph — the client never
        // sees the failure.
        for _ in 0..<20 {
            if try failures() >= Deck.renderFailureLimit { break }
            let response = try await library.get("w=100&h=100")
            #expect(response.status == 200)
        }
        #expect(try failures() >= Deck.renderFailureLimit, "the bad file was never retired")

        // Retired means never offered again: the deck's candidates exclude it,
        // so a fresh fill queues only the good photograph.
        let deck = Deck(database: library.sources.database)
        #expect(try deck.blacklisted().map(\.externalID) == ["broken.png"])
        // And nothing the client was handed was ever the broken file.
        #expect(library.log.all.filter { $0.status == 200 }.allSatisfy { $0.detail != "broken.png" })
    }

    // MARK: - A library that cannot be opened

    @Test("An unopenable library answers 503 on both endpoints, not a crash")
    func unopenableLibraryIs503() async throws {
        // A directory where the database file should be: `sqlite3_open` cannot
        // open it, and the refusal has to be the endpoint's answer rather than
        // an unwound task.
        let directory = URL.temporaryDirectory.appending(path: "pgr-503-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bogus = directory.path(percentEncoded: false)

        let pictures = PictureEndpoint(
            databasePath: bogus, cacheRoot: directory,
            preferences: Preferences(defaults: UserDefaults(suiteName: "pgr.503.\(UUID())")!),
            store: PhotoStore(root: directory), queueRanShort: {}, log: { _ in })
        let picture = await pictures.route(
            try #require(HTTPListener.parse("GET /v1/next HTTP/1.1")))
        #expect(picture.status == 503)

        let sources = SourceEndpoint(
            databasePath: bogus,
            preferences: Preferences(defaults: UserDefaults(suiteName: "pgr.503.\(UUID())")!),
            bytes: PhotoStore(root: directory), log: { _ in })
        let list = await sources.route(
            try #require(HTTPListener.parse("GET /v1/sources HTTP/1.1")))
        #expect(list.status == 503)
    }
}


/// Filling a queue the way the agent does, in the two steps it now takes: deal
/// the cards, then fetch the bytes for what was dealt. A copy of the kit tests'
/// helper, because a test target cannot see another test target's code.
extension PhotoCache {
    @discardableResult
    func fillCompletely(limit: Int = 500) async throws -> Int {
        var dealt = 0
        while dealt < limit, try deal() { dealt += 1 }
        for card in try queue.peek(Int.max) {
            _ = try await cache(photoID: card.id)
        }
        return try queue.size()
    }
}
