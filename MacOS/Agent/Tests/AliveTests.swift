import Foundation
import Testing

@testable import PhotosGoRoundAgentAPI
@testable import PhotosGoRoundServer

/// `GET /v1/alive`: the launch check's question, answered without touching
/// the database. See `Router.alive`.
@Suite("Whether the agent is up")
struct AliveTests {

    private static func request(_ head: String) throws -> HTTPListener.Request {
        try #require(HTTPListener.parse(head))
    }

    @Test("A GET is answered 204, with nothing in it")
    func getIsNoContent() throws {
        let answer = try #require(Router.alive(try Self.request("GET /v1/alive HTTP/1.1")))
        #expect(answer.status == 204)
        guard case .empty = answer.body else {
            Issue.record("expected no body, got \(answer.body)")
            return
        }
    }

    @Test("Only GET is served")
    func onlyGet() throws {
        let answer = try #require(Router.alive(try Self.request("POST /v1/alive HTTP/1.1")))
        #expect(answer.status == 405)
    }

    @Test("Any other path is not its business")
    func otherPathsPass() throws {
        for path in ["/v1/next", "/v1/alive/more", "/v1/dashboard", "/alive"] {
            #expect(Router.alive(try Self.request("GET \(path) HTTP/1.1")) == nil, "\(path)")
        }
    }

    /// Answering it without the secret would tell another account that an
    /// agent is here and up — and the check depends on a `401` meaning
    /// someone else's.
    @Test("It still needs the secret")
    func behindTheGate() async throws {
        let secret = String(repeating: "0123456789abcdef", count: 4)
        let gate = ServiceGate(secret: secret, refused: { _ in })
        let route: (HTTPListener.Request) async -> HTTPListener.Response = {
            Router.alive($0) ?? .text("not alive\n", status: 404, reason: "Not Found")
        }

        let bare = await gate.handle(try Self.request("GET /v1/alive HTTP/1.1"), next: route)
        #expect(bare.status == 401)

        let carrying = await gate.handle(
            try Self.request("GET /v1/alive HTTP/1.1\r\nAuthorization: Bearer \(secret)"), next: route)
        #expect(carrying.status == 204)
    }
}
