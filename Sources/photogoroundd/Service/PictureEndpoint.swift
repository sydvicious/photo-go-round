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
        var bytes: Int64
        var milliseconds: Double

        /// Everything after the name, and the only place that wording lives.
        var summary: String {
            var parts = [consumer]
            if let width, let height { parts.append("\(width)x\(height)") }
            if let deal { parts.append("deal #\(deal)") }
            if bytes > 0 { parts.append(RunCommand.bytes(bytes)) }
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
                bytes=\(bytes, privacy: .public) ms=\(milliseconds, privacy: .public)
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
        let sources = SourceStore(database: database)
        let deck = Deck(database: database)
        return (
            PhotoCache(
                database: database,
                root: cacheRoot,
                settings: preferences.cacheSettings,
                sources: sources,
                deck: deck,
                queueSize: preferences.queueSize,
                store: store
            ),
            deck
        )
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
        bytes: Int64 = 0
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
                bytes: bytes,
                milliseconds: (ContinuousClock.now - request.receivedAt).totalSeconds * 1000
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
        let format = PhotoRenderer.Format.negotiated(accept: request.header("Accept"))

        do {
            // A photograph that will not render is skipped to the next entry
            // rather than answered with an error: the client asked for a picture
            // and there are others. Only an exhausted queue is *no photos*.
            while let served = try await context.cache.serve(to: consumerID) {
                queueRanShort()

                guard let box else {
                    // No size asked for: the original, untouched.
                    let bytes =
                        (try? served.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .map(Int64.init) ?? 0
                    report(
                        request, status: 200, detail: served.card.externalID,
                        card: served.card, bytes: bytes)
                    return HTTPListener.Response(
                        status: 200, reason: "OK",
                        headers: Self.headers(
                            for: served.card, contentType: Self.contentType(of: served.url)),
                        body: .file(served.url, byteCount: bytes))
                }

                let size = PhotoStore.Size(width: box.width, height: box.height)

                // Already rendered at this size: hand over the file rather than
                // decoding again. On a small library this is the common case,
                // because a photograph comes round every few minutes.
                if let held = context.cache.rendering(of: served.card, at: size) {
                    let bytes =
                        (try? held.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .map(Int64.init) ?? 0
                    var headers = Self.headers(
                        for: served.card, contentType: Self.contentType(of: held))
                    // Read from the file rather than echoing the box that was
                    // asked for: the header describes what the client is handed,
                    // and that has to mean the same thing hit or miss.
                    if let pixels = PhotoRenderer.pixelSize(of: held) {
                        headers["X-PGR-Pixels"] = "\(pixels.width)x\(pixels.height)"
                    }
                    headers["X-PGR-Cache"] = "hit"
                    report(
                        request, status: 200, detail: served.card.externalID,
                        card: served.card, bytes: bytes)
                    return HTTPListener.Response(
                        status: 200, reason: "OK", headers: headers,
                        body: .file(held, byteCount: bytes))
                }

                do {
                    let rendered = try PhotoRenderer.render(
                        contentsOf: served.url, fitting: box.width, by: box.height, as: format)
                    // Keep it. A failure to write is not a failure to serve.
                    _ = try? context.cache.keep(
                        rendered.bytes, of: served.card, at: size,
                        pathExtension: rendered.format.rawValue)

                    var headers = Self.headers(
                        for: served.card, contentType: rendered.format.mimeType)
                    headers["X-PGR-Pixels"] = "\(rendered.width)x\(rendered.height)"
                    headers["X-PGR-Cache"] = "miss"
                    report(
                        request, status: 200, detail: served.card.externalID,
                        card: served.card, bytes: Int64(rendered.bytes.count))
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
            // Still ask for more: empty is the loudest possible signal that the
            // queue has run short.
            queueRanShort()
            report(request, status: 204, detail: "no photos available")
            return .noContent()
        } catch {
            report(request, status: 500, detail: "could not serve a picture")
            Log.deck.error("serving failed: \(String(describing: error), privacy: .public)")
            return .text("could not serve a picture\n", status: 500, reason: "Internal Server Error")
        }
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
