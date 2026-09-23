import Foundation
import PhotosGoRoundAgentAPI
import Synchronization

/// Whether this user's agent is answering, asked the way a surface would.
///
/// **An answer, not an open port.** A socket that accepts and says nothing is
/// an agent the surfaces cannot use either — `Deadline`'s whole reason for
/// being — so the question is an HTTP request that has to come back.
///
/// **`/v1/alive`, since 2026-09-23**, which the agent answers with `204` and
/// nothing else. It was `/v1/dashboard`, chosen because it asks nothing of the
/// photo library — but it is the heaviest read the agent serves, and just
/// after a restart on a loaded Mac it missed every attempt for over a minute
/// while the agent was plainly up. See `Router.alive`.
///
/// **The published port, carrying the secret, and a `401` is not an answer.**
/// Until 2026-09-23 this polled the hashed port and counted any status as its
/// agent — so on a collision it found another user's agent and reported its
/// own as up whether it had started or not. The hashed port is also the one
/// another account can hold on purpose, and the secret must never be sent
/// there. `Plans/Multi-user Support.md`, *Clients*.
enum AgentProbe {

    /// How long to keep asking. **Ninety seconds, since 2026-09-23.** It was
    /// thirty, sized for an agent whose storage already exists — Phase 6 of
    /// `Agent Performance Overhaul.md` has the port open in milliseconds then.
    /// The first launch in a fresh account builds its container, cache and
    /// database from nothing: measured in `randyarbuckle`'s, 18 s to reach the
    /// listener and 21.6 s to publish it, and busy enough after that to miss
    /// the old limit — so the wallpaper and the screensaver were never
    /// installed. Syd: "do 1 and 2". `Plans/Multi-user Support.md`, *Phase 6*.
    static let patience = Duration.seconds(90)
    static let interval = Duration.milliseconds(500)
    /// One attempt's bound. **Five seconds**, the picture client's own
    /// (`ServiceTiming.pictureReadLimit`), where it was two: an agent on its
    /// first launch answers, but slowly.
    static let requestLimit: TimeInterval = 5

    /// Served by the agent's `Router.alivePath`. An agent from before it
    /// answers `404` from its picture endpoint — still past the gate, so still
    /// this user's agent, and counted as answering.
    static let path = "/v1/alive"

    /// What one request came back with.
    enum Reply: Equatable, Sendable {
        /// An HTTP status.
        case status(Int)
        /// Nothing within `requestLimit`.
        case timedOut
        /// The request failed: refused, reset, unreachable.
        case failed(String)
    }

    /// Why an attempt did not count, in words for the install log. Never the
    /// secret, never anything the agent served.
    enum Outcome: Equatable, Sendable {
        case answered(Int)
        case noPort
        case noSecret
        case refusedSecret(port: UInt16)
        case timedOut(port: UInt16)
        case failed(port: UInt16, reason: String)

        var isAnswer: Bool {
            if case .answered = self { return true }
            return false
        }

        var words: String {
            switch self {
            case .answered(let status): "answered \(status)"
            case .noPort: "no port published yet"
            case .noSecret: "a port but no secret published yet"
            case .refusedSecret(let port): "the agent on \(port) refused this user's secret"
            case .timedOut(let port): "nothing from \(port) within \(Int(requestLimit)) s"
            case .failed(let port, let reason): "\(port) did not take the request: \(reason)"
            }
        }
    }

    /// Blocks until this user's agent answers, or `patience` runs out.
    ///
    /// **Says why it is still waiting, each time the reason changes**, and why
    /// it gave up. Until 2026-09-23 it said only `agent: not answering`, and a
    /// slow first launch had to be worked out from timestamps.
    ///
    /// `ask` sends one request. `say` is told each change of reason. Both are
    /// hooks so a test can stand in for the agent and read what was said.
    static func answers(
        preferences: Preferences,
        patience: Duration = Self.patience,
        interval: Duration = Self.interval,
        ask: (URLRequest) -> Reply = Self.asksOnce,
        say: (String) -> Void = { Log.install.notice("install: agent: \($0, privacy: .public)") }
    ) -> Bool {
        let started = ContinuousClock.now
        let deadline = started + patience
        var last: Outcome?
        func attempt() -> Bool {
            let outcome = Self.attempt(preferences, ask: ask)
            if outcome.isAnswer { return true }
            if outcome != last { say("waiting — \(outcome.words)") }
            last = outcome
            return false
        }
        while ContinuousClock.now < deadline {
            if attempt() { return true }
            Thread.sleep(forTimeInterval: seconds(interval))
        }
        if attempt() { return true }
        let waited = Int(seconds(started.duration(to: .now)).rounded())
        say("gave up after \(waited) s — \(last?.words ?? "never asked")")
        return false
    }

    /// One attempt, with the port and the secret read afresh.
    ///
    /// **Afresh every time**, because the agent this follows was just
    /// restarted: the old one withdraws its port on the way out and the new one
    /// publishes its own once it is listening, and until then there is nothing
    /// to ask. The secret is kept across launches, but a first install has
    /// none until the agent makes it.
    static func attempt(_ preferences: Preferences, ask: (URLRequest) -> Reply) -> Outcome {
        preferences.reload()
        guard let port = preferences.servicePort,
            let url = URL(string: "http://localhost:\(port)\(Self.path)")
        else { return .noPort }
        guard let secret = preferences.serviceSecret else { return .noSecret }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestLimit
        request.setValue(ServiceSecret.authorization(secret), forHTTPHeaderField: ServiceSecret.headerField)
        switch ask(request) {
        // Any other status, a `404` included, is still this user's agent.
        case .status(401): return .refusedSecret(port: port)
        case .status(let status): return .answered(status)
        case .timedOut: return .timedOut(port: port)
        case .failed(let reason): return .failed(port: port, reason: reason)
        }
    }

    /// One request, and whatever came back.
    static func asksOnce(_ request: URLRequest) -> Reply {
        let reply = Mutex<Reply?>(nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, error in
            reply.withLock {
                if let http = response as? HTTPURLResponse {
                    $0 = .status(http.statusCode)
                } else if let error = error as? URLError, error.code == .timedOut {
                    $0 = .timedOut
                } else {
                    $0 = .failed(error?.localizedDescription ?? "no response")
                }
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + requestLimit + 1) == .success else { return .timedOut }
        return reply.withLock { $0 } ?? .timedOut
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
