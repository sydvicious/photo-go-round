import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import PhotosGoRoundAgentAPI
@testable import PhotosGoRoundKit
@testable import PhotosGoRoundServer

/// The dashboard: its routes, what the JSON says, and that the page's poll
/// stays out of the request log.
///
/// Driven through `route`, the picture endpoint and the router, because what
/// the dashboard counts is only produced where they meet: a picture reaching a
/// consumer is a fact of the picture endpoint, and reading it back is a fact of
/// this one.
@Suite("Dashboard endpoint", .timeLimit(.minutes(2)))
struct DashboardEndpointTests {

    /// A migrated library, a folder of real photographs, and both endpoints
    /// over it sharing one tally — the arrangement `RunCommand` builds.
    private final class Library {
        let directory: URL
        let cache: PhotoCache
        let sources: SourceStore
        let pictures: PictureEndpoint
        let dashboard: DashboardEndpoint
        let store: PhotoStore
        /// The preferences both endpoints read, so a test can change them.
        let defaults: UserDefaults
        let tally = LaunchTally()
        let served = Collector()
        /// Its own, so what another test records never shows up here.
        let errors = AgentErrors(recording: true)
        /// Its own, and the one the sources count into, for the same reason.
        let changes = LibraryChanges(recording: true)

        init(photographs: Int = 0) throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-dash-\(UUID().uuidString)")
            let photos = directory.appending(path: "photos")
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            for index in 0..<photographs {
                try Self.write(to: photos.appending(path: "photo-\(index).png"))
            }

            let path = directory.appending(path: "photosgoround.sqlite").path(percentEncoded: false)
            let database = try Database(path: path)
            try Migrator.migrate(database)
            sources = SourceStore(database: database, changes: changes)

            let cacheRoot = directory.appending(path: "cache")
            let store = PhotoStore(root: cacheRoot)
            self.store = store
            cache = PhotoCache(
                database: database, root: cacheRoot, sources: sources, queueSize: 100, store: store)
            defaults = scratchSuite("dash")
            let preferences = Preferences(defaults: defaults)
            let collector = served
            var pictures = PictureEndpoint(
                databasePath: path, cacheRoot: cacheRoot, preferences: preferences,
                store: store, queueRanShort: {}, log: { collector.record($0) }
            ).awaitingResizes()
            pictures.tally = tally
            self.pictures = pictures
            dashboard = DashboardEndpoint(
                databasePath: path, cacheRoot: cacheRoot, preferences: preferences,
                store: store, tally: tally, errors: errors, changes: changes
            ).awaitingResizes()
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        /// Materialized means copied into the cache, which is the only storage
        /// a cache lookup is counted for. A folder under the temporary
        /// directory is on the boot volume, so it is referenced unless told
        /// otherwise.
        func fill(materialized: Bool = false) async throws {
            try await cache.prepare()
            let folder = directory.appending(path: "photos").path(percentEncoded: false)
            let source = try sources.add(kind: .folder, locator: folder)
            _ = await sources.refresh(source)
            if materialized {
                try sources.database.run("UPDATE photo SET storage = 'materialized';")
            }
            _ = try await cache.fillCompletely()
        }

        /// One picture for `consumer`, with the queue topped up first so a
        /// second request is not answered from an emptied queue.
        func serve(to consumer: String) async throws -> Int {
            _ = try await cache.fillCompletely()
            return await pictures.route(
                try get("/v1/next?consumer=\(consumer)&w=100&h=100")).status
        }

        func snapshot() async throws -> DashboardEndpoint.Snapshot {
            // **The ledgers take their reports through a queue**, so a test that
            // records and then reads is ahead of the drain unless it says so.
            // A barrier through the same queue, not a wait on a clock.
            await tally.settle()
            await errors.settle()
            let response = await dashboard.route(try get(DashboardEndpoint.path))
            #expect(response.status == 200)
            guard case .data(let bytes) = response.body else {
                Issue.record("the dashboard answered without a body")
                throw CancellationError()
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DashboardEndpoint.Snapshot.self, from: bytes)
        }


