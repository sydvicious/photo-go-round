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
/// **`w`, `h` and `depth` are accepted and ignored**, and the answer is the
/// original bytes. They are in the URL so that a client written against this
/// endpoint needs no change when they start being obeyed.
///
/// The pop happens here, and it happens whether or not the download succeeds.
/// There is no reservation, nothing with a lifetime, and nothing to reclaim from
/// a client that goes away mid-transfer — a failed download is a lost picture,
/// and the client asks again.
struct PictureEndpoint {
    let databasePath: String
    let cacheRoot: URL
    let preferences: Preferences
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
                queueSize: preferences.queueSize
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

        do {
            guard let served = try await context.cache.serve(to: consumerID) else {
                // Ordinary, not an error. A fresh install answers this way until
                // downloads land, and every surface has an empty state already.
                // Still ask for more: empty is the loudest possible signal that
                // the queue has run short.
                queueRanShort()
                report(request, status: 204, detail: "no photos available")
                return .noContent()
            }
            queueRanShort()
            let url = served.url
            let byteCount =
                (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            report(
                request, status: 200, detail: served.card.externalID,
                card: served.card, bytes: byteCount)

            return HTTPListener.Response(
                status: 200,
                reason: "OK",
                headers: [
                    "Content-Type": Self.contentType(of: url),
                    "X-PGR-Card": String(served.card.id),
                    "X-PGR-Deal": String(served.card.dealSeq ?? 0),
                    "X-PGR-Source": String(served.card.sourceID),
                    "X-PGR-Storage": served.card.storage.rawValue,
                ],
                body: .file(url, byteCount: byteCount)
            )
        } catch {
            report(request, status: 500, detail: "could not serve a picture")
            Log.deck.error("serving failed: \(String(describing: error), privacy: .public)")
            return .text("could not serve a picture\n", status: 500, reason: "Internal Server Error")
        }
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
