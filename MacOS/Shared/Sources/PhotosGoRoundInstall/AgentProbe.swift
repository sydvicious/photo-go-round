import Foundation
import PhotosGoRoundAgentAPI
import Synchronization

/// Whether this user's agent is answering, asked the way a surface would.
///
/// **An answer, not an open port.** A socket that accepts and says nothing is
/// an agent the surfaces cannot use either — `Deadline`'s whole reason for
/// being — so the question is an HTTP request that has to come back.
/// `/v1/dashboard` because it reads what the agent already holds and asks
/// nothing of the photo library.
///
/// **The published port, carrying the secret, and a `401` is not an answer.**
/// Until 2026-09-23 this polled the hashed port and counted any status as its
/// agent — so on a collision it found another user's agent and reported its
/// own as up whether it had started or not. The hashed port is also the one
/// another account can hold on purpose, and the secret must never be sent
/// there. `Plans/Multi-user Support.md`, *Clients*.
enum AgentProbe {

    /// How long to keep asking. **Thirty seconds**: Phase 6 of `Agent
    /// Performance Overhaul.md` has the port open in milliseconds after
    /// launch, and a bootstrap adds launchd's own start. Past this something is
    /// wrong, and the caller says so rather than waiting on it.
    static let patience = Duration.seconds(30)
    static let interval = Duration.milliseconds(500)
    static let requestLimit: TimeInterval = 2

    /// Blocks until this user's agent answers, or `patience` runs out.
    ///
    /// `ask` sends one request and hands back its HTTP status, or nil when
    /// nothing answered. A hook so a test can stand in for the agent.
    static func answers(
        preferences: Preferences,
        patience: Duration = Self.patience,
        interval: Duration = Self.interval,
        ask: (URLRequest) -> Int? = Self.asksOnce
    ) -> Bool {
        let deadline = ContinuousClock.now + patience
        while ContinuousClock.now < deadline {
            if attempt(preferences, ask: ask) { return true }
            Thread.sleep(forTimeInterval: seconds(interval))
        }
        return attempt(preferences, ask: ask)
    }

    /// One attempt, with the port and the secret read afresh.
    ///
    /// **Afresh every time**, because the agent this follows was just
    /// restarted: the old one withdraws its port on the way out and the new one
    /// publishes its own once it is listening, and until then there is nothing
    /// to ask. The secret is kept across launches, but a first install has
    /// none until the agent makes it.
    static func attempt(_ preferences: Preferences, ask: (URLRequest) -> Int?) -> Bool {
        preferences.reload()
        guard let port = preferences.servicePort,
            let secret = preferences.serviceSecret,
            let url = URL(string: "http://localhost:\(port)/v1/dashboard")
        else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestLimit
        request.setValue(ServiceSecret.authorization(secret), forHTTPHeaderField: ServiceSecret.headerField)
        guard let status = ask(request) else { return false }
        // Any other status, a `404` included, is still this user's agent.
        return status != 401
    }

    /// One request, and whatever status came back.
    static func asksOnce(_ request: URLRequest) -> Int? {
        let status = Mutex<Int?>(nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status.withLock { $0 = (response as? HTTPURLResponse)?.statusCode }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + requestLimit + 1)
        return status.withLock { $0 }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
