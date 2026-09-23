import Foundation
import Synchronization
import Testing

@testable import PhotosGoRoundAgentAPI
@testable import PhotosGoRoundKit

/// Serving pictures while a large Photos album is being re-read.
///
/// **Measured 2026-09-16.** The agent's launch refresh re-read Favorites — 8,547
/// photographs, nothing added or removed — in 73 seconds, and for that whole
/// time `/v1/next` took 10 to 50 seconds against a client that gives up at
/// five. The agent before it did the same during its scheduled refresh at
/// 13:12. Before and after, the same requests took 150–700 ms.
///
/// **Two connections, the way the agent has them.** The refresh opens its own
/// `Database` in its own task, as `RunCommand.refreshSources` does, and each
/// request opens another and does what `PictureEndpoint.next` does to the
/// database: register the consumer, serve, mark the card delivered.
///
/// **This passes, and that is a finding, not a fix.** Written to reproduce the
/// stall, it did not: the re-read took 0.24 s and the slowest request 12 ms.
/// A walk that also blocked a thread for 430 ms per 500 photographs, as
/// `SystemPhotoLibrary.Album` does, took 8.8 s and its slowest request 5 ms.
/// So two connections sharing the writer is not enough on its own. The
/// endpoint's `TIMING:` line was added the same day to say what is.
@Suite("Serving while a large album is re-read")
struct RefreshWhileServingTests {

    /// Favorites on Syd's Mac, 2026-09-16.
    static let albumSize = 8547
    /// Enough warm cards to serve through the whole refresh.
    static let held = 200

    private let album = "EE63D18C-5827-4C7B-8CE9-673C62E19E64/L0/040"

    @Test("Every picture request during a refresh answers before the client gives up")
    func servingKeepsUpDuringARefresh() async throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-refresh-serve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = TestLibrary.path(in: directory)
        let root = directory.appending(path: "cache")

        let assets = (0..<Self.albumSize).map { LibraryAsset(identifier: "ASSET-\($0)/L0/001") }
        let photos = FakePhotoLibrary(
            titles: [album: "Favorites"],
            assets: [album: assets],
            resources: Dictionary(
                uniqueKeysWithValues: assets.map { ($0.identifier, [LibraryResource(kind: .photo)]) }))
        let library = BoundedPhotoLibrary(photos)
        let bytes = PhotoStore(root: root)

        func store(_ database: Database) -> SourceStore {
            SourceStore(
                database: database,
                providers: [PhotosCollectionSourceProvider(library: library)],
                bytes: bytes)
        }

        // The pool as the agent finds it at launch: every photograph already
        // known, and a queue of cards whose bytes are held.
        let setup = try TestLibrary.onDisk(at: directory)
        let setupSources = store(setup.database)
        var setupCache = PhotoCache(
            database: setup.database, root: root, sources: setupSources, queueSize: Self.held,
            store: bytes)
        setupCache.log = { _ in }
        try await setupCache.prepare()
        let source = try setupSources.add(kind: .photosCollection, locator: album)
        let clock = ContinuousClock()
        var started = clock.now
        _ = await setupSources.refresh(source)
        let firstWalk = clock.now - started
        #expect(try await setupCache.fillCompletely(limit: Self.held) == Self.held)

        // The re-read, on its own connection.
        let refreshing = Mutex(true)
        started = clock.now
        let refresh = Task.detached {
            defer { refreshing.withLock { $0 = false } }
            guard let database = try? Database(path: path) else { return Duration.zero }
            let began = ContinuousClock.now
            _ = await store(database).refresh(source)
            return ContinuousClock.now - began
        }

        // Requests, one after another, for as long as the refresh runs.
        var took: [Duration] = []
        while refreshing.withLock({ $0 }), took.count < Self.held {
            let request = clock.now
            let database = try Database(path: path)
            var cache = PhotoCache(
                database: database, root: root, sources: store(database), queueSize: Self.held,
                store: bytes)
            cache.log = { _ in }
            let deck = Deck(database: database)
            let consumer = try deck.register(kind: ConsumerKind("app"), displayID: "DISPLAY").id
            let served = try await cache.serve(to: consumer)
            if let served { try deck.markDelivered(photoID: served.card.id) }
            took.append(clock.now - request)
        }
        let refreshTook = await refresh.value

        let slowest = took.max() ?? .zero
        print(
            """
            first walk \(firstWalk), re-read \(refreshTook), \(took.count) requests during it, \
            slowest \(slowest), \
            median \(took.sorted()[took.isEmpty ? 0 : took.count / 2])
            """)
        #expect(!took.isEmpty, "the refresh finished before a single request was made")
        #expect(
            slowest < ServiceTiming.pictureReadLimit,
            "the slowest request took \(slowest) against a client that gives up at \(ServiceTiming.pictureReadLimit)")
    }
}
