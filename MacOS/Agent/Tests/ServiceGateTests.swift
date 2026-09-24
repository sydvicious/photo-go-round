import Foundation
import Synchronization
import Testing

@testable import PhotosGoRoundAgentAPI
@testable import PhotosGoRoundServer

/// Only a request carrying this user's secret gets past the listener.
/// `Plans/Multi-user Support.md`, *The gate*.
@Suite("The service gate", .timeLimit(.minutes(1)))
struct ServiceGateTests {

    static let secret = String(repeating: "0123456789abcdef", count: 4)

    /// Refusals the gate reported, and requests it let through.
    final class Record: Sendable {
        private let state = Mutex<(refusals: [ServiceGate.Refusal], admitted: [String])>(([], []))

        var refusals: [ServiceGate.Refusal] { state.withLock { $0.refusals } }
        var admitted: [String] { state.withLock { $0.admitted } }

        func refused(_ refusal: ServiceGate.Refusal) { state.withLock { $0.refusals.append(refusal) } }
        func admit(_ path: String) { state.withLock { $0.admitted.append(path) } }
    }

    private static func gate(_ record: Record) -> ServiceGate {
        ServiceGate(secret: secret, refused: { record.refused($0) })
    }

    private static func request(_ head: String) throws -> HTTPListener.Request {
        try #require(HTTPListener.parse(head))
    }

    private static func pass(
        _ head: String, through gate: ServiceGate, record: Record
    ) async throws -> HTTPListener.Response {
        let request = try request(head)
        return await gate.handle(request) { admitted in
            record.admit(admitted.path)
            return .text("through\n")
        }
    }

