import Foundation
import PhotoGoRoundAgentAPI
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

    public init(preferences: Preferences, session: URLSession = .shared) {
        self.preferences = preferences
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
        /// A port is published and nothing is answering there. A crash leaves
        /// the value behind, so this is the ordinary shape of *the agent died*.
        case unreachable(port: UInt16, reason: String)
        /// The service answered, and not with a picture.
        case refused(status: Int)
    }

    /// The published address, or `nil` when there is none.
    ///
    /// A value outlives the process that wrote it, so this says what was
    /// published rather than promising something is listening — the same
    /// distinction `pgr_ctl status` draws.
    public var address: URL? {
        preferences.servicePort.flatMap { URL(string: "http://localhost:\($0)") }
    }

    public func next(
        consumer: String, displayID: String?, fitting box: PixelSize?
    ) async throws -> ServedPicture? {
        guard let port = preferences.servicePort else { throw Failure.noPortPublished }

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

        var request = URLRequest(url: components.url!)
        // No `Accept`, which the service reads as *HEIC is fine* — it is roughly
        // half the bytes of JPEG and everything on this machine decodes it.
        // Saying so explicitly would mean re-stating the service's default in a
        // second place, where the two could drift apart.
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
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
