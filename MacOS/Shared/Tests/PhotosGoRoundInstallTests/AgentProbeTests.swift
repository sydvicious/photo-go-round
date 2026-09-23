import Foundation
import Synchronization
import Testing

@testable import PhotosGoRoundAgentAPI
@testable import PhotosGoRoundInstall

/// The launch check: this user's agent, on its published port, carrying its
/// secret — and a `401` is somebody else's. `Plans/Multi-user Support.md`,
/// *Clients*.
@Suite("Whether this user's agent answers")
struct AgentProbeTests {

    static let secret = String(repeating: "0123456789abcdef", count: 4)

    private final class Suite: Sendable {
        let name = scratchSuiteName("probe")
        var preferences: Preferences { Preferences(suiteName: name) }
        deinit { discardScratchSuite(name) }

        func publish(port: UInt16, secret: String? = AgentProbeTests.secret) {
            preferences.publishServicePort(port)
            if let secret {
                UserDefaults(suiteName: name)!.set(
                    secret, forKey: Preferences.Key.serviceSecret.rawValue)
            }
        }
    }

    /// What the probe asked, in order.
    private final class Asked: Sendable {
        private let requests = Mutex<[URLRequest]>([])
        var all: [URLRequest] { requests.withLock { $0 } }
        func record(_ request: URLRequest) { requests.withLock { $0.append(request) } }
    }

    /// Short enough that a probe that never succeeds costs a fraction of a
    /// second, and long enough for several attempts.
    private static func probe(
        _ suite: Suite, said: Said = Said(), ask: (URLRequest) -> AgentProbe.Reply
    ) -> Bool {
        AgentProbe.answers(
            preferences: suite.preferences, patience: .milliseconds(100),
            interval: .milliseconds(10), ask: ask, say: { said.record($0) })
    }

    /// What the probe said, in order.
    private final class Said: Sendable {
        private let lines = Mutex<[String]>([])
        var all: [String] { lines.withLock { $0 } }
        func record(_ line: String) { lines.withLock { $0.append(line) } }
    }

    @Test("It asks the published port, not the hashed one, and carries the secret")
    func asksThePublishedPortWithTheSecret() throws {
        let suite = Suite()
        let published: UInt16 = BuildVariant.current.port == 41_234 ? 41_235 : 41_234
        suite.publish(port: published)
        let asked = Asked()

        #expect(Self.probe(suite) { asked.record($0); return .status(200) })

        let request = try #require(asked.all.first)
        #expect(request.url?.port == Int(published))
        #expect(request.url?.path() == "/v1/alive")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.secret)")
    }

    @Test("Any status but 401 is this user's agent, a 404 included")
    func anyStatusButRefusalCounts() {
        for status in [200, 204, 404, 500, 503] {
            let suite = Suite()
            suite.publish(port: 41_234)
            #expect(Self.probe(suite) { _ in .status(status) }, "status \(status)")
        }
    }

    @Test("A 401 is somebody else's agent, however long it is asked")
    func refusalIsNotAnswering() {
        let suite = Suite()
        suite.publish(port: 41_234)
        let asked = Asked()

        #expect(!Self.probe(suite) { asked.record($0); return .status(401) })
        #expect(asked.all.count > 1)
    }

    @Test("With no port published there is nothing to ask")
    func noPortNothingAsked() {
        let suite = Suite()
        let asked = Asked()
        #expect(!Self.probe(suite) { asked.record($0); return .status(200) })
        #expect(asked.all.isEmpty)
    }

    /// The secret must never go anywhere without it, and a request without
    /// it would be refused anyway.
    @Test("With a port and no secret there is nothing to ask")
    func noSecretNothingAsked() {
        let suite = Suite()
        suite.publish(port: 41_234, secret: nil)
        let asked = Asked()
        #expect(!Self.probe(suite) { asked.record($0); return .status(200) })
        #expect(asked.all.isEmpty)
    }

    // MARK: - Saying why

    /// Once per reason, not once per attempt: at two a second for ninety
    /// seconds, every attempt would be 180 lines.
    @Test("Each change of reason is said once, and so is giving up")
    func saysWhyOncePerReason() {
        let suite = Suite()
        let said = Said()

        #expect(!Self.probe(suite, said: said) { _ in .status(200) })

        #expect(said.all.first == "waiting — no port published yet")
        #expect(said.all.filter { $0.hasPrefix("waiting") }.count == 1)
        #expect(said.all.last?.hasPrefix("gave up after ") == true)
        #expect(said.all.last?.hasSuffix("no port published yet") == true)
    }

    @Test("A slow agent, a refused secret and a refused connection are each named")
    func reasonsAreNamed() {
        let cases: [(AgentProbe.Reply, String)] = [
            (.timedOut, "waiting — nothing from 41234 within 5 s"),
            (.status(401), "waiting — the agent on 41234 refused this user's secret"),
            (.failed("Could not connect to the server."),
             "waiting — 41234 did not take the request: Could not connect to the server."),
        ]
        for (reply, words) in cases {
            let suite = Suite()
            suite.publish(port: 41_234)
            let said = Said()
            #expect(!Self.probe(suite, said: said) { _ in reply })
            #expect(said.all.first == words)
        }
    }

    @Test("A port with no secret beside it is named as that")
    func noSecretIsNamed() {
        let suite = Suite()
        suite.publish(port: 41_234, secret: nil)
        let said = Said()
        #expect(!Self.probe(suite, said: said) { _ in .status(200) })
        #expect(said.all.first == "waiting — a port but no secret published yet")
    }

    @Test("An answer on the first attempt says nothing")
    func answeringSaysNothing() {
        let suite = Suite()
        suite.publish(port: 41_234)
        let said = Said()
        #expect(Self.probe(suite, said: said) { _ in .status(200) })
        #expect(said.all.isEmpty)
    }

    @Test("A first launch has ninety seconds, and each attempt five")
    func boundsAreRoomy() {
        #expect(AgentProbe.patience == .seconds(90))
        #expect(AgentProbe.requestLimit == 5)
    }

    /// The agent it follows was just restarted: the old one's port goes, the
    /// new one's arrives, and the probe has to follow.
    @Test("The port is read again on every attempt")
    func followsANewPort() {
        let suite = Suite()
        suite.publish(port: 41_234)
        let asked = Asked()

        let answered = Self.probe(suite) { request in
            asked.record(request)
            guard request.url?.port == 41_235 else {
                // Nothing on the old port; the new agent publishes its own.
                suite.publish(port: 41_235)
                return .failed("Could not connect to the server.")
            }
            return .status(200)
        }

        #expect(answered)
        #expect(asked.all.map { $0.url?.port } == [41_234, 41_235])
    }
}
