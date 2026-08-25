import Console
import Foundation
import PhotoGoRoundKit
import UniformTypeIdentifiers

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
    /// Where a picture whose bytes are not local goes. Serving asks for it and
    /// moves on, so a miss costs this request a skip rather than a wait.
    var wantsCaching: @Sendable (Int64) -> Void = { _ in }
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
        /// Whether the pixels came from a rendering we already had.
        ///
        /// Nil when no size was asked for, because the original is neither: it
        /// is the file itself, and nothing was decoded to produce it.
        var cache: Cache?

        /// A miss is the interesting one, and the milliseconds beside it are
        /// what it cost — a decode and a re-encode of a full-resolution
        /// photograph, which is the number the whole render-on-demand design is
        /// judged on.
        enum Cache: String, Sendable {
            case hit
            case miss
        }

        /// What the cache holds, at the moment this request was answered.
        ///
        /// Beside the hit or miss because the two are read together: a miss is
        /// ordinary while the cache is filling and worth a second look once it
        /// is not, and the size is how you tell which.
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
            if let cache {
                parts.append(
                    cache.rawValue + (cacheBytes.map { " of \(RunCommand.bytes($0))" } ?? ""))
            }
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
                bytes=\(bytes, privacy: .public) cache=\(cache?.rawValue ?? "n/a", privacy: .public) \
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
        cache.wantsCaching = wantsCaching
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
        cache: Served.Cache? = nil,
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
                cache: cache,
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
            // The box is named up front, because the cache needs it to answer
            // at all: a photograph whose original has been evicted can still be
            // served from a rendering held at exactly this size, and only the
            // caller knows what size that is.
            let size = box.map { PhotoStore.Size(width: $0.width, height: $0.height) }

            while let served = try await context.cache.serve(to: consumerID, fitting: size) {
                queueRanShort()

                // What a re-render would decode from. The served URL, except
                // for a held rendering the client cannot accept, where it
                // becomes the original.
                var renderSource = served.url

                // Already rendered at this size: hand over the file rather than
                // decoding again — when the client accepts its format. On a
                // small library this is the common case, because a photograph
                // comes round every few minutes — and it is the *only* case
                // when the original is no longer held.
                var serveHeld = served.isRendering
                if served.isRendering {
                    let held = PhotoRenderer.Format(
                        rawValue: served.url.pathExtension.lowercased())
                    let acceptable = held?.admitted(by: accept) ?? false
                    if !acceptable {
                        if let original = (try? context.cache.residentURL(
                            forPhoto: served.card.id)) ?? nil
                        {
                            // Re-render in the format the client asked for; the
                            // replacement takes the held file's place at this
                            // size — see `PhotoStore.store`.
                            serveHeld = false
                            renderSource = original
                        } else {
                            // Nothing to re-render from. The bytes we hold go
                            // out rather than nothing — a format preference is
                            // not worth answering a client with no picture.
                            Console.event(
                                "\(served.card.externalID) held as \(served.url.pathExtension) which the client does not accept; original gone, serving it anyway")
                            Log.deck.notice(
                                "photo \(served.card.id, privacy: .public) served in an unaccepted format; the original is no longer held")
                        }
                    }
                }
                if serveHeld {
                    // Opened before anything is promised. The pop removed this
                    // photograph's eviction protection, so the file can vanish
                    // between here and the pump; an open handle keeps the bytes
                    // whatever happens to the name, and a failed open is the
                    // race caught before any header is written — skipped like
                    // any other card whose bytes are not here.
                    guard let stream = HTTPListener.Response.StreamedFile(url: served.url) else {
                        vanished(served, context: context)
                        continue
                    }
                    var headers = Self.headers(
                        for: served.card, contentType: Self.contentType(of: served.url))
                    // Read from the file rather than echoing the box that was
                    // asked for: the header describes what the client is handed,
                    // and that has to mean the same thing hit or miss.
                    if let pixels = PhotoRenderer.pixelSize(of: served.url) {
                        headers["X-PGR-Pixels"] = "\(pixels.width)x\(pixels.height)"
                    }
                    headers["X-PGR-Cache"] = "hit"
                    try? context.deck.markDelivered(photoID: served.card.id)
                    report(
                        request, status: 200, detail: served.card.externalID,
                        card: served.card, bytes: stream.byteCount, cache: .hit,
                        cacheBytes: store.totals.byteCount,
                        queued: try? context.cache.queue.size())
                    return HTTPListener.Response(
                        status: 200, reason: "OK", headers: headers, body: .file(stream))
                }

                guard let box, let size else {
                    // No size asked for: the original, untouched — opened now,
                    // for the same reason as above.
                    guard let stream = HTTPListener.Response.StreamedFile(url: served.url) else {
                        vanished(served, context: context)
                        continue
                    }
                    try? context.deck.markDelivered(photoID: served.card.id)
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
                    let rendered = try PhotoRenderer.render(
                        contentsOf: renderSource, fitting: box.width, by: box.height, as: format)
                    // Keep it. A failure to write is not a failure to serve.
                    _ = try? context.cache.keep(
                        rendered.bytes, of: served.card, at: size,
                        pathExtension: rendered.format.rawValue)

                    var headers = Self.headers(
                        for: served.card, contentType: rendered.format.mimeType)
                    headers["X-PGR-Pixels"] = "\(rendered.width)x\(rendered.height)"
                    headers["X-PGR-Cache"] = "miss"
                    try? context.deck.markDelivered(photoID: served.card.id)
                    report(
                        request, status: 200, detail: served.card.externalID,
                        card: served.card, bytes: Int64(rendered.bytes.count), cache: .miss, cacheBytes: store.totals.byteCount,
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

            // Ordinary, not an error. A fresh install answers this way until
            // downloads land, and every surface has an empty state already.
            //
            // **And it asks for more, which reverses what this comment used to
            // say.**
            //
            // The old reasoning was that the cards this walk passed over are all
            // out being fetched and will come back, so dealing here buys a fresh
            // cold card in place of a warm one already paid for. That is sound
            // about a walk that *passed over* cards. It says nothing about a
            // walk that found none — `walked 0`, an empty queue — where nothing
            // was skipped, nothing is coming back, and tying the deal to
            // pictures actually served makes the one event that could restart
            // dealing the one event that cannot happen.
            //
            // Observed 2026-08-25: an empty queue answering 204 every three
            // seconds for minutes with a full pool behind it. So a 204 rings the
            // filler. The overshoot the old note worried about is prevented
            // where it belongs — `FillerBox.Gauge.isShort` still counts cards in
            // flight as the queue's the moment the queue has anything at all.
            queueRanShort()
            report(request, status: 204, detail: "no photos available")
            return .noContent()
        } catch {
            report(request, status: 500, detail: "could not serve a picture")
            Log.deck.error("serving failed: \(String(describing: error), privacy: .public)")
            return .text("could not serve a picture\n", status: 500, reason: "Internal Server Error")
        }
    }

    /// A card whose bytes disappeared between the index saying held and the
    /// open — the eviction race's one remaining door. The card is skipped
    /// exactly as one whose bytes were never there, and a materialized
    /// photograph is asked for again so the bytes come back.
    private func vanished(_ served: PhotoCache.ServedPhoto, context: (cache: PhotoCache, deck: Deck)) {
        Console.event(
            "\(served.card.externalID) vanished between the index and the open; skipping it")
        Log.deck.notice(
            "photo \(served.card.id, privacy: .public) vanished before its bytes could be opened")
        if served.card.storage == .materialized { wantsCaching(served.card.id) }
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