        static func write(to url: URL) throws {
            let context = CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
    }

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

    /// Nothing in it, and never asked: the router needs a photos endpoint to be
    /// built at all, and no request here reaches one.
    private struct NoLibrary: PhotoLibrary {
        var authorization: LibraryAuthorization { get async { .authorized } }
        func requestAuthorization() async -> LibraryAuthorization { .authorized }
        func collections() async -> [LibraryCollection] { [] }
        func folderPaths() async -> [String: [String]] { [:] }
        func imageCount(ofCollection identifier: String) async -> Int? { nil }
        func title(ofCollection identifier: String) async -> String? { nil }
        @discardableResult
        func enumerateImages(
            inCollection identifier: String, _ body: (LibraryAsset) async throws -> Void
        ) async throws -> Bool { false }
        func assetExists(_ identifier: String) async -> Bool { false }
        func resources(ofAsset identifier: String) async -> [LibraryResource] { [] }
        func write(
            _ resource: LibraryResource, ofAsset identifier: String, to destination: URL
        ) async throws -> Int64 { 0 }
    }

    // MARK: - Routes

    /// The body of a dashboard route, or nil after recording why not.
    private func text(_ response: HTTPListener.Response) -> String? {
        guard case .data(let bytes) = response.body else {
            Issue.record("answered without a body")
            return nil
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// **Three files from `MacOS/Agent/Dashboard/Resources/`** since 2026-09-16, when
    /// the page stopped being a string in `DashboardPage.swift`. Under
    /// `swift test` there is no app bundle, so these are read from the source
    /// folder — the second place `DashboardPage` looks.
    @Test("The page is HTML that links its stylesheet and script, and draws itself from the JSON route")
    func pageIsServed() async throws {
        let library = try Library()

        let page = await library.dashboard.route(try get(DashboardEndpoint.pagePath))
        #expect(page.status == 200)
        #expect(page.headers["Content-Type"] == "text/html; charset=utf-8")
        let html = try #require(text(page))
        #expect(html.contains(#"href="/dashboard/dashboard.css""#))
        #expect(html.contains(#"src="/dashboard/dashboard.js""#))

        let style = await library.dashboard.route(try get("/dashboard/dashboard.css"))
        #expect(style.status == 200)
        #expect(style.headers["Content-Type"] == "text/css; charset=utf-8")

        let script = await library.dashboard.route(try get("/dashboard/dashboard.js"))
        #expect(script.status == 200)
        #expect(script.headers["Content-Type"] == "text/javascript; charset=utf-8")
        let js = try #require(text(script))
        #expect(js.contains(#"fetch("/v1/dashboard""#))
        #expect(js.contains("/v1/dashboard/thumbnail?photo="))
        // A busy resizer is "not yet": the page keeps the image it has.
        #expect(js.contains("response.status === 503"))
        // Refused is "stop asking": the cookie is gone, and every later poll
        // would be refused too.
        #expect(js.contains("response.status === 401"))
    }

    /// The app bundle first, so an installed agent never reads a source folder
    /// it may not be next to; the source folder second, for a build with no bundle.
    @Test("The page's files are looked for in the app bundle, then beside the agent's sources")
    func assetsAreFoundInOrder() throws {
        let source = "/repo/MacOS/Agent/Dashboard/Sources/DashboardPage.swift"
        let bundle = try #require(Bundle(path: URL.temporaryDirectory.path(percentEncoded: false)))
        let looked = DashboardPage.candidates(for: .js, bundle: bundle, source: source)
            .map { $0.path(percentEncoded: false) }

        #expect(looked.last == "/repo/MacOS/Agent/Dashboard/Resources/dashboard.js")
        #expect(looked.count == 2)
        #expect(DashboardPage.contents(of: .js, bundle: bundle, source: source) == nil)
    }

    @Test("Only GET is served, and nothing under the JSON route but the thumbnail, nor under the page but its files")
    func refusals() async throws {
        let library = try Library()

        var post = try get(DashboardEndpoint.path)
        post = HTTPListener.Request(
            method: "POST", path: post.path, query: [:], headers: [:], receivedAt: .now)
        #expect(await library.dashboard.route(post).status == 405)
        #expect(await library.dashboard.route(try get("/v1/dashboard/nope")).status == 404)
        #expect(await library.dashboard.route(try get("/dashboard/nope.js")).status == 404)
    }

    @Test("The dashboard claims its routes and what is under them, and nothing else")
    func claims() {
        #expect(DashboardEndpoint.claims("/dashboard"))
        #expect(DashboardEndpoint.claims("/dashboard/dashboard.js"))
        #expect(DashboardEndpoint.claims("/dashboard/dashboard.css"))
        #expect(DashboardEndpoint.claims("/v1/dashboard"))
        #expect(DashboardEndpoint.claims("/v1/dashboard/thumbnail"))

        #expect(!DashboardEndpoint.claims("/dashboards"))
        #expect(!DashboardEndpoint.claims("/v1/dashboards"))
        #expect(!DashboardEndpoint.claims("/v1/next"))
        #expect(!DashboardEndpoint.claims("/"))
    }

    /// An open page asks once a second. Were these routes the picture
    /// endpoint's, every poll would be a 404 on the console.
    @Test("The page's requests are never a line in the request log")
    func pollIsQuiet() async throws {
        let library = try Library(photographs: 1)
        try await library.fill()
        let photos = NoLibrary()
        let router = Router(
            pictures: library.pictures,
            sources: SourceEndpoint(
                databasePath: library.dashboard.databasePath,
                preferences: library.dashboard.preferences, bytes: library.dashboard.store),
            photos: PhotosEndpoint(
                catalog: PhotosCollectionCatalog(library: photos), library: photos),
            dashboard: library.dashboard)

        #expect(await router.route(try get("/dashboard")).status == 200)
        #expect(await router.route(try get("/v1/dashboard")).status == 200)
        #expect(await router.route(try get("/v1/dashboard/nope")).status == 404)
        let photo = try #require(try library.cache.queue.peek().first).id
        #expect(await router.route(try get("/v1/dashboard/thumbnail?photo=\(photo)")).status == 200)

        #expect(library.served.all.isEmpty)
    }

    // MARK: - What it says

    @Test("An empty library reports nothing held, nothing served, and no last picture")
    func emptyLibrary() async throws {
        let library = try Library()
        let snapshot = try await library.snapshot()

        #expect(snapshot.photos == 0)
        #expect(snapshot.libraryChanges.isEmpty)
        #expect(snapshot.cached == 0)
        #expect(snapshot.cacheBytes == 0)
        #expect(snapshot.served.isEmpty)
        #expect(snapshot.last == nil)
        #expect(snapshot.errors.isEmpty)
        #expect(snapshot.evictions == LaunchTally.Evictions())
        #expect(snapshot.fetchLookups == LaunchTally.FetchLookups())
        #expect(snapshot.cacheCeilingBytes == CacheSettings.default.byteCeiling)
        #expect(snapshot.freeFloorBytes == CacheSettings.default.minimumFreeBytes)
    }

    @Test("Every photograph row is counted, and the cache figures are the cache's own")
    func counts() async throws {
        let library = try Library(photographs: 3)
        try await library.fill()
        let snapshot = try await library.snapshot()
        let status = try await library.cache.status()

        #expect(snapshot.photos == 3)
        #expect(snapshot.cached == status.residentCount)
        #expect(snapshot.cacheBytes == status.bytesOnDisk)
    }

    @Test("Photographs added and removed are reported by source, and a removed source keeps its name")
    func libraryChangesAreReported() async throws {
        let library = try Library(photographs: 3)
        try await library.fill()
        let source = try #require(try library.sources.all().first)

        #expect(
            try await library.snapshot().libraryChanges
                == [.init(source: source.spokenName, sourceRemoved: false, added: 3, removed: 0)])

        try await library.sources.remove(id: source.id)

        #expect(
            try await library.snapshot().libraryChanges
                == [.init(source: source.spokenName, sourceRemoved: true, added: 3, removed: 3)])
    }

