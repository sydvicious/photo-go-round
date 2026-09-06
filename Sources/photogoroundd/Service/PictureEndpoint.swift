import Console
import Foundation
import PhotoGoRoundKit
import UniformTypeIdentifiers
import PhotoGoRoundAgentAPI

/// The one endpoint that matters.
///
/// ```
/// GET /v1/next?consumer=screensaver&display=<uuid>&w=3840&h=2160
/// → 200  the picture
/// → 204  nothing queued
/// ```
///
/// **The answer is rendered to the box the client asked for**, in the format it
/// said it would accept, so what arrives can be drawn 1:1 without resampling.
/// Naming no size at all returns the original bytes untouched, which is what
/// `curl` wants and what a client that intends to decode for itself would ask
/// for.
///
/// The pop happens here, and it happens whether or not the download succeeds.
/// There is no reservation, nothing with a lifetime, and nothing to reclaim from
/// a client that goes away mid-transfer — a failed download is a lost picture,
/// and the client asks again.
struct PictureEndpoint {
    let databasePath: String
    let cacheRoot: URL
    let preferences: Preferences
    /// The one index for this process. A `PhotoCache` is built per request, but
    /// the record of what is on disk is not — a fresh one would know nothing,
    /// write a file, and miss it again on the next request.
    let store: PhotoStore
    /// Called after a picture is handed over, because serving is the only thing
    /// that shortens the queue and therefore the only thing that can notice it
    /// has run low. The host decides what to do about it; this just says so.
    let queueRanShort: @Sendable () -> Void
    /// Called when a request found nothing to show.
    ///
    /// **A different event from the deck running short.** Running short
    /// follows a picture reaching somebody; coming up empty means no picture
    /// reached anybody, and the deck must be refilled all the same.
    ///
    /// Without this the deck can only be refilled by a picture being served or
    /// by the heartbeat, and the heartbeat runs behind the refresh. Removing a
    /// source on 2026-08-26 emptied the deck by cascade and left it empty for
    /// thirty seconds — the length of a network source's walk — with 592
    /// servable photographs in the cache and the window blank throughout.
    var deckCameUpEmpty: @Sendable () -> Void = {}
    /// Asked when a request meets a head card whose bytes are not here, so the
    /// host can make sure it is being fetched. Wired to the queue fetcher's
    /// kick.
    var ensureFetching: @Sendable () -> Void = {}
    /// The process's bench, so serving does not wait on a card whose source
    /// has stopped answering. Nil never benches anything.
    var bench: SourceBench?
    /// Where the queue's decisions are said. Separate from the served-request
    /// log above it, which records what a *client* was handed.
    var speak: @Sendable (QueueEvent) -> Void = { $0.report() }
    /// The one route this serves.
    static let path = "/v1/next"

    /// Where a served request is recorded. Injected so a test can collect the
    /// entries and read them, rather than watching a terminal.
    var log: @Sendable (Served) -> Void = { $0.report() }

    /// One request, as it happened. A value rather than a formatted line, so the
    /// facts can be asserted without parsing the sentence they end up in.
    struct Served: Sendable, Equatable {
        var status: Int
        /// The photograph's name when one was served, and what went wrong when
        /// one was not.
        var detail: String
        var consumer: String
        var width: String?
        var height: String?
        var card: Int64?
        var deal: Int64?
        /// Which source the photograph came from. **The name alone does not say**
        /// — two folders can hold `Image_001.jpg`, and when something is wrong
        /// with one source the first question is which one is being served from.
        ///
        /// The row id rather than the `uuid`, because this line is read by a
        /// person: `source 6` is what `pgr_ctl sources list` prints beside the
        /// path, and a uuid is thirty-six characters of nothing to hold on to.
        /// A client naming a source still uses the `uuid` — that identity is
        /// stable and this one is not.
        var sourceID: Int64?
        var bytes: Int64
        var milliseconds: Double
        /// What the cache holds, at the moment this request was answered.
        ///
        /// **`cache: hit | miss` used to sit beside this** and went with the
        /// resize cache on 2026-09-06: every sized request renders now, so a
        /// field that is always `miss` says nothing. The milliseconds at the end
        /// of the line are what the render cost, which is the number the
        /// render-on-demand design is judged on.
        var cacheBytes: Int64?
        /// How many cards were still queued after this one was taken.
        ///
        /// The queue is the thing being drained and topped up continuously, so a
        /// depth that is falling says the walk is outrunning the deck, and one
        /// pinned at its target says it is not.
        var queued: Int?

