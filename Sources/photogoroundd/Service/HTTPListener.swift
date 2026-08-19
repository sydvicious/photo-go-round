import Console
import Foundation
import Network
import PhotoGoRoundKit

/// A minimal HTTP/1.1 listener, on `Network.framework` and nothing else.
///
/// Hand-rolled for the same reason the argument parsing is: a server that
/// answers `GET` on a handful of routes is a couple of hundred lines, and the
/// no-dependencies rule has no exception for web frameworks. `NWListener` is in
/// the OS on every platform we run on.
///
/// **Deliberately not general.** One method, no keep-alive, no chunked request
/// bodies, no compression. Every response says `Connection: close` and the
/// connection is closed when it has been written, which removes the entire
/// state machine that HTTP keep-alive would otherwise need. The cost is one TCP
/// handshake per picture, against a picture that arrives every several seconds.
final class HTTPListener: @unchecked Sendable {

    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        /// When the head finished arriving, so a route can report how long it
        /// took to answer. Serve latency is the number this whole design is
        /// judged on, and it is invisible unless something measures it.
        let receivedAt: ContinuousClock.Instant

        func query(_ name: String) -> String? { query[name] }
        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    /// What a route hands back. `body` is a closure rather than `Data` so a
    /// picture is streamed from disk in bounded chunks rather than read whole
    /// into memory — a 48-megapixel original is 25 MB and there is no reason
    /// for it ever to be resident.
    struct Response {
        var status: Int
        var reason: String
        var headers: [String: String] = [:]
        var body: Body = .empty

        enum Body {
            case empty
            case data(Data)
            case file(URL, byteCount: Int64)
        }

        static func status(_ code: Int, _ reason: String) -> Response {
            Response(status: code, reason: reason)
        }

        static func noContent() -> Response { .status(204, "No Content") }

        static func text(_ body: String, status: Int = 200, reason: String = "OK") -> Response {
            Response(
                status: status, reason: reason,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: .data(Data(body.utf8))
            )
        }
    }

    /// Where pictures are served when nothing says otherwise.
    static let defaultPort: UInt16 = 9000

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "com.sydpolk.photogoround.http")
    private var listener: NWListener?
    private let route: @Sendable (Request) async -> Response
    /// Named in the ready message, so the line a person reads is one they can
    /// paste. Passed in rather than known here, since the listener routes
    /// nothing itself.
    private let advertising: String

    init(
        port: UInt16,
        advertising: String,
        route: @escaping @Sendable (Request) async -> Response
    ) {
        self.port = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: Self.defaultPort)!
        self.advertising = advertising
        self.route = route
    }

    /// The port actually bound. Fixed today; once the listener asks for `.any`
    /// this is what gets written to preferences for local clients to read.
    private(set) var boundPort: UInt16 = 0

    func start() throws {
        let parameters = NWParameters.tcp
        // Loopback only for now. It has to widen before any off-machine client
        // works, and that arrives with Bonjour rather than on its own.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.boundPort = listener.port?.rawValue ?? 0
                Console.recovered(
                    "serving pictures on http://localhost:\(self.boundPort)\(self.advertising)")
                Log.deck.notice("http listener ready on port \(self.boundPort, privacy: .public)")
            case .failed(let error):
                Console.alert("http listener failed: \(error)")
                Log.deck.error("http listener failed: \(String(describing: error), privacy: .public)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - One connection, one request

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    /// Reads until the blank line that ends the headers. A request with no body
    /// is the only kind this serves, so that blank line is the whole message.
    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            guard error == nil else { connection.cancel(); return }

            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer[buffer.startIndex..<terminator.lowerBound]
                self.handle(String(decoding: head, as: UTF8.self), on: connection)
                return
            }
            // A header block this large is not a request we are interested in.
            guard !isComplete, buffer.count < 64 * 1024 else {
                self.write(.status(431, "Request Header Fields Too Large"), to: connection)
                return
            }
            self.receiveHead(connection, buffer: buffer)
        }
    }

    private func handle(_ head: String, on connection: NWConnection) {
        guard let request = Self.parse(head) else {
            write(.text("malformed request\n", status: 400, reason: "Bad Request"), to: connection)
            return
        }
        Task { [route] in
            let response = await route(request)
            self.write(response, to: connection)
        }
    }

    static func parse(_ head: String, receivedAt: ContinuousClock.Instant = .now) -> Request? {
        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // `URLComponents` rather than hand-splitting, so percent-encoding in a
        // consumer name or a display identifier survives.
        let components = URLComponents(string: "http://localhost" + target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return Request(
            method: method,
            path: components?.path ?? target,
            query: query,
            headers: headers,
            receivedAt: receivedAt
        )
    }

    // MARK: - Writing

    private func write(_ response: Response, to connection: NWConnection) {
        var headers = response.headers
        headers["Connection"] = "close"

        switch response.body {
        case .empty:
            headers["Content-Length"] = "0"
        case .data(let data):
            headers["Content-Length"] = String(data.count)
        case .file(_, let byteCount):
            headers["Content-Length"] = String(byteCount)
        }

        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        connection.send(
            content: Data(head.utf8),
            completion: .contentProcessed { [weak self] error in
                guard error == nil else { connection.cancel(); return }
                switch response.body {
                case .empty:
                    connection.cancel()
                case .data(let data):
                    connection.send(
                        content: data,
                        completion: .contentProcessed { _ in connection.cancel() })
                case .file(let url, _):
                    self?.sendFile(at: url, on: connection)
                }
            })
    }

    /// Streams a file in bounded chunks.
    ///
    /// The point is that memory does not scale with the picture: a ProRAW
    /// original is tens of megabytes and the agent's whole resident size is
    /// supposed to be less than that.
    private func sendFile(at url: URL, on connection: NWConnection) {
        guard let pump = FilePump(url: url, connection: connection) else {
            connection.cancel()
            return
        }
        pump.resume()
    }

    static let chunkSize = 256 * 1024
}

/// Reads a file and writes it to a connection, one chunk at a time.
///
/// A type rather than a recursive local function, because the recursion crosses
/// a `@Sendable` completion handler — which is exactly the boundary Swift 6 is
/// right to object to. The object owns the handle, so closing it is not
/// something a closure has to remember on every exit path.
private final class FilePump: @unchecked Sendable {
    private let handle: FileHandle
    private let connection: NWConnection

    init?(url: URL, connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
        self.connection = connection
    }

    func resume() {
        let chunk = (try? handle.read(upToCount: HTTPListener.chunkSize)) ?? nil
        guard let chunk, !chunk.isEmpty else { return finish() }

        connection.send(
            content: chunk,
            completion: .contentProcessed { [self] error in
                guard error == nil else { return finish() }
                resume()
            })
    }

    private func finish() {
        try? handle.close()
        connection.cancel()
    }
}
