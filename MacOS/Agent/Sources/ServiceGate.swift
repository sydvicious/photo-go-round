import Console
import CryptoKit
import Foundation
import PhotosGoRoundAgentAPI

/// Who gets past the listener: a request carrying this user's secret, a
/// browser holding the dashboard's cookie, and nobody else.
///
/// ```
/// listener → ServiceGate.handle(request) → Router.route(request)
/// ```
///
/// **In front of the router, not inside it.** `Router` exists so a test can
/// hold the dispatch, and a secret it had to be given would be either a
/// parameter every such test invents or a default that turns checking off — a
/// default that disables security is one edit from shipping. Here the endpoints
/// never learn that credentials exist, and this type owns every one of them.
///
/// **Not inside `HTTPListener` either.** The listener is transport; the tests
/// that speak raw HTTP to it would all need the header for reasons that have
/// nothing to do with them.
///
/// It decides, in this order:
///
/// 1. **A `Bearer` header.** Right: on it goes, and `POST /v1/dashboard/code`
///    is answered here. Wrong: refused.
/// 2. **`GET /dashboard?code=…` with a live code.** Spent, and answered with
///    the cookie and a redirect to the page without it.
/// 3. **The cookie, on a `GET` the dashboard claims.** Right: on it goes.
///    Wrong: refused.
/// 4. **Nothing.** Refused.
///
/// `Plans/Multi-user Support.md`, *The gate* and *The dashboard*.
struct ServiceGate: Sendable {
    /// This user's secret, from `Preferences.establishServiceSecret()`.
    let secret: String

    /// The dashboard's one-time codes, alive for this process only.
    let codes: DashboardCodes

    /// Told about each refusal. The console line in the agent; a test hands in
    /// its own to count them.
    let refused: @Sendable (Refusal) -> Void

    /// The dashboard cookie's name and value, both derived from the secret.
    let cookieName: String
    let cookieValue: String

    init(
        secret: String,
        codes: DashboardCodes = DashboardCodes(),
        refused: @escaping @Sendable (Refusal) -> Void = ServiceGate.report
    ) {
        self.secret = secret
        self.codes = codes
        self.refused = refused
        self.cookieName = Self.cookieName(for: secret)
        self.cookieValue = Self.cookieValue(for: secret)
    }

    /// One request turned away, and why. Never the value offered.
    struct Refusal: Equatable, Sendable {
        enum Reason: String, Sendable {
            /// No credential at all.
            case absent
            /// One that is not this user's: a wrong secret, a wrong cookie, or
            /// a code that is spent, expired or was never made.
            case wrong
        }
        var method: String
        var path: String
        var reason: Reason
    }

    /// Where the app asks for a code, carrying the secret. Inside the
    /// dashboard's prefix, and answered here before the dashboard is asked.
    static let codePath = DashboardEndpoint.path + "/code"

    func handle(
        _ request: HTTPListener.Request,
        next: (HTTPListener.Request) async -> HTTPListener.Response
    ) async -> HTTPListener.Response {
        // 1. The secret, which is what every client but a browser sends.
        if let offered = ServiceSecret.offered(
            inAuthorization: request.header(ServiceSecret.headerField))
        {
            guard ServiceSecret.matches(offered, secret) else { return refuse(request, .wrong) }
            if request.method == "POST", request.path == Self.codePath { return await mint() }
            return await next(request)
        }

        // 2. A code, spent for the cookie. **A dead one falls through** to the
        // cookie, so a stale link in a tab that already has one still opens.
        let offersCode = request.method == "GET" && request.path == DashboardEndpoint.pagePath
            && request.query("code") != nil
        if offersCode, let code = request.query("code"), await codes.spend(code) {
            return welcome()
        }

        // 3. The cookie — for the dashboard's `GET`s and nothing more. Every
        // port on `localhost` is the same site, so `SameSite=Strict` does not
        // stop a page on another user's port from making this browser send it;
        // confined to reading the dashboard, it buys that page nothing.
        if let cookie = Self.cookie(named: cookieName, in: request.header("Cookie")),
            request.method == "GET", DashboardEndpoint.claims(request.path)
        {
            guard ServiceSecret.matches(cookie, cookieValue) else { return refuse(request, .wrong) }
            return await next(request)
        }

        return refuse(request, offersCode ? .wrong : .absent)
    }

    // MARK: - The dashboard's code and cookie