    @Test("The page draws the changes by source, and a standing condition as standing")
    func pageHasChangesAndStanding() async throws {
        let library = try Library()
        // The headings are the page's and the drawing is the script's, both in
        // `MacOS/Agent/Dashboard/Resources/`; what is asserted is that the two together
        // draw it.
        let html = await library.dashboard.route(try get(DashboardEndpoint.pagePath))
        let script = await library.dashboard.route(try get("/dashboard/dashboard.js"))
        guard case .data(let htmlBytes) = html.body, case .data(let scriptBytes) = script.body else {
            Issue.record("the page or its script answered without a body")
            return
        }
        let page = String(decoding: htmlBytes + scriptBytes, as: UTF8.self)
        #expect(page.contains("s.libraryChanges"))
        #expect(page.contains("e.standing"))
        #expect(page.contains("e.until"))
    }

    @Test("Pictures handed over are counted by the consumer that asked for them")
    func servedByConsumer() async throws {
        let library = try Library(photographs: 3)
        try await library.fill()

        #expect(try await library.serve(to: "app") == 200)
        #expect(try await library.serve(to: "screensaver") == 200)
        #expect(try await library.serve(to: "screensaver") == 200)

        let snapshot = try await library.snapshot()
        #expect(snapshot.served == ["app": 1, "screensaver": 2])
    }

