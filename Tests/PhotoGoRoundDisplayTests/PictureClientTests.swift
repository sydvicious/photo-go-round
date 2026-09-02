import Foundation
import Synchronization
import Testing

@testable import PhotoGoRoundDisplay
@testable import PhotoGoRoundAgentAPI

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
        suite.preferences.publishServicePort(9999)
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

    // MARK: - The answers that are not errors

    @Test("204 is an empty queue, which is an ordinary answer")
    func emptyQueue() async throws {
        let suite = DefaultsSuite()
        suite.preferences.publishServicePort(9000)
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { _ in .success((204, [:], Data())) })

        let picture = try await client.next(consumer: "app", displayID: nil, fitting: nil)
        #expect(picture == nil)
    }

    @Test("A picture arrives with its bytes and everything the service said about it")
    func served() async throws {
        let suite = DefaultsSuite()
        suite.preferences.publishServicePort(9000)
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
                        "X-PGR-Cache": "miss",
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
        #expect(picture.cache == .miss)
    }

    @Test("Anything else the service says is a refusal")
    func refused() async throws {
        let suite = DefaultsSuite()
        suite.preferences.publishServicePort(9000)
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
        suite.preferences.publishServicePort(9000)
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
        suite.preferences.publishServicePort(9000)
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
        suite.preferences.publishServicePort(9000)
        let ports = Mutex<[Int?]>([])
        let client = PictureClient(
            preferences: suite.preferences,
            session: Stub.session { request in
                ports.withLock { $0.append(request.url?.port) }
                return .success((204, [:], Data()))
            })

        _ = try await client.next(consumer: "app", displayID: nil, fitting: nil)
        suite.preferences.publishServicePort(9100)
        _ = try await client.next(consumer: "app", displayID: nil, fitting: nil)

        #expect(ports.withLock { $0 } == [9000, 9100])
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
    private static let handlers = Mutex<[String: @Sendable (URLRequest) -> Answer]>([:])
    private static let keyHeader = "X-PGR-Stub"

    static func session(
        _ answer: (@Sendable (URLRequest) -> Answer)? = nil
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
            guard let answer = Stub.handlers.withLock({ $0[key] })?(request) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
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
private final class DefaultsSuite {
    let name = scratchSuiteName("picture-client")
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    var preferences: Preferences { Preferences(defaults: defaults) }

    deinit { discardScratchSuite(name) }
}
