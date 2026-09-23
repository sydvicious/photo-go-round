import Foundation

/// Which endpoint answers.
///
/// A type rather than a closure in `RunCommand` so that the dispatch is
/// something a test can hold: "a `POST` to `/v1/sources` does not reach the
/// picture endpoint" is a claim about this and about nothing else.
///
/// **Anything unclaimed goes to the pictures.** That endpoint already owns "no
/// such endpoint" and "only GET is served", and it already reports both through
/// the request log a person is watching — so the fallback keeps one account of
/// what arrived rather than two that have to be read together.
struct Router {
    let pictures: PictureEndpoint
    let sources: SourceEndpoint
    let photos: PhotosEndpoint
    let dashboard: DashboardEndpoint

    func route(_ request: HTTPListener.Request) async -> HTTPListener.Response {
        if let answer = Self.alive(request) { return answer }
        // **Before the pictures, so the page's once-a-second poll is never a
        // line in the request log.** Unclaimed, it would be answered by the
        // picture endpoint's 404 and reported sixty times a minute.
        if DashboardEndpoint.claims(request.path) {
            return await dashboard.route(request)
        }
        if SourceEndpoint.claims(request.path) {
            return await sources.route(request)
        }
        // **Claims the whole `/v2/photos` prefix**, not just the one route it
        // serves, so a mistyped path under it is answered by the endpoint that
        // knows what belongs there rather than by the pictures.
        if PhotosEndpoint.claims(request.path) {
            return await photos.route(request)
        }
        return await pictures.route(request)
    }

    /// `GET /v1/alive`: this user's agent is up and listening, and nothing else.
    static let alivePath = "/v1/alive"

    /// `204` at once, for the app's launch check, touching no database, cache
    /// or library.
    ///
    /// **Why it exists.** The check asked `/v1/dashboard` until 2026-09-23,
    /// the heaviest read the agent serves: in `randyarbuckle`'s account, just
    /// after a restart, with the agent walking its cache and refreshing a large
    /// library on a loaded Mac, that request missed its five seconds for 72
    /// seconds straight, and the wallpaper and the screensaver were not
    /// installed — while the next launch's agent answered in 1.5 s. The
    /// question the check asks is whether the agent is up, and this answers
    /// only that. Syd: "add /v1/alive and point the probe at it".
    ///
    /// **Behind the gate like everything else**, so it still carries the
    /// secret and another account's agent still answers `401`. Quiet: no
    /// request line, for the same reason as the dashboard's poll.
    static func alive(_ request: HTTPListener.Request) -> HTTPListener.Response? {
        guard request.path == alivePath else { return nil }
        guard request.method == "GET" else {
            return .text("only GET is served\n", status: 405, reason: "Method Not Allowed")
        }
        return .noContent()
    }
}