    /// `cli` and `anonymous` are served like anybody else, and a total that
    /// left them out would disagree with the console.
    @Test("A consumer nobody listed is counted too")
    func unlistedConsumer() async throws {
        let library = try Library(photographs: 2)
        try await library.fill()

        _ = try await library.cache.fillCompletely()
        #expect(await library.pictures.route(try get("/v1/next?w=10&h=10")).status == 200)
        #expect(try await library.serve(to: "cli") == 200)

        #expect(try await library.snapshot().served == ["anonymous": 1, "cli": 1])
    }

    @Test("A request that reached nobody is not counted")
    func emptyAnswerIsNotCounted() async throws {
        let library = try Library()
        #expect(try await library.serve(to: "wallpaper") == 204)
        #expect(try await library.snapshot().served.isEmpty)
    }

    // MARK: - The fetch side

    @Test("The fetch side counts dealt cards held or not, and what became of each fetch")
    func fetchLookupsAreReported() async throws {
        let library = try Library()
        library.tally.record(DealLookup.hit)
        library.tally.record(DealLookup.miss)
        library.tally.record(DealLookup.miss)
        library.tally.record(fetch: .fetched)
        library.tally.record(fetch: .timedOut)

        let fetch = try await library.snapshot().fetchLookups
        #expect(
            fetch == LaunchTally.FetchLookups(hits: 1, misses: 2, fetched: 1, failed: 0, timedOut: 1))
    }

    @Test("The page draws a serve panel and a fetch panel")
    func pageHasBothSides() async throws {
        let library = try Library()
        // The headings are the page's and the drawing is the script's, both in
        // `MacOS/Agent/Dashboard/Resources/`; what is asserted is that the two together
        // draw it.
        let html = await library.dashboard.route(try get(DashboardEndpoint.pagePath))
        let script = await library.dashboard.route(try get("/dashboard/dashboard.js"))
        guard case .data(let htmlBytes) = html.body, case .data(let scriptBytes) = script.body else {
            Issue.record("the page or its script answered without a body")
            return
        }
        let page = String(decoding: htmlBytes + scriptBytes, as: UTF8.self)
        #expect(page.contains("Serve: cache lookups since launch"))
        #expect(page.contains("Fetch: cache lookups since launch"))
        #expect(page.contains("s.serveLookups"))
        #expect(page.contains("s.fetchLookups"))
    }

    // MARK: - Evictions

