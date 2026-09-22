import Foundation
import Synchronization

/// Whether an agent is answering on a port, asked the way a surface would.
///
/// **An answer, not an open port.** A socket that accepts and says nothing is
/// an agent the surfaces cannot use either — `Deadline`'s whole reason for
/// being — so the question is an HTTP request that has to come back.
/// `/v1/dashboard` because it reads what the agent already holds and asks
/// nothing of the photo library.
enum AgentProbe {

    /// How long to keep asking. **Thirty seconds**: Phase 6 of `Agent
    /// Performance Overhaul.md` has the port open in milliseconds after
    /// launch, and a bootstrap adds launchd's own start. Past this something is
    /// wrong, and the caller says so rather than waiting on it.
    static let patience = Duration.seconds(30)
    static let interval = Duration.milliseconds(500)
    static let requestLimit: TimeInterval = 2

    /// Blocks until an agent on `port` answers, or `patience` runs out.
    static func answers(on port: UInt16) -> Bool {
        let url = URL(string: "http://localhost:\(port)/v1/dashboard")!
        let deadline = ContinuousClock.now + patience
        while ContinuousClock.now < deadline {
            if asksOnce(url) { return true }
            Thread.sleep(forTimeInterval: seconds(interval))
        }
        return asksOnce(url)
    }

    /// One request, answered with any HTTP status. A `404` is still an agent.
    private static func asksOnce(_ url: URL) -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestLimit
        let answered = Mutex(false)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            answered.withLock { $0 = response is HTTPURLResponse }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + requestLimit + 1)
        return answered.withLock { $0 }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
