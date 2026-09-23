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
            deployment: .development,
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
