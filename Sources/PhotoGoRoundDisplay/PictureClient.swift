import Foundation
import PhotoGoRoundAgentAPI

/// The Mac agent's client: one `GET /v1/next` per picture.
///
/// It opens neither the database nor the cache, which is the whole point of
/// *The service is the interface*. What it needs to know is where the agent is
/// listening, and that is a preference rather than a number anyone agreed on in
/// advance.
public struct PictureClient: PictureSource {
    /// Where the port is published. Read fresh on every request rather than
    /// resolved once: the agent may have restarted onto a different port since
    /// the last picture, and a client holding the old one would fail for ever
    /// against a service that is running perfectly well.
    private let preferences: Preferences
    private let session: URLSession

    /// The bound on one picture.
    ///
    /// **Under one dwell, which is what sets it.** `Shuffle` leaves a picture
    /// up for ten seconds, so a bound of half that means an agent which has
    /// gone quiet is reported while the picture it failed to replace is still
    /// on screen — rather than a dwell and a half later, by which time a person
    /// has been looking at a stalled window wondering. It is also two orders of
    /// magnitude above a healthy serve, which is a queue pop and a file
    /// streamed off the boot volume.
    public static let defaultLimit = Duration.seconds(5)

    /// Injected so a test can prove the bound without waiting out the real
    /// one, which is the same reason `SourcesModel` takes its poll interval.
    private let limit: Duration

    public init(
        preferences: Preferences,
        limit: Duration = PictureClient.defaultLimit,
        session: URLSession = AgentSession.make()
    ) {
        self.preferences = preferences
        self.limit = limit
        self.session = session
    }

    /// Why no picture arrived, when the reason is not *there are none*.
    ///
    /// The two cases are worth keeping apart even though a person sees the same
    /// screen for both, because only one of them is fixed by starting the agent
    /// and the other is fixed by waiting.
    public enum Failure: Error, Equatable, Sendable {
        /// Nothing has published a port. The agent is not running, or has not
        /// finished starting its listener.
        case noPortPublished
        /// A preference domain exists and this process cannot see into it, so
        /// whether a port is published is unknown.
        ///
        /// **Not `noPortPublished`, and the difference is the whole reason this
        /// case exists.** Inside `legacyScreenSaver`'s sandbox an unreadable
        /// domain looks exactly like an empty one, and reporting *the agent is
        /// not running* about an agent that is running perfectly well sends
        /// somebody to the one place the fault is not. Measured 2026-09-07; see
        /// `ServicePort`.
        case portUnreadable(reason: String)
        /// A port is published and nothing is answering there. A crash leaves
        /// the value behind, so this is the ordinary shape of *the agent died*.
        case unreachable(port: UInt16, reason: String)
        /// The service answered, and not with a picture.
        case refused(status: Int)
        /// A port is published, something accepted the connection, and nothing
        /// was ever said.
        ///
        /// **Separate from `unreachable`, because it is a different fault with
        /// a different cause.** Refusing is the agent being absent; going quiet
        /// after accepting is the agent being alive and stuck — which is what a
        /// wedged photo library does to it. Telling somebody the agent is not
        /// running while its process is right there in Activity Monitor sends
        /// them looking in the wrong place.
        case silent(port: UInt16, limit: Duration)
    }

    /// The published address, or `nil` when there is none.
    ///
    /// A value outlives the process that wrote it, so this says what was
    /// published rather than promising something is listening — the same
    /// distinction `pgr_ctl status` draws.
    public var address: URL? {
        guard case .published(let port, _) = ServicePort.read(preferences) else { return nil }
        return URL(string: "http://localhost:\(port)")
    }

    public func next(
        consumer: String, displayID: String?, fitting box: PixelSize?
    ) async throws -> ServedPicture? {
        // **Not `preferences.servicePort` directly.** A sandboxed client is
        // handed an empty suite rather than a refusal, so the lookup has to be
        // able to say *unknown* as well as *none*. See `ServicePort`.
        let port: UInt16
        switch ServicePort.read(preferences) {
        case .published(let found, _): port = found
        case .none: throw Failure.noPortPublished
        case .unreadable(let reason): throw Failure.portUnreadable(reason: reason)
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(port)
        components.path = "/v1/next"
        var query = [URLQueryItem(name: "consumer", value: consumer)]
        if let displayID { query.append(URLQueryItem(name: "display", value: displayID)) }
        if let box {
            query.append(URLQueryItem(name: "w", value: String(box.width)))
            query.append(URLQueryItem(name: "h", value: String(box.height)))
        }
        components.queryItems = query

        let request = URLRequest(url: components.url!)
        // No `Accept`, which the service reads as *HEIC is fine* — it is roughly
        // half the bytes of JPEG and everything on this machine decodes it.
        // Saying so explicitly would mean re-stating the service's default in a
        // second place, where the two could drift apart.
        //
        // **Nothing sets `timeoutInterval` here any more.** It used to be 30,
        // which is `timeoutIntervalForRequest` — the gap between packets, not
        // the bound on the answer; see `AgentSession`. Setting it to `limit`
        // instead would be worse than leaving it: the transport would time out
        // at the same instant `Deadline` does, and the same silence would be
        // reported as `unreachable` or `silent` depending on which won the race.
        // The session's bounds sit above the deadline so that the deadline is
        // always the one that fires.

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Deadline.run(within: limit) { [session] in
                try await session.data(for: request)
            }
        } catch is Deadline.Expired {
            throw Failure.silent(port: port, limit: limit)
        } catch let error as URLError {
            throw Failure.unreachable(port: port, reason: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.unreachable(port: port, reason: "not an HTTP response")
        }
        switch http.statusCode {
        case 200:
            return ServedPicture.from(data: data, headers: Self.headers(of: http))
        // Ordinary rather than an error: the queue is empty, which a fresh
        // library answers until the agent has produced something.
        case 204:
            return nil
        default:
            throw Failure.refused(status: http.statusCode)
        }
    }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var fields: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            fields[name] = value
        }
        return fields
    }
}