        /// Everything after the name, and the only place that wording lives.
        var summary: String {
            var parts = [consumer]
            if let sourceID { parts.append("source \(sourceID)") }
            if let width, let height { parts.append("\(width)x\(height)") }
            if let deal { parts.append("deal #\(deal)") }
            if bytes > 0 { parts.append(RunCommand.bytes(bytes)) }
            if let cacheBytes { parts.append("cache \(RunCommand.bytes(cacheBytes))") }
            if let queued { parts.append("\(queued) queued") }
            parts.append(milliseconds.formatted(.number.precision(.fractionLength(1))) + "ms")
            return parts.joined(separator: " · ")
        }

        /// The console line and the unified-log record. Separate from the value
        /// above so that what a request *was* can be asserted without asserting
        /// how it happens to be phrased.
        func report() {
            switch status {
            case 200: Console.change("▸", detail, .yellow, suffix: summary)
            case 500...599: Console.alert("\(status) \(detail) · \(summary)")
            default: Console.event("\(status) \(detail) · \(summary)")
            }

            Log.deck.notice(
                """
                served status=\(status, privacy: .public) consumer=\(consumer, privacy: .public) \
                card=\(card ?? 0, privacy: .public) deal=\(deal ?? 0, privacy: .public) \
                bytes=\(bytes, privacy: .public) \
                source=\(sourceID ?? 0, privacy: .public) \
                cacheBytes=\(cacheBytes ?? -1, privacy: .public) \
                queued=\(queued ?? -1, privacy: .public) ms=\(milliseconds, privacy: .public)
                """
            )
        }
    }

    /// A connection per request rather than one shared.
    ///
    /// A `Database` belongs to one isolation domain and WAL is what makes
    /// several of them safe, so concurrent requests get their own rather than
    /// serialising behind a lock. Opening one is sub-millisecond against a
    /// picture that arrives every several seconds.
    private func context() throws -> (cache: PhotoCache, deck: Deck) {
        let database = try Database(path: databasePath)
        try Migrator.migrate(database)
        let sources = SourceStore(database: database, bytes: store)
        let deck = Deck(database: database)
        var cache = PhotoCache(
                database: database,
                root: cacheRoot,
                settings: preferences.cacheSettings,
                sources: sources,
                deck: deck,
                queueSize: preferences.queueSize,
                store: store
        )
        cache.log = speak
        cache.serveWait = preferences.serveWait
        cache.ensureFetching = ensureFetching
        cache.bench = bench
        return (cache, deck)
    }

    func route(_ request: HTTPListener.Request) async -> HTTPListener.Response {
        guard request.method == "GET" else {
            report(request, status: 405, detail: "\(request.method) is not served")
            return .text("only GET is served\n", status: 405, reason: "Method Not Allowed")
        }
        switch request.path {
        case Self.path:
            return await next(request)
        default:
            report(request, status: 404, detail: "no such endpoint")
            return .text("no such endpoint\n", status: 404, reason: "Not Found")
        }
    }

    /// One line per request, on the console where a person is watching.
    ///
    /// Deliberately separate from the unified log below it: `os_log` is the
    /// shipping mechanism and works from inside every sandbox, but a person
    /// standing the service up needs the request to appear the moment it lands.
    private func report(
        _ request: HTTPListener.Request,
        status: Int,
        detail: String,
        card: DeckCard? = nil,
        bytes: Int64 = 0,
        cacheBytes: Int64? = nil,
        queued: Int? = nil
    ) {
        log(
            Served(
                status: status,
                detail: detail,
                consumer: request.query("consumer") ?? "anonymous",
                width: request.query("w"),
                height: request.query("h"),
                card: card?.id,
                deal: card?.dealSeq,
                sourceID: card?.sourceID,
                bytes: bytes,
                milliseconds: (ContinuousClock.now - request.receivedAt).totalSeconds * 1000,
                cacheBytes: cacheBytes,
                queued: queued
            )
        )
    }