    /// A new code, as `{"code": "…"}`.
    private func mint() async -> HTTPListener.Response {
        guard let code = await codes.mint() else {
            Console.alert(
                "no code could be made for the dashboard", recording: .kind("dashboard.code-failed"))
            return .text("no code could be made\n", status: 500, reason: "Internal Server Error")
        }
        return HTTPListener.Response(
            status: 200, reason: "OK",
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store",
            ],
            body: .data(Data(#"{"code":"\#(code)"}"#.utf8)))
    }

    /// The cookie, and the page without the code in its address.
    private func welcome() -> HTTPListener.Response {
        HTTPListener.Response(
            status: 303, reason: "See Other",
            headers: [
                "Location": DashboardEndpoint.pagePath,
                "Set-Cookie": setCookie,
                "Cache-Control": "no-store",
            ])
    }

    /// **As long as the secret lasts, as near as a browser allows.** Syd,
    /// 2026-09-23: a bookmarked dashboard keeps working across browser
    /// restarts. 400 days is the most Chrome keeps any cookie, and it cuts a
    /// longer one to that silently. Rotating the secret ends it.
    var setCookie: String {
        "\(cookieName)=\(cookieValue); Path=/; Max-Age=\(Self.cookieLifetimeSeconds); HttpOnly; SameSite=Strict"
    }

    static let cookieLifetimeSeconds = 400 * 24 * 60 * 60

    /// **Derived from the secret, not made per launch.** The app restarts the
    /// agent on every launch of its own, and a per-launch value would blank
    /// every open dashboard each time. Not the secret itself either: the
    /// browser keeps what it is given in its own files.
    static func cookieValue(for secret: String) -> String {
        hmac(secret, "dashboard cookie")
    }

    /// **Distinct per secret**, because cookies are kept by host and path and
    /// ignore the port: Syd's Release, Debug and Claude agents — and another
    /// user's, in a shared browser — would otherwise overwrite each other's.
    static func cookieName(for secret: String) -> String {
        "pgr-" + hmac(secret, "dashboard cookie name").prefix(12)
    }

    private static func hmac(_ secret: String, _ purpose: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(purpose.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// The value of the first cookie called `name` in a `Cookie` header.
    static func cookie(named name: String, in header: String?) -> String? {
        guard let header else { return nil }
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                parts[0].trimmingCharacters(in: .whitespaces) == name
            else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Refusing

    private func refuse(
        _ request: HTTPListener.Request, _ reason: Refusal.Reason
    ) -> HTTPListener.Response {
        refused(Refusal(method: request.method, path: request.path, reason: reason))
        return Self.refusal
    }

    /// What every refusal says, from every agent alike.
    ///
    /// **One line, and the same one everywhere.** Syd, 2026-09-23, over an
    /// empty body that a browser shows as a blank page: it helps whoever hits
    /// it, and an agent that is not yours still says nothing about whose it is.
    /// `WWW-Authenticate` because HTTP asks it of every `401`.
    static let refusal = HTTPListener.Response(
        status: 401, reason: "Unauthorized",
        headers: [
            "WWW-Authenticate": "Bearer",
            "Content-Type": "text/plain; charset=utf-8",
        ],
        body: .data(Data(refusalText.utf8)))

    static let refusalText = "Open the dashboard from Photos-Go-Round's About box.\n"

    /// A request line like any other the agent prints, mirrored to the unified
    /// log with them. The path is the request's without its query, so nothing
    /// a client put in a URL — a code included — is repeated here.
    static func report(_ refusal: Refusal) {
        Console.event("401 \(refusal.method) \(refusal.path) · \(refusal.reason.rawValue)")
    }
}

/// The dashboard's one-time codes: good once, and for a minute.
///
/// **In memory, for this process only.** An agent restart forgets them, which
/// costs nothing — the next click in the About box asks for another. A code is
/// in one URL, and so in the browser's history; by the time anyone reads that,
/// it is spent and expired, which is the point of it.
actor DashboardCodes {
    static let lifetime = Duration.seconds(60)
    /// Sixteen random bytes: a code only has to survive a minute.
    static let byteCount = 16

    private var live: [String: ContinuousClock.Instant] = [:]
    private let now: @Sendable () -> ContinuousClock.Instant

    /// `now` is a hook so a test can let a minute pass without waiting one.
    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    /// A new code, or nil when no random bytes could be had.
    func mint() -> String? {
        forgetExpired()
        guard let code = ServiceSecret.random(bytes: Self.byteCount) else { return nil }
        live[code] = now() + Self.lifetime
        return code
    }

    /// Whether `code` was live, and it is not any more either way.
    func spend(_ code: String) -> Bool {
        forgetExpired()
        return live.removeValue(forKey: code) != nil
    }

    private func forgetExpired() {
        let instant = now()
        live = live.filter { $0.value > instant }
    }
}

/// The agent will not serve without a secret to check.
struct NoServiceSecret: Error, CustomStringConvertible {
    var description: String {
        "no secret could be made for the service, and the agent does not serve without one"
    }
}
