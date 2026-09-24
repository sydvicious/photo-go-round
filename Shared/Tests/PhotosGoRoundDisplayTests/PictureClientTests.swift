import Foundation
import Synchronization
import Testing

@testable import PhotosGoRoundDisplay
@testable import PhotosGoRoundAgentAPI

@Suite("Asking the service for a picture")
struct PictureClientTests {

    // MARK: - A service that is not there

    @Test("With no port published, the agent is not running")
    func noPort() async {
        let suite = DefaultsSuite()
        let client = PictureClient(preferences: suite.preferences, session: Stub.session())
        await #expect(throws: PictureClient.Failure.noPortPublished) {
            try await client.next(consumer: "app", displayID: nil, fitting: nil)
        }
    }

    /// A crash leaves the published value behind, so this is the ordinary shape
    /// of *the agent died* rather than an exotic case.
    @Test("A published port with nothing listening is unreachable, not empty")
    func stalePort() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9999)
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { _ in .failure(URLError(.cannotConnectToHost)) })

        do {
            _ = try await client.next(consumer: "app", displayID: nil, fitting: nil)
            Issue.record("expected a failure")
        } catch let failure as PictureClient.Failure {
            guard case .unreachable(let port, _) = failure else {
                Issue.record("expected unreachable, got \(failure)")
                return
            }
            #expect(port == 9999)
        }
    }

    /// **The fault this whole bound exists for.** An agent whose cooperative
    /// threads are parked inside a wedged photo library accepts the connection
    /// and then says nothing — and before there was a deadline, the picture loop
    /// waited on it for as long as it stayed stuck.
    @Test("An agent that accepts the connection and says nothing is silent, not unreachable")
    func silentAgent() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9000)
        let client = PictureClient(
            preferences: suite.preferences,
            limit: .milliseconds(50),
            session: Stub.silentSession())

        do {
            _ = try await client.next(consumer: "app", displayID: nil, fitting: nil)
            Issue.record("expected a failure")
        } catch let failure as PictureClient.Failure {
            // **Not `unreachable`.** That would send somebody to start an agent
            // whose process is right there in Activity Monitor.
            guard case .silent(let port, let limit) = failure else {
                Issue.record("expected silent, got \(failure)")
                return
            }
            #expect(port == 9000)
            #expect(limit == .milliseconds(50))
        }
    }

    /// **A patient request waits for the first-picture bound instead.** Before
    /// the agent has answered a surface there is no picture to protect, and
    /// giving up at five seconds only means asking again. See
    /// `ServiceTiming.firstPictureReadLimit`.
    @Test("A patient request is bounded by the first-picture limit")
    func patientRequestUsesTheFirstLimit() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9000)
        let client = PictureClient(
            preferences: suite.preferences,
            limit: .milliseconds(50), firstLimit: .milliseconds(120),
            session: Stub.silentSession())

        for (patient, expected) in [(true, Duration.milliseconds(120)), (false, .milliseconds(50))] {
            do {
                _ = try await client.next(
                    consumer: "screensaver", displayID: nil, fitting: nil, patient: patient)
                Issue.record("expected a failure")
            } catch let failure as PictureClient.Failure {
                guard case .silent(_, let limit) = failure else {
                    Issue.record("expected silent, got \(failure)")
                    continue
                }
                #expect(limit == expected, "patient: \(patient)")
            }
        }
    }

    /// The loop asks again every few seconds, so a bound that leaked the
    /// abandoned request would pile up one stuck task per turn of the wheel for
    /// as long as the agent stayed wedged.
    @Test("A silent agent costs one wait each time, not a growing one")
    func silenceDoesNotAccumulate() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9000)
        let client = PictureClient(
            preferences: suite.preferences,
            limit: .milliseconds(50),
            session: Stub.silentSession())

        let clock = ContinuousClock()
        let started = clock.now
        for _ in 0..<3 {
            _ = try? await client.next(consumer: "app", displayID: nil, fitting: nil)
        }
        #expect(clock.now - started < .seconds(2))
    }

    // MARK: - The answers that are not errors

    @Test("204 is an empty queue, which is an ordinary answer")
    func emptyQueue() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9000)
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { _ in .success((204, [:], Data())) })

        let picture = try await client.next(consumer: "app", displayID: nil, fitting: nil)
        #expect(picture == nil)
    }

    @Test("A picture arrives with its bytes and everything the service said about it")
    func served() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9000)
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { _ in
                .success((
                    200,
                    [
                        "Content-Type": "image/heic",
                        "X-PGR-Card": "7806",
                        "X-PGR-Deal": "5",
                        "X-PGR-Pixels": "100x67",
                    ],
                    Data([0xDE, 0xAD, 0xBE, 0xEF])
                ))
            })

        let picture = try #require(
            try await client.next(consumer: "app", displayID: nil, fitting: nil))
        #expect(picture.data.count == 4)
        #expect(picture.card == 7806)
        #expect(picture.deal == 5)
        #expect(picture.pixels == PixelSize(width: 100, height: 67))
    }

    @Test("Anything else the service says is a refusal")
    func refused() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9000)
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { _ in .success((503, [:], Data())) })

        await #expect(throws: PictureClient.Failure.refused(status: 503)) {
            try await client.next(consumer: "app", displayID: nil, fitting: nil)
        }
    }

    // MARK: - What goes on the wire

    @Test("The box and the consumer's identity are the query")
    func requestQuery() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9000)
        let seen = Mutex<URLRequest?>(nil)
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { request in
                seen.withLock { $0 = request }
                return .success((204, [:], Data()))
            })

        _ = try await client.next(
            consumer: "app", displayID: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
            fitting: PixelSize(width: 3840, height: 2160))

        let url = try #require(seen.withLock { $0 }?.url)
        #expect(url.port == 9000)
        #expect(url.path() == "/v1/next")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        #expect(values["consumer"] == "app")
        #expect(values["display"] == "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        #expect(values["w"] == "3840")
        #expect(values["h"] == "2160")
    }

    /// Naming neither bound is how a client asks for the original bytes
    /// untouched, so half a box must never be sent.
    @Test("Asking for no size sends no size")
    func originalRequest() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9000)
        let seen = Mutex<URLRequest?>(nil)
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { request in
                seen.withLock { $0 = request }
                return .success((204, [:], Data()))
            })

        _ = try await client.next(consumer: "cli", displayID: nil, fitting: nil)

        let url = try #require(seen.withLock { $0 }?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!query.contains { $0.name == "w" || $0.name == "h" })
        #expect(!query.contains { $0.name == "display" })
    }

    /// The agent may have restarted onto a different port since the last
    /// picture. A client that resolved the address once would fail for ever
    /// against a service running perfectly well.
    @Test("The port is read again for every picture")
    func portIsReadEachTime() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9000)
        let ports = Mutex<[Int?]>([])
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { request in
                ports.withLock { $0.append(request.url?.port) }
                return .success((204, [:], Data()))
            })

        _ = try await client.next(consumer: "app", displayID: nil, fitting: nil)
        suite.publish(port: 9100)
        _ = try await client.next(consumer: "app", displayID: nil, fitting: nil)

        #expect(ports.withLock { $0 } == [9000, 9100])
    }

    // MARK: - The secret

    @Test("A port with no secret beside it sends nothing")
    func noSecret() async {
        let suite = DefaultsSuite()
        suite.preferences.publishServicePort(9000)
        let asked = Mutex(0)
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { _ in
                asked.withLock { $0 += 1 }
                return .success((204, [:], Data()))
            })

        await #expect(throws: PictureClient.Failure.noSecret) {
            try await client.next(consumer: "app", displayID: nil, fitting: nil)
        }
        #expect(asked.withLock { $0 } == 0)
    }

    @Test("Every request carries the secret as a Bearer header")
    func secretIsSent() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9000)
        let secret = try #require(suite.secret)
        let seen = Mutex<String?>(nil)
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { request in
                seen.withLock { $0 = request.value(forHTTPHeaderField: "Authorization") }
                return .success((204, [:], Data()))
            })

        _ = try await client.next(consumer: "app", displayID: nil, fitting: nil)
        #expect(seen.withLock { $0 } == "Bearer \(secret)")
    }

    /// Asked once more only if there is something new to offer: the same
    /// secret sent again would be refused again.
    @Test("A 401 with the secret unchanged is not this user's agent, and is asked once")
    func refusedSecretIsNotOurs() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9000)
        let asked = Mutex(0)
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { _ in
                asked.withLock { $0 += 1 }
                return .success((401, [:], Data()))
            })

        await #expect(throws: PictureClient.Failure.notOurs(port: 9000)) {
            try await client.next(consumer: "app", displayID: nil, fitting: nil)
        }
        #expect(asked.withLock { $0 } == 1)
    }

    @Test("A 401 after the secret changed is asked again with the new one")
    func changedSecretIsRetried() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9000)
        let old = try #require(suite.secret)
        let offered = Mutex<[String]>([])
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { request in
                let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
                let count = offered.withLock { $0.append(header); return $0.count }
                guard count == 1 else { return .success((204, [:], Data())) }
                // The agent's secret was rotated before this request arrived.
                suite.replaceSecret()
                return .success((401, [:], Data()))
            })

        let picture = try await client.next(consumer: "app", displayID: nil, fitting: nil)
        #expect(picture == nil)
        let new = try #require(suite.secret)
        #expect(offered.withLock { $0 } == ["Bearer \(old)", "Bearer \(new)"])
    }

    @Test("A 401 to the new secret too is not this user's agent")
    func refusedTwiceIsNotOurs() async throws {
        let suite = DefaultsSuite()
        suite.publish(port: 9000)
        let asked = Mutex(0)
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { _ in
                if asked.withLock({ $0 += 1; return $0 }) == 1 { suite.replaceSecret() }
                return .success((401, [:], Data()))
            })

        await #expect(throws: PictureClient.Failure.notOurs(port: 9000)) {
            try await client.next(consumer: "app", displayID: nil, fitting: nil)
        }
        #expect(asked.withLock { $0 } == 2)
    }
}

