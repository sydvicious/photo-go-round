import Console
import Foundation
import PhotosGoRoundAgentAPI

/// Who gets past the listener: a request carrying this user's secret, and
/// nobody else.
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
/// `Plans/Multi-user Support.md`, *The gate*.
struct ServiceGate: Sendable {
    /// This user's secret, from `Preferences.establishServiceSecret()`.
    let secret: String

    /// Told about each refusal. The console line in the agent; a test hands in
    /// its own to count them.
    var refused: @Sendable (Refusal) -> Void = ServiceGate.report

    /// One request turned away, and why. Never the value offered.
    struct Refusal: Equatable, Sendable {
        enum Reason: String, Sendable {
            /// No `Bearer` credential at all.
            case absent
            /// One that is not this user's secret.
            case wrong
        }
        var method: String
        var path: String
        var reason: Reason
    }

    func handle(
        _ request: HTTPListener.Request,
        next: (HTTPListener.Request) async -> HTTPListener.Response
    ) async -> HTTPListener.Response {
        guard
            let offered = ServiceSecret.offered(
                inAuthorization: request.header(ServiceSecret.headerField))
        else {
            return refuse(request, .absent)
        }
        guard ServiceSecret.matches(offered, secret) else {
            return refuse(request, .wrong)
        }
        return await next(request)
    }

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
    /// a client put in a URL is repeated here.
    static func report(_ refusal: Refusal) {
        Console.event("401 \(refusal.method) \(refusal.path) · secret \(refusal.reason.rawValue)")
    }
}

/// The agent will not serve without a secret to check.
struct NoServiceSecret: Error, CustomStringConvertible {
    var description: String {
        "no secret could be made for the service, and the agent does not serve without one"
    }
}
