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
/// **Step 1 accepts `w`, `h` and `depth` and ignores all three**, answering with
/// the original bytes. The parameters are in the URL from the outset so the
/// shape is settled before the renderer makes them real, and so a client written
/// against this endpoint today needs no change when it starts being obeyed.
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
        case "/v1/next":
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
    /// Without it the only visible evidence a client had been served was the
    /// queue getting shorter, which is the wrong end of the telescope.
    private func report(
        _ request: HTTPListener.Request,
        status: Int,
        detail: String,
        card: DeckCard? = nil,
        bytes: Int64 = 0
    ) {
        let elapsed = (ContinuousClock.now - request.receivedAt).totalSeconds * 1000
        let who = request.query("consumer") ?? "anonymous"
        let size = [request.query("w"), request.query("h")].compactMap(\.self).joined(separator: "x")
        var parts = [who]
        if !size.isEmpty { parts.append(size) }
        if let card { parts.append("deal #\(card.dealSeq ?? 0)") }
        if bytes > 0 { parts.append(RunCommand.bytes(bytes)) }
        parts.append(elapsed.formatted(.number.precision(.fractionLength(1))) + "ms")
        let suffix = parts.joined(separator: " · ")

        switch status {
        case 200:
            Console.change("▸", detail, .yellow, suffix: suffix)
        case 500...599:
            Console.alert("\(status) \(detail) · \(suffix)")
        default:
            Console.event("\(status) \(detail) · \(suffix)")
        }

        Log.deck.notice(
            """
            served status=\(status, privacy: .public) consumer=\(who, privacy: .public) \
            card=\(card?.id ?? 0, privacy: .public) deal=\(card?.dealSeq ?? 0, privacy: .public) \
            bytes=\(bytes, privacy: .public) ms=\(elapsed, privacy: .public)
            """
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