// MARK: - Stubbing the transport

/// A `URLSession` that answers from a closure instead of a socket.
///
/// The client's contract is which query it builds and what it makes of each
/// status, and neither of those wants a listener to assert. Serving a real
/// picture over a real port is the endpoint's own suite, one target over.
private enum Stub {
    typealias Answer = Result<(status: Int, headers: [String: String], body: Data), URLError>

    /// Keyed by session rather than held as one handler, because Swift Testing
    /// runs these in parallel and a single slot would be whichever test wrote
    /// to it last. The key rides on the session's own additional headers, which
    /// is the only channel a test has to a request the client builds.
    private static let handlers = Mutex<[String: @Sendable (URLRequest) -> Answer?]>([:])
    private static let keyHeader = "X-PGR-Stub"

    /// A session that accepts the request and never answers it — the agent that
    /// is running and stuck, which is the case a refused connection cannot
    /// stand in for.
    static func silentSession() -> URLSession {
        session { _ in nil }
    }

    static func session(
        _ answer: (@Sendable (URLRequest) -> Answer?)? = nil
    ) -> URLSession {
        let key = UUID().uuidString
        if let answer { handlers.withLock { $0[key] = answer } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Transport.self]
        configuration.httpAdditionalHeaders = [keyHeader: key]
        return URLSession(configuration: configuration)
    }

