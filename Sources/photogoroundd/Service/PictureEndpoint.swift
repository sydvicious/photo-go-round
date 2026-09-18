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

    /// Where a picture handed over, and what serving found in the cache, are
    /// counted for the dashboard. Nil counts nothing, which is every test that
    /// is not about counting.
    var tally: LaunchTally?

    /// Told what an eviction took after a resized copy was kept. See
    /// `PhotoCache.evictAfterWriting()`.
    var evicted: @Sendable (PhotoCache.EvictionResult) -> Void = { _ in }

    /// Handed the task that keeps each resized copy. Nothing in the agent wants
    /// it; the tests await it rather than polling for the row. See `CopyPlace`.
    var kept: @Sendable (Task<Void, Never>) -> Void = { _ in }

    /// Resizes an original to the box a request asked for.
    ///
    /// **So a test can make a resize hang.** Added 2026-09-16 for `Agent
    /// Performance Overhaul.md`, Phase 1. The agent's `TIMING:` lines that
    /// afternoon had single resizes taking up to 741 seconds, and a thread
    /// sample caught one waiting on a synchronous call to the system's video
    /// decoder. A resize that fast machines finish in a fraction of a second
    /// cannot reproduce what that did to the agent; one that blocks on purpose
    /// can.
    ///
    /// Always run on `resizer`, never on the request's own thread.
    var resize: @Sendable (_ original: URL, _ width: Int, _ height: Int, _ format: PhotoRenderer.Format)
        throws -> PhotoRenderer.Rendered = { original, width, height, format in
            try PhotoRenderer.render(contentsOf: original, fitting: width, by: height, as: format)
        }

    /// Where `resize` runs: one at a time, off the shared pool. See `Resizer`.
    var resizer: Resizer = .shared

    /// How long a request waits for its resize before it sends the original.
    /// `ServiceTiming.resizeBudget`; see there.
    var resizeBudget: Duration = ServiceTiming.resizeBudget

    /// Where a resized copy is kept, carried onto the resizer's thread.
    ///
    /// A `PhotoCache` holds a `Database`, which belongs to one isolation
    /// domain, so the cache is opened where the copy is written rather than
    /// carried there; see `CopyPlace`.
    var copyPlace: CopyPlace {
        CopyPlace(
            databasePath: databasePath, cacheRoot: cacheRoot, settings: preferences.cacheSettings,
            store: store, evicted: evicted, kept: kept)
    }

    /// `RESIZE: gave up after 1000ms on IMG_0327.HEIC (…) · card 6921 · deal #84642; serving the original`
    ///
    /// The one line a stalled resize leaves, on the console and in the unified
    /// log. Filter on the prefix.
    static func resizeGaveUp(name: String, card: Int64, deal: Int64?, after budget: Duration) -> String {
        var parts = ["RESIZE: gave up after \(StageTimes.milliseconds(budget)) on \(name)", "card \(card)"]
        if let deal { parts.append("deal #\(deal)") }
        return parts.joined(separator: " · ") + "; serving the original"
    }

    /// One request, as it happened. A value rather than a formatted line, so the
    /// facts can be asserted without parsing the sentence they end up in.
    struct Served: Sendable, Equatable {
        var status: Int
        /// The photograph's name when one was served, and what went wrong when
        /// one was not.
        var detail: String
        var consumer: String
        /// Which display asked, when the client named one.
        ///
        /// **Consumers are keyed on `(kind, display)`**, so without this two
        /// displays of one surface read as one in the log, and a count per
        /// display — the wallpaper's twice an hour on each — cannot be taken
        /// from the agent's side. Added 2026-09-10; `Wallpaper Plan.md`, *What
        /// the agent logs*.
        var display: String? = nil
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
        /// What that source is called, beside its row id: `source 6
        /// (Photos › Trips › Holiday)`. The id alone is what `pgr_ctl` answers
        /// to; the name is what a person reading an installed agent's log
        /// recognises without a second terminal.
        var sourceName: String? = nil
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
        /// How long each step of the request took, for the `TIMING:` line. Nil
        /// for a request that was refused before any step ran.
        var stages: StageTimes? = nil

        /// Everything after the name, and the only place that wording lives.
        var summary: String {
            var parts = [consumer]
            if let display { parts.append("display \(display)") }
            if let sourceID {
                parts.append(sourceName.map { "source \(sourceID) (\($0))" } ?? "source \(sourceID)")
            }
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
            // The error logged where the failure happened records it; this
            // line carries a latency, and would never collapse into one row.
            case 500...599: Console.alert("\(status) \(detail) · \(summary)", recording: .unrecorded)
            default: Console.event("\(status) \(detail) · \(summary)")
            }

            Log.deck.notice(
                """
                served status=\(status, privacy: .public) consumer=\(consumer, privacy: .public) \
                display=\(display ?? "none", privacy: .public) \
                card=\(card ?? 0, privacy: .public) deal=\(deal ?? 0, privacy: .public) \
                bytes=\(bytes, privacy: .public) \
                source=\(sourceID ?? 0, privacy: .public) \
                name=\(detail, privacy: .public) sourceName=\(sourceName ?? "none", privacy: .public) \
                cacheBytes=\(cacheBytes ?? -1, privacy: .public) \
                queued=\(queued ?? -1, privacy: .public) ms=\(milliseconds, privacy: .public)
                """
            )
            if let timing { Log.deck.notice("\(timing, privacy: .public)") }
        }

        /// `TIMING: app · 200 · deal #83911 · waited 0ms · open 2ms · … · total 29012ms`
        ///
        /// **Every step, every request, in the unified log only.** Added
        /// 2026-09-16 when requests took 10–50 seconds during a refresh and
        /// nothing said where. `waited` is the time between the request being
        /// read and this endpoint starting on it, which is the one to watch for
        /// an agent whose threads are all busy. Filter on the prefix:
        ///
        ///     /usr/bin/log show --info --predicate 'eventMessage BEGINSWITH "TIMING:"'
        var timing: String? {
            guard let stages else { return nil }
            var parts = ["TIMING: \(consumer)", "\(status)"]
            if let deal { parts.append("deal #\(deal)") }
            if !stages.stages.isEmpty { parts.append(stages.summary) }
            parts.append("total \(Int(milliseconds))ms")
            return parts.joined(separator: " · ")
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
        if let tally { cache.lookedUp = { tally.record($0) } }
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
        source: Source? = nil,
        card: DeckCard? = nil,
        bytes: Int64 = 0,
        cacheBytes: Int64? = nil,
        queued: Int? = nil,
        timing: StageTimes? = nil
    ) {
        let consumer = request.query("consumer") ?? "anonymous"
        // Here rather than beside each `return` of a 200, so the count and the
        // console line cannot disagree: every request is reported exactly once,
        // through this.
        if status == 200 { tally?.recordServed(consumer: consumer, card: card, source: source) }
        log(
            Served(
                status: status,
                detail: detail,
                consumer: consumer,
                display: request.query("display"),
                width: request.query("w"),
                height: request.query("h"),
                card: card?.id,
                deal: card?.dealSeq,
                sourceID: card?.sourceID,
                sourceName: source?.spokenName,
                bytes: bytes,
                milliseconds: (ContinuousClock.now - request.receivedAt).totalSeconds * 1000,
                cacheBytes: cacheBytes,
                queued: queued,
                stages: timing
            )
        )
    }

    private func next(_ request: HTTPListener.Request) async -> HTTPListener.Response {
        var timing = StageTimes(from: request.receivedAt)
        timing.lap("waited")
        let context: (cache: PhotoCache, deck: Deck)
        do {
            context = try self.context()
            timing.lap("open")
        } catch {
            timing.lap("open")
            report(request, status: 503, detail: "library unavailable", timing: timing)
            Log.deck.error(kind: "serve.library-unavailable", "could not open the library: \(error)")
            return .text("library unavailable\n", status: 503, reason: "Service Unavailable")
        }

        // Consumer identity is parameters rather than registration: first sight
        // creates the row, every sight updates the heartbeat. Nothing to reap.
        let kind = ConsumerKind(request.query("consumer") ?? "cli")
        let consumerID = try? context.deck.register(
            kind: kind, displayID: request.query("display")
        ).id
        timing.lap("register")

        let box = Self.requestedSize(request)
        let accept = request.header("Accept")
        // Refused before the pop: a request that cannot be answered in any
        // format must not spend a card finding that out.
        guard let format = PhotoRenderer.Format.negotiated(accept: accept) else {
            report(request, status: 406, detail: "no acceptable format", timing: timing)
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
            // The box and format go to `serve`, so a card whose original has
            // been evicted is still served from a copy kept for that box.
            let wanted = box.map { ResizedCopies.Request(width: $0.width, height: $0.height, format: format) }
            while let served = try await context.cache.serve(
                to: consumerID, fitting: wanted, timing: &timing)
            {

                guard let box else {
                    // No size asked for: the original, untouched — opened now,
                    // for the same reason as above.
                    guard
                        let response = original(
                            served, request: request, context: context, timing: &timing)
                    else { continue }
                    return response
                }

                // **A resized copy, if the cache keeps one for this box, before
                // the resizer is asked.** Syd, 2026-09-16: "hits should be
                // service before the Resizer is asked. That's the entire point
                // of caching the resized images". A copy whose file has gone is
                // not a hit; `find` drops its row and this falls through.
                if let copy = served.copy,
                    let stream = HTTPListener.Response.StreamedFile(url: copy.url)
                {
                    timing.lap("resized copy")
                    var headers = Self.headers(for: served, contentType: format.mimeType)
                    headers["X-PGR-Pixels"] = "\(copy.pixelWidth)x\(copy.pixelHeight)"
                    try? context.deck.markDelivered(photoID: served.card.id)
                    timing.lap("delivered")
                    queueRanShort()
                    timing.lap("top up")
                    report(
                        request, status: 200, detail: served.card.spokenName, source: served.source,
                        card: served.card, bytes: stream.byteCount,
                        cacheBytes: try? await context.cache.bytesOnDisk(),
                        queued: try? context.cache.queue.size(), timing: timing)
                    return HTTPListener.Response(
                        status: 200, reason: "OK", headers: headers, body: .file(stream))
                }

                do {
                    // **Resized, and kept.** The bytes went into the cache under
                    // `(photo, resolution)` until 2026-09-06, were thrown away
                    // from then, and are kept again since 2026-09-16 — as a
                    // resized copy with a row, saved on the resizer's thread
                    // even when this request has already given up on it. Syd:
                    // "save the copy of the file that did not finish resizing in
                    // 1 second. Maybe it will be asked for again."
                    //
                    // **Its turn on the resizer, then the resize**, timed apart:
                    // a long `resize wait` is a busy queue, a long `render` a
                    // slow picture.
                    //
                    // **Bounded, and the original goes when the bound runs
                    // out.** Syd, 2026-09-16: "just serve the original image if
                    // the resizer stalls." A stalled decoder says nothing about
                    // the photograph, so it is not charged a render failure.
                    let resize = self.resize
                    let resizer = self.resizer
                    let ticket = Resizer.Ticket()
                    let place = copyPlace
                    let outcome: (result: PhotoRenderer.Rendered, started: ContinuousClock.Instant)
                    do {
                        outcome = try await Deadline.run(within: resizeBudget) {
                            try await resizer.run(ticket) {
                                let rendered = try resize(served.url, box.width, box.height, format)
                                place.keeping(
                                    rendered, photoID: served.card.id,
                                    photoUUID: served.card.uuid, boxWidth: box.width,
                                    boxHeight: box.height,
                                    named:
                                        "resized copy of \(served.card.spokenName) at \(box.width)x\(box.height)")
                                return rendered
                            }
                        }
                    } catch is Deadline.Expired {
                        ticket.abandon()
                        timing.lap("resize gave up")
                        let line = Self.resizeGaveUp(
                            name: served.card.spokenName, card: served.card.id,
                            deal: served.card.dealSeq, after: resizeBudget)
                        Console.event(line)
                        Log.deck.notice("\(line, privacy: .public)")
                        guard
                            let response = original(
                                served, request: request, context: context, timing: &timing)
                        else { continue }
                        return response
                    }
                    let rendered = outcome.result
                    timing.lap("resize wait", now: outcome.started)
                    timing.lap("render")

                    var headers = Self.headers(
                        for: served, contentType: rendered.format.mimeType)
                    headers["X-PGR-Pixels"] = "\(rendered.width)x\(rendered.height)"
                    try? context.deck.markDelivered(photoID: served.card.id)
                    timing.lap("delivered")
                    // **A deal follows a picture that reached somebody**, not a
                    // request that arrived. Rung at the top of this loop it
                    // fired once per card *taken*, so a request walking past
                    // three unrenderable photographs bought four fresh cards —
                    // against `PhotoCache`'s own statement that "a skip no
                    // longer buys a fresh card". `markDelivered` is the
                    // endpoint's existing notion of a 200 in hand, so this
                    // belongs beside it and nowhere else.
                    queueRanShort()
                    timing.lap("top up")
                    report(
                        request, status: 200, detail: served.card.spokenName, source: served.source,
                        card: served.card, bytes: Int64(rendered.bytes.count),
                        cacheBytes: try? await context.cache.bytesOnDisk(),
                        queued: try? context.cache.queue.size(), timing: timing)
                    return HTTPListener.Response(
                        status: 200, reason: "OK", headers: headers,
                        body: .data(rendered.bytes))
                } catch {
                    timing.lap("render")
                    let failures = (try? context.deck.recordRenderFailure(photoID: served.card.id)) ?? 0
                    timing.lap("render failure")
                    // Visible on the console as well as in the log, because a
                    // photograph leaving the library for good is a state change
                    // somebody watching should see happen.
                    let retired = failures >= Deck.renderFailureLimit
                    if retired {
                        Console.alert(
                            "\(served.card.spokenName) will not render; retired after \(failures) attempts",
                            recording: .kind(
                                AgentErrors.kind("serve.photo-retired", source: served.card.sourceID)))
                    } else {
                        Console.event(
                            "\(served.card.spokenName) failed to render (\(failures)); skipping it")
                    }
                    // Recorded unless it retired the photograph, which the
                    // alert above has already recorded.
                    Log.deck.error(
                        kind: retired
                            ? nil : AgentErrors.kind("serve.render-failed", source: served.card.sourceID),
                        "photo \(served.card.id) failed to render (\(failures) times): \(error)")
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
            report(request, status: 204, detail: "no photos available", timing: timing)
            return .noContent()
        } catch {
            report(request, status: 500, detail: "could not serve a picture", timing: timing)
            Log.deck.error(kind: "serve.failed", "serving failed: \(error)")
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
    /// Streams the original of `served` and reports it: the answer to a
    /// request that asked for no size, and to one whose resize stalled. Nil
    /// when the file vanished between the index and the open, so the caller
    /// moves on to the next card.
    private func original(
        _ served: PhotoCache.ServedPhoto, request: HTTPListener.Request,
        context: (cache: PhotoCache, deck: Deck), timing: inout StageTimes
    ) -> HTTPListener.Response? {
        guard let stream = HTTPListener.Response.StreamedFile(url: served.url) else {
            vanished(served, context: context)
            return nil
        }
        timing.lap("original")
        try? context.deck.markDelivered(photoID: served.card.id)
        timing.lap("delivered")
        // **A deal follows a picture that reached somebody**, not a request
        // that arrived; see the resized branch in `next`.
        queueRanShort()
        timing.lap("top up")
        report(
            request, status: 200, detail: served.card.spokenName, source: served.source,
            card: served.card, bytes: stream.byteCount, timing: timing)
        return HTTPListener.Response(
            status: 200, reason: "OK",
            headers: Self.headers(for: served, contentType: Self.contentType(of: served.url)),
            body: .file(stream))
    }

    private func vanished(_ served: PhotoCache.ServedPhoto, context: (cache: PhotoCache, deck: Deck)) {
        Console.event(
            "\(served.card.spokenName) vanished between the index and the open; skipping it")
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

    static func headers(for served: PhotoCache.ServedPhoto, contentType: String) -> [String: String] {
        let card = served.card
        return [
            "Content-Type": contentType,
            "X-PGR-Card": String(card.id),
            "X-PGR-Deal": String(card.dealSeq ?? 0),
            "X-PGR-Source": String(card.sourceID),
            "X-PGR-Storage": card.storage.rawValue,
            // What a person calls the photograph and its source, for a client
            // that wants to say so, or to name a file it saves.
            "X-PGR-Name": headerValue(headerName(for: card)),
            "X-PGR-Source-Name": headerValue(served.source.spokenName),
        ]
    }

    /// The original filename when one was recorded and the identifier
    /// otherwise — a folder photograph's path inside its folder — **with the
    /// extension removed.** What goes out is in the format `Accept` chose, not
    /// the original's, so `.png` on a HEIC answer would be a lie. The folders
    /// stay: two directories in one source can hold the same filename.
    ///
    /// Only the header strips it. The logs and the dashboard name the original
    /// file, where its extension is true.
    static func headerName(for card: DeckCard) -> String {
        ((card.originalFilename ?? card.externalID) as NSString).deletingPathExtension
    }

    /// **Percent-encoded, because a header is ASCII and a filename is not.**
    /// `日本.jpg`, `Photos › Trips`, a name with a newline in it: each would
    /// be mangled or would break the response written raw onto the socket. A
    /// space is encoded too, since a header parser trims the ends of a value and
    /// a filename may begin or end with one. `removingPercentEncoding` reads it
    /// back.
    static func headerValue(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: headerSafe) ?? ""
    }

    private static let headerSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~()[]/,'&+=!@$;")

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
