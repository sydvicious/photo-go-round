import Foundation
import PhotoGoRoundKit
import PhotoGoRoundAgentAPI

/// What the agent is doing, for a person with a browser.
///
/// ```
/// GET /dashboard                            the page
/// GET /v1/dashboard                         what the page shows, as JSON
/// GET /v1/dashboard/thumbnail?photo=<id>    a small JPEG of one photograph
/// ```
///
/// **The page is for an installed agent.** A LaunchAgent's console goes nowhere
/// anybody reads, and its unified log has to be dug out with `log show`; this is
/// the same facts, one URL away, redrawn every second.
///
/// **The page is a string in the binary, and draws itself.** It holds no
/// numbers: its script asks `/v1/dashboard` once a second and fills them in. The
/// listener closes every connection after one answer, so there is nothing to
/// push over — and a poll against loopback is a few milliseconds.
///
/// **Quiet.** No route here writes a console line or a log record per request.
/// A page open in a browser asks sixty times a minute, and the request log is
/// something a person reads.
struct DashboardEndpoint {
    let databasePath: String
    let cacheRoot: URL
    let preferences: Preferences
    /// The process's index, whose totals are what the cache holds.
    let store: PhotoStore
    /// The picture endpoint's count of what it has handed over and what it
    /// found in the cache.
    let tally: LaunchTally
    /// The agent's record of its errors. The shared one in the agent; a test
    /// hands in its own.
    var errors: AgentErrors = .shared

    static let pagePath = "/dashboard"
    static let path = "/v1/dashboard"
    static let thumbnailPath = "/v1/dashboard/thumbnail"
    /// Both bounds, in pixels. The page draws it in a 240-point frame, so this
    /// is sharp on a Retina display and no larger.
    static let thumbnailSize = 480

    /// Every route, and anything under the JSON one, so a mistyped path there is
    /// answered here rather than logged by the pictures as a stray request.
    static func claims(_ path: String) -> Bool {
        path == pagePath || path == Self.path || path.hasPrefix(Self.path + "/")
    }

    /// Everything the page draws.
    struct Snapshot: Codable, Equatable {
        /// Every photograph row, in every source, whatever its state.
        var photos: Int
        /// Originals held in the cache.
        var cached: Int
        var cacheBytes: Int64
        var cacheCeilingBytes: Int64
        /// Free space on the cache's volume. Absent when the volume would not
        /// say, rather than a number that means "unknown".
        var freeBytes: Int64?
        /// Below this, nothing more is fetched. See `CacheSettings`.
        var freeFloorBytes: Int64
        /// Cards dealt and waiting to be served.
        var queued: Int
        /// How many cards the deck keeps dealt ahead: `queueSize`.
        var queueSize: Int
        /// Pictures handed over since launch, by the consumer that asked.
        var served: [String: Int]
        /// What serving found in the cache since launch — almost always hits.
        var serveLookups: LaunchTally.ServeLookups
        /// What dealing found in the cache since launch, and what became of
        /// the fetches — on a large library, mostly misses.
        var fetchLookups: LaunchTally.FetchLookups
        /// What the agent's maintenance evicted from the cache since launch.
        var evictions: LaunchTally.Evictions
        /// The picture most recently handed over. Absent until one has been.
        var last: Last?
        /// The errors reported since launch, one per kind, most recently seen
        /// first. See `AgentErrors`.
        var errors: [AgentErrors.Entry]
        /// When the agent launched, which is when `served` began counting.
        var since: Date
        /// When this was taken.
        var at: Date

        struct Last: Codable, Equatable {
            /// The photograph's row id, which is what the thumbnail route takes.
            var photo: Int64
            var consumer: String
            var at: Date
            /// What its source is called: a path, or `Photos › Trips › Holiday`.
            var source: String
            /// Its original filename when one was recorded, its identifier
            /// otherwise.
            var name: String
            /// Its identifier, which is the name for a folder photograph and a
            /// `PHAsset` identifier for a Photos one.
            var externalID: String
        }
    }