    private func next(_ request: HTTPListener.Request) async -> HTTPListener.Response {
        let context: (cache: PhotoCache, deck: Deck)
        do {
            context = try self.context()
        } catch {
            report(request, status: 503, detail: "library unavailable")
            Log.deck.error("could not open the library: \(String(describing: error), privacy: .public)")
            return .text("library unavailable\n", status: 503, reason: "Service Unavailable")
        }

        // Consumer identity is parameters rather than registration: first sight
        // creates the row, every sight updates the heartbeat. Nothing to reap.
        let kind = ConsumerKind(request.query("consumer") ?? "cli")
        let consumerID = try? context.deck.register(
            kind: kind, displayID: request.query("display")
        ).id

        let box = Self.requestedSize(request)
        let accept = request.header("Accept")
        // Refused before the pop: a request that cannot be answered in any
        // format must not spend a card finding that out.
        guard let format = PhotoRenderer.Format.negotiated(accept: accept) else {
            report(request, status: 406, detail: "no acceptable format")
            return .text(
                "neither image/heic nor image/jpeg is acceptable\n",
                status: 406, reason: "Not Acceptable")
        }

        do {
            // A photograph that will not render is skipped to the next entry
            // rather than answered with an error: the client asked for a picture
            // and there are others. Only an exhausted queue is *no photos*.
            //
            // **The box is not passed down any more.** It used to be, so that a
            // photograph whose original had been evicted could be answered from
            // a rendering held at exactly this size. Nothing is held but
            // originals since 2026-09-06, so what comes back is the original and
            // the resize happens here, on every request.
            while let served = try await context.cache.serve(to: consumerID) {

                guard let box else {
                    // No size asked for: the original, untouched — opened now,
                    // for the same reason as above.
                    guard let stream = HTTPListener.Response.StreamedFile(url: served.url) else {
                        vanished(served, context: context)
                        continue
                    }
                    try? context.deck.markDelivered(photoID: served.card.id)
                    // **A deal follows a picture that reached somebody**, not a
                    // request that arrived. Rung at the top of this loop it
                    // fired once per card *taken*, so a request walking past
                    // three unrenderable photographs bought four fresh cards —
                    // against `PhotoCache`'s own statement that "a skip no
                    // longer buys a fresh card". `markDelivered` is the
                    // endpoint's existing notion of a 200 in hand, so this
                    // belongs beside it and nowhere else.
                    queueRanShort()
                    report(
                        request, status: 200, detail: served.card.externalID,
                        card: served.card, bytes: stream.byteCount)
                    return HTTPListener.Response(
                        status: 200, reason: "OK",
                        headers: Self.headers(
                            for: served.card, contentType: Self.contentType(of: served.url)),
                        body: .file(stream))
                }

                do {
                    // **Rendered and thrown away.** The bytes went into the
                    // cache under `(photo, resolution)` until 2026-09-06, where
                    // they were a gigabyte of near-duplicate boxes — a window
                    // moved two pixels and the whole set was made again — for a
                    // hit that a shuffle with a repeat window almost never
                    // takes. The decode is ~109 ms median, measured, and it is
                    // spent inside the gap between pictures rather than on a
                    // blank frame.
                    let rendered = try PhotoRenderer.render(
                        contentsOf: served.url, fitting: box.width, by: box.height, as: format)

                    var headers = Self.headers(
                        for: served.card, contentType: rendered.format.mimeType)
                    headers["X-PGR-Pixels"] = "\(rendered.width)x\(rendered.height)"
                    try? context.deck.markDelivered(photoID: served.card.id)
                    // **A deal follows a picture that reached somebody**, not a
                    // request that arrived. Rung at the top of this loop it
                    // fired once per card *taken*, so a request walking past
                    // three unrenderable photographs bought four fresh cards —
                    // against `PhotoCache`'s own statement that "a skip no
                    // longer buys a fresh card". `markDelivered` is the
                    // endpoint's existing notion of a 200 in hand, so this
                    // belongs beside it and nowhere else.
                    queueRanShort()
                    report(
                        request, status: 200, detail: served.card.externalID,
                        card: served.card, bytes: Int64(rendered.bytes.count),
                        cacheBytes: store.totals.byteCount,
                        queued: try? context.cache.queue.size())
                    return HTTPListener.Response(
                        status: 200, reason: "OK", headers: headers,
                        body: .data(rendered.bytes))
                } catch {
                    let failures = (try? context.deck.recordRenderFailure(photoID: served.card.id)) ?? 0
                    // Visible on the console as well as in the log, because a
                    // photograph leaving the library for good is a state change
                    // somebody watching should see happen.
                    if failures >= Deck.renderFailureLimit {
                        Console.alert(
                            "\(served.card.externalID) will not render; retired after \(failures) attempts")
                    } else {
                        Console.event(
                            "\(served.card.externalID) failed to render (\(failures)); skipping it")
                    }
                    Log.deck.error(
                        """
                        photo \(served.card.id, privacy: .public) failed to render \
                        (\(failures, privacy: .public) times): \
                        \(String(describing: error), privacy: .public)
                        """
                    )
                    continue
                }
            }

            // Ordinary, not an error, and it now means one thing only: the
            // deck's pool is empty, because the deck deals nothing it cannot
            // show. There is no second interpretation to distinguish and
            // nothing useful to ask for — the cache is already refreshing
            // itself, and a client that asks again in a few seconds will find
            // whatever landed in between.
            deckCameUpEmpty()
            report(request, status: 204, detail: "no photos available")
            return .noContent()
        } catch {
            report(request, status: 500, detail: "could not serve a picture")
            Log.deck.error("serving failed: \(String(describing: error), privacy: .public)")
            return .text("could not serve a picture\n", status: 500, reason: "Internal Server Error")
        }
    }

