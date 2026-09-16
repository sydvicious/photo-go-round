import Foundation
import PhotoGoRoundKit
import PhotoGoRoundAgentAPI

/// What the agent is doing, for a person with a browser.
///
/// ```
/// GET /dashboard                            the page
/// GET /dashboard/dashboard.css               its stylesheet
/// GET /dashboard/dashboard.js                its script
/// GET /v1/dashboard                         what the page shows, as JSON
/// GET /v1/dashboard/thumbnail?photo=<id>    a small JPEG of one photograph
/// ```
///
/// **The page is for an installed agent.** A LaunchAgent's console goes nowhere
/// anybody reads, and its unified log has to be dug out with `log show`; this is
/// the same facts, one URL away, redrawn every second.
///
/// **The page is three files in `js/`, beside these sources, and draws itself.** See
/// `DashboardPage` for where they are found. It holds no numbers: its script
/// asks `/v1/dashboard` once a second and fills them in. The
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
    /// The agent's count of photographs added and removed. The shared one in
    /// the agent; a test hands in its own.
    var changes: LibraryChanges = .shared

    /// Resizes an original to a thumbnail no larger than `side` on its longest
    /// edge, as JPEG. A hook so a test can make it hang.
    var resize: @Sendable (_ original: URL, _ side: Int) throws -> PhotoRenderer.Rendered = {
        original, side in
        try PhotoRenderer.render(contentsOf: original, fitting: side, by: side, as: .jpeg)
    }

    /// Where `resize` runs: the agent's one resizer, shared with `/v1/next`.
    var resizer: Resizer = .shared

    /// How long a thumbnail waits for its resize before answering 503.
    /// `ServiceTiming.resizeBudget`, the same as a picture request's.
    var resizeBudget: Duration = ServiceTiming.resizeBudget

    static let pagePath = "/dashboard"
    static let path = "/v1/dashboard"
    static let thumbnailPath = "/v1/dashboard/thumbnail"
    /// Both bounds, in pixels. The page draws it in a 240-point frame, so this
    /// is sharp on a Retina display and no larger.
    static let thumbnailSize = 480

    /// Every route, and anything under the JSON one, so a mistyped path there is
    /// answered here rather than logged by the pictures as a stray request.
    static func claims(_ path: String) -> Bool {
        path == pagePath || path.hasPrefix(pagePath + "/") || path == Self.path
            || path.hasPrefix(Self.path + "/")
    }

    /// Everything the page draws.
    struct Snapshot: Codable, Equatable {
        /// Every photograph row, in every source, whatever its state.
        var photos: Int
        /// Photographs added to and removed from the database since launch,
        /// one row per source that has done either, ordered by name.
        var libraryChanges: [LibraryChange]
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
        /// The errors standing now and those reported in the last minute, one
        /// per kind, most recently seen first. See `AgentErrors`.
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

        struct LibraryChange: Codable, Equatable {
            /// What the source is called now, or was called when it was removed.
            var source: String
            /// Whether the source itself is gone.
            var sourceRemoved: Bool
            var added: Int
            var removed: Int
        }
    }

    func route(_ request: HTTPListener.Request) async -> HTTPListener.Response {
        guard request.method == "GET" else {
            return .text("only GET is served\n", status: 405, reason: "Method Not Allowed")
        }
        switch request.path {
        case Self.pagePath:
            return asset(.html)
        case Self.pagePath + "/" + DashboardPage.Asset.css.rawValue:
            return asset(.css)
        case Self.pagePath + "/" + DashboardPage.Asset.js.rawValue:
            return asset(.js)
        case Self.path:
            return answer()
        case Self.thumbnailPath:
            return await thumbnail(request)
        default:
            return .text("no such endpoint\n", status: 404, reason: "Not Found")
        }
    }

    /// One of the page's files, or a 500 naming it and where it was looked for.
    private func asset(_ asset: DashboardPage.Asset) -> HTTPListener.Response {
        guard let data = DashboardPage.contents(of: asset) else {
            let looked = DashboardPage.candidates(for: asset).map { $0.path(percentEncoded: false) }
            Log.deck.error(
                kind: "dashboard.asset-missing",
                "dashboard could not find \(asset.rawValue); looked in \(looked.joined(separator: ", "))")
            return .text(
                "\(asset.rawValue) is missing; looked in \(looked.joined(separator: ", "))\n",
                status: 500, reason: "Internal Server Error")
        }
        return HTTPListener.Response(
            status: 200, reason: "OK",
            headers: ["Content-Type": asset.contentType, "Cache-Control": "no-store"],
            body: .data(data))
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
        // Named as the source is called now; a source no longer in the table
        // by what it was called when it went, or by its row id when it went
        // somewhere this process did not see.
        let current = Dictionary(
            uniqueKeysWithValues: try SourceStore(database: database).all().map { ($0.id, $0) })
        let libraryChanges = changes.bySource.map { id, count in
            Snapshot.LibraryChange(
                source: current[id]?.spokenName ?? changes.nameOfRemovedSource(id) ?? "source \(id)",
                sourceRemoved: current[id] == nil, added: count.added, removed: count.removed)
        }.sorted { $0.source.localizedStandardCompare($1.source) == .orderedAscending }

        return Snapshot(
            photos: photos,
            libraryChanges: libraryChanges,
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
            errors: errors.entries(at: now),
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
    private func thumbnail(_ request: HTTPListener.Request) async -> HTTPListener.Response {
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
            // On the agent's one resizer, like every other resize. See `Resizer`.
            // **Bounded, and "not yet" when the bound runs out.** Measured
            // 2026-09-16: a thumbnail waited 38.9 s behind the picture
            // requests' resizes, and the page's image fell further behind its
            // filename with every picture. Syd chose the same budget as
            // `/v1/next`. A browser cannot be handed the original — not every
            // one draws HEIC — so the answer is 503, and the page keeps the
            // image it has and asks again.
            let resize = self.resize
            let resizer = self.resizer
            let ticket = Resizer.Ticket()
            let outcome: (result: PhotoRenderer.Rendered, started: ContinuousClock.Instant)
            do {
                outcome = try await Deadline.run(within: resizeBudget) {
                    try await resizer.run(ticket) { try resize(url, Self.thumbnailSize) }
                }
            } catch is Deadline.Expired {
                ticket.abandon()
                Log.deck.info(
                    "RESIZE: dashboard thumbnail gave up after \(StageTimes.milliseconds(resizeBudget), privacy: .public) on photo \(photo, privacy: .public); answering 503")
                return HTTPListener.Response(
                    status: 503, reason: "Service Unavailable",
                    headers: [
                        "Content-Type": "text/plain; charset=utf-8", "Retry-After": "1",
                        "Cache-Control": "no-store",
                    ],
                    body: .data(Data("the resizer is busy; ask again\n".utf8)))
            }
            let rendered = outcome.result
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
