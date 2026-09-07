import Foundation

/// The `URLSession` a client talks to the agent with, and why it is never
/// `URLSession.shared`.
///
/// **`.shared` cannot be configured and its resource timeout is seven days.**
/// Setting `timeoutInterval` on a request only moves `timeoutIntervalForRequest`,
/// which is the gap *between* packets — so an agent that dribbles one byte a
/// minute resets that clock for ever and is never given up on. The bound that
/// covers the whole answer is `timeoutIntervalForResource`, and it lives on the
/// configuration rather than the request.
///
/// It is also process-wide. Mutating its behaviour for the picture loop would
/// mutate it for everything else in the app that ever uses it.
///
/// **These are the transport's own bounds and not the rule.** The rule is
/// `Deadline`, applied around the call, because the seam a client is written
/// against is a function rather than a session — `PictureSource` exists because
/// Phase 4 already knows about a transport that is not HTTP at all. What the
/// configuration buys on top is the socket being released at roughly the moment
/// the caller stops waiting, instead of a connection nobody is listening to
/// being held open against the agent.
public enum AgentSession {

    /// One session per client, made once. `URLSession` pools connections per
    /// instance, and a fresh one per request would pay a handshake it did not
    /// need to.
    public static func make(
        request: Duration = requestTimeout,
        resource: Duration = resourceTimeout
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.totalSeconds
        configuration.timeoutIntervalForResource = resource.totalSeconds
        // Loopback. There is no connectivity to come back, so waiting for it
        // would turn "the agent is not running" into a request that never
        // returns — which is the exact failure this file exists to remove.
        configuration.waitsForConnectivity = false
        // A picture is never the same twice and a source list is a fact about
        // right now. Nothing here is worth a byte of cache.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    /// The gap between packets. Generous, because it is the weaker of the two
    /// bounds and the one that a healthy-but-busy agent is most likely to brush
    /// against.
    public static let requestTimeout = Duration.seconds(15)

    /// The whole answer, end to end. Above every `Deadline` a client applies,
    /// deliberately: the caller's bound is the one that decides what a person
    /// is told, and a transport that fired first would report the same silence
    /// as a `URLError` with different words.
    public static let resourceTimeout = Duration.seconds(60)
}