    private static func body(_ response: HTTPListener.Response) -> String? {
        guard case .data(let data) = response.body else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Refused

    @Test("No secret is a 401, the one line every agent says, and never reaches the router")
    func absentIsRefused() async throws {
        let record = Record()
        let response = try await Self.pass(
            "GET /v1/next?consumer=cli HTTP/1.1\r\nHost: localhost", through: Self.gate(record),
            record: record)

        #expect(response.status == 401)
        #expect(response.headers["WWW-Authenticate"] == "Bearer")
        #expect(Self.body(response) == "Open the dashboard from Photos-Go-Round's About box.\n")
        #expect(record.admitted.isEmpty)
        #expect(record.refusals == [.init(method: "GET", path: "/v1/next", reason: .absent)])
    }

    @Test("Another scheme offers no secret")
    func anotherSchemeIsAbsent() async throws {
        let record = Record()
        let response = try await Self.pass(
            "GET /v1/next HTTP/1.1\r\nAuthorization: Basic \(Self.secret)",
            through: Self.gate(record), record: record)

        #expect(response.status == 401)
        #expect(record.refusals.map(\.reason) == [.absent])
    }

    @Test("A wrong secret is a 401, logged as wrong")
    func wrongIsRefused() async throws {
        let record = Record()
        let wrong = String(repeating: "f", count: 64)
        let response = try await Self.pass(
            "POST /v2/sources HTTP/1.1\r\nAuthorization: Bearer \(wrong)",
            through: Self.gate(record), record: record)

        #expect(response.status == 401)
        #expect(record.admitted.isEmpty)
        #expect(record.refusals == [.init(method: "POST", path: "/v2/sources", reason: .wrong)])
    }

    @Test("The right secret at a different length is refused")
    func rightButDifferentLengthIsRefused() async throws {
        for offered in [String(Self.secret.dropLast()), Self.secret + "0"] {
            let record = Record()
            let response = try await Self.pass(
                "GET /v1/next HTTP/1.1\r\nAuthorization: Bearer \(offered)",
                through: Self.gate(record), record: record)
            #expect(response.status == 401, "\(offered.count) digits")
            #expect(record.refusals.map(\.reason) == [.wrong])
        }
    }

    @Test("What a refusal reports is the path without its query")
    func refusalsDoNotRepeatTheQuery() async throws {
        let record = Record()
        _ = try await Self.pass(
            "GET /dashboard?code=abcdef HTTP/1.1", through: Self.gate(record), record: record)
        #expect(record.refusals.map(\.path) == ["/dashboard"])
    }

    // MARK: - Admitted

    @Test("The right secret goes through, and the router's answer comes back untouched")
    func rightIsAdmitted() async throws {
        let record = Record()
        let response = try await Self.pass(
            "GET /v1/next HTTP/1.1\r\nauthorization: bearer \(Self.secret)",
            through: Self.gate(record), record: record)

        #expect(response.status == 200)
        #expect(Self.body(response) == "through\n")
        #expect(record.admitted == ["/v1/next"])
        #expect(record.refusals.isEmpty)
    }

    // MARK: - The dashboard's code

    /// A code, minted the way the app asks for one.
    private static func mint(_ gate: ServiceGate, record: Record) async throws -> String {
        let response = try await pass(
            "POST /v1/dashboard/code HTTP/1.1\r\nAuthorization: Bearer \(secret)",
            through: gate, record: record)
        #expect(response.status == 200)
        #expect(response.headers["Cache-Control"] == "no-store")
        let json = try #require(body(response))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        return try #require(object["code"])
    }

    @Test("A code is minted only for the secret, and never reaches the router")
    func mintingNeedsTheSecret() async throws {
        let record = Record()
        let gate = Self.gate(record)

        let bare = try await Self.pass("POST /v1/dashboard/code HTTP/1.1", through: gate, record: record)
        #expect(bare.status == 401)

        let code = try await Self.mint(gate, record: record)
        #expect(code.count == 32)
        #expect(record.admitted.isEmpty)
    }

    @Test("A code is spent for the cookie and a redirect to the page without it")
    func codeBuysTheCookie() async throws {
        let record = Record()
        let gate = Self.gate(record)
        let code = try await Self.mint(gate, record: record)

        let response = try await Self.pass(
            "GET /dashboard?code=\(code) HTTP/1.1", through: gate, record: record)

        #expect(response.status == 303)
        #expect(response.headers["Location"] == "/dashboard")
        let cookie = try #require(response.headers["Set-Cookie"])
        #expect(cookie.hasPrefix("\(gate.cookieName)=\(gate.cookieValue);"))
        #expect(cookie.contains("HttpOnly"))
        #expect(cookie.contains("SameSite=Strict"))
        #expect(cookie.contains("Path=/"))
        #expect(cookie.contains("Max-Age=34560000"))
        // Neither the secret nor the code goes back to the browser.
        #expect(!cookie.contains(Self.secret))
        #expect(!cookie.contains(code))
        #expect(record.admitted.isEmpty)
    }

    @Test("A code is good once")
    func codeIsGoodOnce() async throws {
        let record = Record()
        let gate = Self.gate(record)
        let code = try await Self.mint(gate, record: record)

        _ = try await Self.pass("GET /dashboard?code=\(code) HTTP/1.1", through: gate, record: record)
        let again = try await Self.pass(
            "GET /dashboard?code=\(code) HTTP/1.1", through: gate, record: record)

        #expect(again.status == 401)
        #expect(record.refusals.map(\.reason) == [.wrong])
    }

    @Test("A code made up is refused as wrong")
    func madeUpCodeIsWrong() async throws {
        let record = Record()
        let response = try await Self.pass(
            "GET /dashboard?code=\(String(repeating: "a", count: 32)) HTTP/1.1",
            through: Self.gate(record), record: record)
        #expect(response.status == 401)
        #expect(record.refusals.map(\.reason) == [.wrong])
    }

    @Test("A code is not good after a minute")
    func codeExpires() async throws {
        let clock = Mutex(ContinuousClock.now)
        let codes = DashboardCodes(now: { clock.withLock { $0 } })
        let first = try #require(await codes.mint())
        let second = try #require(await codes.mint())

        clock.withLock { $0 += .seconds(59) }
        #expect(await codes.spend(first))

        clock.withLock { $0 += .seconds(2) }
        #expect(!(await codes.spend(second)))
    }

    // MARK: - The dashboard's cookie

    private static func withCookie(_ gate: ServiceGate, _ method: String, _ path: String) -> String {
        "\(method) \(path) HTTP/1.1\r\nCookie: other=1; \(gate.cookieName)=\(gate.cookieValue)"
    }

    @Test("The cookie admits every GET the dashboard claims")
    func cookieAdmitsTheDashboard() async throws {
        for path in [
            "/dashboard", "/dashboard/dashboard.js", "/dashboard/dashboard.css", "/v1/dashboard",
            "/v1/dashboard/thumbnail",
        ] {
            let record = Record()
            let gate = Self.gate(record)
            let response = try await Self.pass(
                Self.withCookie(gate, "GET", path), through: gate, record: record)
            #expect(response.status == 200, "\(path)")
            #expect(record.admitted == [path])
        }
    }

    /// A page on another localhost port can make the browser send the cookie;
    /// it must not buy that page anything but reading the dashboard.
    @Test("The cookie admits nothing else")
    func cookieAdmitsNothingElse() async throws {
        for (method, path) in [
            ("GET", "/v1/next"), ("POST", "/v2/sources"), ("GET", "/v2/sources"),
            ("POST", "/v1/dashboard/code"), ("POST", "/v1/dashboard"),
        ] {
            let record = Record()
            let gate = Self.gate(record)
            let response = try await Self.pass(
                Self.withCookie(gate, method, path), through: gate, record: record)
            #expect(response.status == 401, "\(method) \(path)")
            #expect(record.admitted.isEmpty)
        }
    }

    @Test("Our cookie's name with a value not ours is refused as wrong")
    func forgedCookieIsWrong() async throws {
        let record = Record()
        let gate = Self.gate(record)
        let response = try await Self.pass(
            "GET /v1/dashboard HTTP/1.1\r\nCookie: \(gate.cookieName)=\(String(repeating: "0", count: 64))",
            through: gate, record: record)
        #expect(response.status == 401)
        #expect(record.refusals.map(\.reason) == [.wrong])
    }

    /// Cookies ignore ports, so another agent's cookie arrives here too. With
    /// a name of its own it is not even looked at.
    @Test("Another agent's cookie is not ours, and is refused")
    func anotherAgentsCookieIsRefused() async throws {
        let record = Record()
        let gate = Self.gate(record)
        let other = ServiceGate(secret: String(repeating: "fedcba9876543210", count: 4))
        #expect(other.cookieName != gate.cookieName)
        #expect(other.cookieValue != gate.cookieValue)

        let response = try await Self.pass(
            Self.withCookie(other, "GET", "/v1/dashboard"), through: gate, record: record)
        #expect(response.status == 401)
        #expect(record.admitted.isEmpty)
    }

    @Test("The cookie is the same for the same secret, and carries none of it")
    func cookieIsDerived() {
        let first = ServiceGate(secret: Self.secret)
        let second = ServiceGate(secret: Self.secret)
        #expect(first.cookieName == second.cookieName)
        #expect(first.cookieValue == second.cookieValue)
        #expect(first.cookieName.hasPrefix("pgr-"))
        #expect(first.cookieName.count == 16)
        #expect(!first.cookieValue.contains(Self.secret))
    }

    @Test("A dead code in a tab that has the cookie still opens the page")
    func deadCodeWithCookieOpens() async throws {
        let record = Record()
        let gate = Self.gate(record)
        let response = try await Self.pass(
            Self.withCookie(gate, "GET", "/dashboard?code=spent"), through: gate, record: record)
        #expect(response.status == 200)
        #expect(record.admitted == ["/dashboard"])
    }

    // MARK: - Over a socket

    @Test("Over a real socket: refused without the header, served with it")
    func overASocket() async throws {
        let record = Record()
        let gate = Self.gate(record)
        let bound = RequestBodyTests.BoundPort()
        let listener = HTTPListener(
            port: nil, advertising: "", onReady: { bound.set($0) }
        ) { request in
            await gate.handle(request) { _ in .text("through\n") }
        }
        try listener.start()
        defer { listener.stop() }
        let port = await bound.value

        let url = try #require(URL(string: "http://localhost:\(port)/v1/next"))
        let session = URLSession(configuration: .ephemeral)

        let (_, bare) = try await session.data(for: URLRequest(url: url))
        #expect((bare as? HTTPURLResponse)?.statusCode == 401)

        var carrying = URLRequest(url: url)
        carrying.setValue(
            ServiceSecret.authorization(Self.secret), forHTTPHeaderField: ServiceSecret.headerField)
        let (data, served) = try await session.data(for: carrying)
        #expect((served as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "through\n")
    }

    // MARK: - No secret, no agent

    @Test("The agent does not start when no secret can be made")
    func noSecretNoAgent() async throws {
        let name = scratchSuiteName("gate")
        defer { discardScratchSuite(name) }
        let directory = URL.temporaryDirectory.appending(path: "pgr-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let environment = MacHostEnvironment(
            containerOverride: directory.appending(path: "container"),
            cacheOverride: directory.appending(path: "cache"),
            environment: ["PGR_PREFS_SUITE": name]
        )
        var command = RunCommand(
            environment: environment, foldersToAdd: [], tick: .milliseconds(10), once: true,
            scanIntervalOverride: nil, servicePort: nil)
        command.makeSecret = { nil }

        await #expect(throws: NoServiceSecret.self) { try await command.run() }
        #expect(environment.preferences.serviceSecret == nil)
    }
}