    /// A card whose bytes disappeared between the index saying held and the
    /// open — the eviction race's one remaining door.
    ///
    /// `PhotoCache.serve` already handles the ordinary case, where the bytes
    /// are gone before it looks. This is the narrower one where they go between
    /// its look and this open. Skipped the same way; the record is corrected by
    /// the next request that draws the card, or by the launch walk, whichever
    /// comes first.
    private func vanished(_ served: PhotoCache.ServedPhoto, context: (cache: PhotoCache, deck: Deck)) {
        Console.event(
            "\(served.card.externalID) vanished between the index and the open; skipping it")
        Log.deck.notice(
            "photo \(served.card.id, privacy: .public) vanished before its bytes could be opened")
    }

    /// The box the client asked to fill, or nil when it asked for the original.
    ///
    /// Both numbers or neither: half a box is a request nobody can satisfy
    /// sensibly, and guessing the other half would be inventing a fit rule the
    /// client did not ask for.
    static func requestedSize(_ request: HTTPListener.Request) -> (width: Int, height: Int)? {
        guard let width = request.query("w").flatMap(Int.init),
            let height = request.query("h").flatMap(Int.init),
            width > 0, height > 0
        else { return nil }
        return (width, height)
    }

    static func headers(for card: DeckCard, contentType: String) -> [String: String] {
        [
            "Content-Type": contentType,
            "X-PGR-Card": String(card.id),
            "X-PGR-Deal": String(card.dealSeq ?? 0),
            "X-PGR-Source": String(card.sourceID),
            "X-PGR-Storage": card.storage.rawValue,
        ]
    }

    /// From the extension, because that is what the cache path carries and what
    /// the source file is named. Conformance rather than a switch, so formats
    /// nobody listed are still described correctly.
    static func contentType(of url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()),
            let mime = type.preferredMIMEType
        else { return "application/octet-stream" }
        return mime
    }
}