    final class Transport: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let key = request.value(forHTTPHeaderField: Stub.keyHeader) ?? ""
            guard let handler = Stub.handlers.withLock({ $0[key] }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            // A handler that answers nil says nothing, ever. Distinct from
            // having no handler, which is a test that forgot to set one up.
            guard let answer = handler(request) else { return }
            switch answer {
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            case .success(let (status, headers, body)):
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
}

/// A throwaway defaults suite, so a test never writes into the real preferences
/// of whoever is running it.
///
/// The same shape as `HostTests.Suite`. Teardown is `discardScratchSuite`, which
/// is the whole of it — see that function for why the obvious companions to it
/// are what used to leave the plists behind.
private final class DefaultsSuite: Sendable {
    let name = scratchSuiteName("picture-client")
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    var preferences: Preferences { Preferences(defaults: defaults) }

    /// A port, and the secret an agent keeps beside it.
    func publish(port: UInt16) {
        preferences.publishServicePort(port)
        _ = preferences.establishServiceSecret()
    }

    var secret: String? { preferences.serviceSecret }

    /// What the agent would do when its secret is rotated.
    func replaceSecret() {
        defaults.set(ServiceSecret.make(), forKey: Preferences.Key.serviceSecret.rawValue)
    }

    deinit { discardScratchSuite(name) }
}