    @Test("Evictions are totalled across the passes that took something, with the last one's time and cause")
    func evictionsAreReported() async throws {
        let library = try Library()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        library.tally.record(
            PhotoCache.EvictionResult(evicted: 3, bytesFreed: 9_000_000), at: start)
        // Nothing taken: not a pass worth counting, and it must not move `lastAt`.
        library.tally.record(
            PhotoCache.EvictionResult(evicted: 0, bytesFreed: 0), at: start.addingTimeInterval(30))
        library.tally.record(
            PhotoCache.EvictionResult(evicted: 2, bytesFreed: 4_000_000, ceilingHalved: true),
            at: start.addingTimeInterval(60))

        let evictions = try await library.snapshot().evictions
        #expect(
            evictions
                == LaunchTally.Evictions(
                    photos: 5, bytesFreed: 13_000_000, passes: 2,
                    lastAt: start.addingTimeInterval(60), lastCeilingHalved: true))
    }

    @Test("The page draws the evictions panel from the JSON")
    func pageHasEvictions() async throws {
        let library = try Library()
        // The headings are the page's and the drawing is the script's, both in
        // `MacOS/Agent/Dashboard/Resources/`; what is asserted is that the two together
        // draw it.
        let html = await library.dashboard.route(try get(DashboardEndpoint.pagePath))
        let script = await library.dashboard.route(try get("/dashboard/dashboard.js"))
        guard case .data(let htmlBytes) = html.body, case .data(let scriptBytes) = script.body else {
            Issue.record("the page or its script answered without a body")
            return
        }
        let page = String(decoding: htmlBytes + scriptBytes, as: UTF8.self)
        #expect(page.contains("Cache evictions since launch"))
        #expect(page.contains("s.evictions"))
    }

    // MARK: - Errors

    /// Read at a fixed moment, because a row's life is measured from when it
    /// was reported.
    @Test("The errors recorded are in the reading, one per kind, most recent first")
    func errorsAreReported() async throws {
        let library = try Library()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        library.errors.record(
            kind: "cache.timed-out.source-6", "CACHE: a.jpg did not answer in 60s", at: start)
        library.errors.record(
            kind: "source.empty.source-2", "source 2 is empty", at: start.addingTimeInterval(5))
        library.errors.record(
            kind: "cache.timed-out.source-6", "CACHE: b.jpg did not answer in 60s",
            at: start.addingTimeInterval(10))

        // The reports go through a queue; drain it before reading.
        await library.errors.settle()
        let errors = try await library.dashboard.snapshot(now: start.addingTimeInterval(10)).errors
        #expect(errors.compactMap(\.kind) == ["cache.timed-out.source-6", "source.empty.source-2"])
        #expect(errors.map(\.count) == [2, 1])
        #expect(errors.first?.message == "CACHE: b.jpg did not answer in 60s")
        #expect(errors.first?.firstSeen == start)
    }

    @Test("An error not seen for a minute is gone from the reading, and a standing condition is not")
    func errorsClear() async throws {
        let library = try Library()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        library.errors.record(
            kind: "cache.timed-out.source-6", "CACHE: a.jpg did not answer in 60s", at: start)
        library.errors.record(
            kind: "source.unavailable.source-2", "source 2 unavailable: not mounted",
            lasting: .standing, at: start)

        // The reports go through a queue; drain it before reading.
        await library.errors.settle()
        let errors = try await library.dashboard.snapshot(now: start.addingTimeInterval(61)).errors
        #expect(errors.compactMap(\.kind) == ["source.unavailable.source-2"])
        #expect(errors.first?.standing == true)
    }

    // MARK: - The last picture

    @Test("The last picture served is named by its file, its folder, and who it went to")
    func lastPictureFromAFolder() async throws {
        let library = try Library(photographs: 2)
        try await library.fill()

        #expect(try await library.serve(to: "screensaver") == 200)
        #expect(try await library.serve(to: "app") == 200)

        let served = try #require(library.served.all.last)
        let last = try #require(try await library.snapshot().last)
        #expect(last.photo == served.card)
        #expect(last.name == served.detail)
        #expect(last.name.hasPrefix("photo-"))
        #expect(last.externalID == last.name)
        #expect(last.source.hasSuffix("/photos"))
        #expect(last.source == served.sourceName)
        #expect(last.consumer == "app")
    }

    /// A Photos photograph cannot be served in this suite — nothing here is a
    /// Photos library — so the tally is handed the card and source serving
    /// would have handed it.
    @Test("A Photos photograph is named by its original file and its album, with its identifier kept")
    func lastPictureFromPhotos() async throws {
        let library = try Library()
        let card = DeckCard(
            id: 7, uuid: "u", sourceID: 9, sourceUUID: "s", externalID: "C3D4/L0/001",
            storage: .materialized, dealSeq: 12, originalFilename: "IMG_0042.HEIC")
        let album = Source(
            id: 9, uuid: "s", kind: .photosCollection, locator: "A1B2/L0/040",
            description: SourceDescription(
                title: "Holiday", collectionKind: "userAlbum", folders: ["Trips"]),
            addedAt: Date(timeIntervalSince1970: 0))

        library.tally.recordServed(
            consumer: "wallpaper", card: card, source: album,
            at: Date(timeIntervalSince1970: 1_800_000_000))

        let last = try #require(try await library.snapshot().last)
        #expect(
            last
                == .init(
                    photo: 7, consumer: "wallpaper", at: Date(timeIntervalSince1970: 1_800_000_000),
                    source: "Photos › Trips › Holiday", name: "IMG_0042.HEIC",
                    externalID: "C3D4/L0/001"))
    }

    @Test("The thumbnail is a small JPEG of the photograph, and asking for it takes no card")
    func thumbnail() async throws {
        let library = try Library(photographs: 2)
        try await library.fill()
        let photo = try #require(try library.cache.queue.peek().first).id
        let queued = try library.cache.queue.size()

        let response = await library.dashboard.route(
            try get("\(DashboardEndpoint.thumbnailPath)?photo=\(photo)"))

        #expect(response.status == 200)
        #expect(response.headers["Content-Type"] == "image/jpeg")
        guard case .data(let bytes) = response.body else {
            Issue.record("the thumbnail answered without a body")
            return
        }
        #expect(!bytes.isEmpty)
        #expect(try library.cache.queue.size() == queued, "a thumbnail spent a card")
        #expect(library.served.all.isEmpty)
    }

    /// Syd, 2026-09-16, of the resize cache: "yes, same cache".
    @Test("A thumbnail asked for twice is resized once")
    func thumbnailIsKept() async throws {
        let library = try Library(photographs: 1)
        try await library.fill()
        let photo = try #require(try library.cache.queue.peek().first).id
        let resizes = Mutex(0)
        var dashboard = library.dashboard
        dashboard.resizer = Resizer()
        dashboard.resize = { original, side in
            resizes.withLock { $0 += 1 }
            return try PhotoRenderer.render(contentsOf: original, fitting: side, by: side, as: .jpeg)
        }
        let copies = KeptCopies()
        dashboard.kept = copies.collect

        for pass in 0..<2 {
            let response = await dashboard.route(
                try get("\(DashboardEndpoint.thumbnailPath)?photo=\(photo)"))
            #expect(response.status == 200)
            #expect(response.headers["Content-Type"] == "image/jpeg")
            // The copy is written in a task of its own, so the second pass has
            // to ask after it is on disk rather than before.
            if pass == 0 { await copies.settle() }
        }
        #expect(resizes.withLock { $0 } == 1)
    }

    /// Syd, 2026-09-16: "So, after you write any file to the cache, run
    /// evict()."
    @Test("A picture's resized copy that takes the cache over its ceiling evicts, and says so")
    func aKeptPictureCopyEvicts() async throws {
        let library = try Library(photographs: 2)
        try await library.fill(materialized: true)
        _ = try await library.cache.fillCompletely()
        // The originals fit exactly; any copy goes over.
        let ceiling = try await library.cache.bytesOnDisk()
        library.defaults.set(ceiling, forKey: Preferences.Key.cacheByteCeiling.rawValue)
        let evictions = Mutex<[PhotoCache.EvictionResult]>([])
        var pictures = library.pictures
        pictures.resizer = Resizer()
        pictures.evicted = { result in evictions.withLock { $0.append(result) } }
        let copies = KeptCopies()
        pictures.kept = copies.collect

        let response = await pictures.route(
            try #require(HTTPListener.parse("GET /v1/next?w=200&h=200 HTTP/1.1")))

        #expect(response.status == 200)
        // One pass, which took something. How much depends on the sizes: a
        // copy bigger than the oldest original takes itself too. The eviction
        // happens inside the task that keeps the copy, so awaiting that task
        // is awaiting the eviction.
        await copies.settle()
        let passes = evictions.withLock { $0 }
        #expect(passes.count == 1)
        #expect(passes.allSatisfy { $0.evicted > 0 })
        await #expect(try library.cache.bytesOnDisk() <= ceiling)
    }

    @Test("A dashboard thumbnail that takes the cache over its ceiling evicts, and says so")
    func aKeptThumbnailEvicts() async throws {
        let library = try Library(photographs: 2)
        try await library.fill(materialized: true)
        _ = try await library.cache.fillCompletely()
        let photo = try #require(try library.cache.queue.peek().first).id
        let ceiling = try await library.cache.bytesOnDisk()
        library.defaults.set(ceiling, forKey: Preferences.Key.cacheByteCeiling.rawValue)
        let evictions = Mutex<[PhotoCache.EvictionResult]>([])
        var dashboard = library.dashboard
        dashboard.resizer = Resizer()
        dashboard.evicted = { result in evictions.withLock { $0.append(result) } }
        let copies = KeptCopies()
        dashboard.kept = copies.collect

        let response = await dashboard.route(
            try get("\(DashboardEndpoint.thumbnailPath)?photo=\(photo)"))

        #expect(response.status == 200)
        // One pass, which took something. How much depends on the sizes: a
        // copy bigger than the oldest original takes itself too. The eviction
        // happens inside the task that keeps the copy, so awaiting that task
        // is awaiting the eviction.
        await copies.settle()
        let passes = evictions.withLock { $0 }
        #expect(passes.count == 1)
        #expect(passes.allSatisfy { $0.evicted > 0 })
        await #expect(try library.cache.bytesOnDisk() <= ceiling)
    }

    /// **A stalled resizer is "not yet", not "never".** Measured 2026-09-16: a
    /// thumbnail waited 38.9 s behind the picture requests' resizes, and the
    /// page's image fell further behind its filename with every picture. Syd
    /// chose to give it the same budget as `/v1/next`; the page keeps the image
    /// it has and asks again on its next redraw.
    @Test("A thumbnail whose resize stalls answers 503 inside the budget")
    func stalledThumbnailIsNotReady() async throws {
        let library = try Library(photographs: 1)
        try await library.fill()
        let photo = try #require(try library.cache.queue.peek().first).id

        let gate = DispatchSemaphore(value: 0)
        var dashboard = library.dashboard
        dashboard.resizer = Resizer()
        // The budget is this test's subject, so the production one.
        dashboard.resizeBudget = ServiceTiming.resizeBudget
        dashboard.resize = { _, _ in
            _ = gate.wait(timeout: .now() + 60)
            throw PhotoRenderer.Failure.decodeFailed
        }
        defer { gate.signal() }

        let clock = ContinuousClock()
        let started = clock.now
        let response = await dashboard.route(
            try get("\(DashboardEndpoint.thumbnailPath)?photo=\(photo)"))
        let took = clock.now - started

        #expect(response.status == 503)
        #expect(response.headers["Retry-After"] == "1")
        #expect(took >= ServiceTiming.resizeBudget)
        #expect(took < ServiceTiming.pictureReadLimit, "took \(took)")
    }

    @Test("A thumbnail names its photograph, and one that is not here is a 404")
    func thumbnailRefusals() async throws {
        let library = try Library(photographs: 1)
        try await library.fill(materialized: true)

        let path = DashboardEndpoint.thumbnailPath
        #expect(await library.dashboard.route(try get(path)).status == 400)
        #expect(await library.dashboard.route(try get("\(path)?photo=seven")).status == 400)
        #expect(await library.dashboard.route(try get("\(path)?photo=999999")).status == 404)

        // Evicted, however the fill left it: the bytes go, and the record with them.
        let head = try #require(try library.cache.queue.peek().first)
        await library.store.remove(photoUUID: head.uuid)
        try library.cache.releaseResidency(ofPhotos: [head.uuid])
        #expect(await library.dashboard.route(try get("\(path)?photo=\(head.id)")).status == 404)
    }

    // MARK: - Queue and preferences

    @Test("The queue is reported against the size it is kept at")
    func queueAgainstItsSize() async throws {
        let library = try Library(photographs: 3)
        try await library.fill()
        let snapshot = try await library.snapshot()

        #expect(snapshot.queued == (try library.cache.queue.size()))
        #expect(snapshot.queued > 0)
        #expect(snapshot.queueSize == library.dashboard.preferences.queueSize)
    }

    /// Nothing in the endpoint keeps a copy of a preference, so a change is in
    /// the very next reading — the page is a place to watch a `defaults write`
    /// take effect.
    @Test("A change to the cache ceiling or the queue size is in the next reading")
    func followsPreferences() async throws {
        let library = try Library()
        let before = try await library.snapshot()

        library.defaults.set(123_456_789, forKey: Preferences.Key.cacheByteCeiling.rawValue)
        library.defaults.set(7, forKey: Preferences.Key.queueSize.rawValue)
        let after = try await library.snapshot()

        #expect(before.cacheCeilingBytes != 123_456_789)
        #expect(before.queueSize != 7)
        #expect(after.cacheCeilingBytes == 123_456_789)
        #expect(after.queueSize == 7)
    }

    // MARK: - Cache lookups

    @Test("An original already in the cache, served, is a hit on the dashboard")
    func hitReachesTheDashboard() async throws {
        let library = try Library(photographs: 1)
        try await library.fill(materialized: true)
        try await library.cache.fetchAllQueued()

        #expect(
            await library.pictures.route(try get("/v1/next?consumer=app&w=10&h=10")).status == 200)
        #expect(try await library.snapshot().serveLookups == LaunchTally.ServeLookups(hits: 1))
    }

    @Test("An original not in the cache, with no wait allowed, is a miss dropped without waiting")
    func missReachesTheDashboard() async throws {
        let library = try Library(photographs: 1)
        try await library.fill(materialized: true)
        library.defaults.set(0, forKey: Preferences.Key.serveWaitSeconds.rawValue)
        // Cold, however the fill left it: the bytes go, and the record with them.
        let head = try #require(try library.cache.queue.peek().first)
        await library.store.remove(photoUUID: head.uuid)
        try library.cache.releaseResidency(ofPhotos: [head.uuid])

        #expect(
            await library.pictures.route(try get("/v1/next?consumer=app&w=10&h=10")).status == 204)

        let snapshot = try await library.snapshot()
        #expect(snapshot.serveLookups == LaunchTally.ServeLookups(droppedWithoutWaiting: 1))
        #expect(snapshot.serveLookups.misses == 1)
        #expect(snapshot.served.isEmpty)
    }

    @Test("Serving a referenced photograph leaves the lookups alone")
    func referencedIsNotALookup() async throws {
        let library = try Library(photographs: 1)
        try await library.fill()

        #expect(try await library.serve(to: "app") == 200)
        #expect(try await library.snapshot().serveLookups == LaunchTally.ServeLookups())
    }
}

private func get(_ target: String) throws -> HTTPListener.Request {
    try #require(HTTPListener.parse("GET \(target) HTTP/1.1"))
}