    func route(_ request: HTTPListener.Request) async -> HTTPListener.Response {
        guard request.method == "GET" else {
            return .text("only GET is served\n", status: 405, reason: "Method Not Allowed")
        }
        switch request.path {
        case Self.pagePath:
            return HTTPListener.Response(
                status: 200, reason: "OK",
                headers: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Cache-Control": "no-store",
                ],
                body: .data(Data(DashboardPage.html.utf8)))
        case Self.path:
            return answer()
        case Self.thumbnailPath:
            return thumbnail(request)
        default:
            return .text("no such endpoint\n", status: 404, reason: "Not Found")
        }
    }

    private func answer() -> HTTPListener.Response {
        let taken: Snapshot
        do {
            taken = try snapshot()
        } catch {
            Log.deck.error(
                kind: "dashboard.library-unavailable", "dashboard could not read the library: \(error)")
            return .text("library unavailable\n", status: 503, reason: "Service Unavailable")
        }
        guard let bytes = try? SourceEndpoint.encoder().encode(taken) else {
            Log.deck.error(kind: "dashboard.encode-failed", "a dashboard response would not encode")
            return .text(
                "the library could not answer\n", status: 500, reason: "Internal Server Error")
        }
        return HTTPListener.Response(
            status: 200, reason: "OK",
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store",
            ],
            body: .data(bytes))
    }

    /// A connection per request, for the same reason `PictureEndpoint` opens
    /// one: a `Database` belongs to one isolation domain.
    ///
    /// **Preferences are read on every call**, and `Preferences` keeps no copy
    /// of its own, so a changed ceiling or queue size is in the next reading.
    /// How soon after the write depends on `cfprefsd`, which the agent's loop
    /// makes re-read on the doorbell and every thirty seconds regardless.
    func snapshot(now: Date = Date()) throws -> Snapshot {
        let database = try Database(path: databasePath)
        try Migrator.migrate(database)
        let deck = Deck(database: database)
        let status = try makeCache(database: database, deck: deck).status()
        let photos = try deck.stats(settings: preferences.deckSettings).totalPhotos

        return Snapshot(
            photos: photos,
            cached: status.residentCount,
            cacheBytes: status.bytesOnDisk,
            cacheCeilingBytes: status.byteCeiling,
            // `PhotoCache` answers `.max` for a volume that would not say.
            freeBytes: status.freeBytesOnVolume == .max ? nil : status.freeBytesOnVolume,
            freeFloorBytes: preferences.cacheSettings.minimumFreeBytes,
            queued: status.queued,
            queueSize: preferences.queueSize,
            served: tally.served,
            serveLookups: tally.serveLookups,
            fetchLookups: tally.fetchLookups,
            evictions: tally.evictions,
            last: tally.lastServed.map {
                Snapshot.Last(
                    photo: $0.photo, consumer: $0.consumer, at: $0.at,
                    source: $0.sourceName, name: $0.name, externalID: $0.externalID)
            },
            errors: errors.entries,
            since: tally.since,
            at: now
        )
    }

    private func makeCache(database: Database, deck: Deck) -> PhotoCache {
        PhotoCache(
            database: database,
            root: cacheRoot,
            settings: preferences.cacheSettings,
            sources: SourceStore(database: database, bytes: store),
            deck: deck,
            queueSize: preferences.queueSize,
            store: store
        )
    }

    // MARK: - The last picture

    /// Rendered from the original, wherever it is — in the cache for a
    /// materialized photograph, in place for a referenced one. **Nothing about
    /// the deck is touched**: no card is taken, nothing is counted as served,
    /// and a photograph that will not decode here is not charged a render
    /// failure, since the page asking is not a consumer asking.
    private func thumbnail(_ request: HTTPListener.Request) -> HTTPListener.Response {
        guard let photo = request.query("photo").flatMap({ Int64($0) }) else {
            return .text("name a photo: ?photo=<id>\n", status: 400, reason: "Bad Request")
        }

        let url: URL?
        do {
            let database = try Database(path: databasePath)
            try Migrator.migrate(database)
            url = try makeCache(database: database, deck: Deck(database: database))
                .residentURL(forPhoto: photo)
        } catch {
            Log.deck.error(
                kind: "dashboard.thumbnail-lookup-failed",
                "dashboard could not look up photo \(photo): \(error)")
            return .text("library unavailable\n", status: 503, reason: "Service Unavailable")
        }
        guard let url else {
            return .text("photo \(photo) is not here to draw\n", status: 404, reason: "Not Found")
        }

        do {
            let rendered = try PhotoRenderer.render(
                contentsOf: url, fitting: Self.thumbnailSize, by: Self.thumbnailSize, as: .jpeg)
            return HTTPListener.Response(
                status: 200, reason: "OK",
                headers: [
                    // JPEG whatever the browser says it accepts: not every
                    // browser a person might open this in draws HEIC.
                    "Content-Type": rendered.format.mimeType,
                    "Cache-Control": "no-store",
                ],
                body: .data(rendered.bytes))
        } catch {
            Log.deck.notice(
                "dashboard thumbnail for photo \(photo, privacy: .public) would not render: \(String(describing: error), privacy: .public)")
            return .text(
                "photo \(photo) would not render\n", status: 422, reason: "Unprocessable Content")
        }
    }
}
