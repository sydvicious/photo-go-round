import Console
import Foundation
import Network
import PhotosGoRoundKit
import PhotosGoRoundAgentAPI

/// A minimal HTTP/1.1 listener, on `Network.framework` and nothing else.
///
/// Hand-rolled for the same reason the argument parsing is: a server that
/// answers `GET` on a handful of routes is a couple of hundred lines, and the
/// no-dependencies rule has no exception for web frameworks. `NWListener` is in
/// the OS on every platform we run on.
///
/// **Deliberately not general.** No keep-alive, no chunked request bodies, no
/// compression, and a request body read whole under a hard cap rather than
/// streamed. Every response says `Connection: close` and the connection is
/// closed when it has been written, which removes the entire state machine that
/// HTTP keep-alive would otherwise need. The cost is one TCP handshake per
/// picture, against a picture that arrives every several seconds.
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
        /// Whatever `Content-Length` said would follow the head, read whole.
        ///
        /// Whole rather than streamed, because the only body this serves is a
        /// list of sources a person just picked in a dialog — kilobytes, with a
        /// hard cap above it. Pictures go the other way, and *that* direction is
        /// streamed.
        var body: Data = Data()

        func query(_ name: String) -> String? { query[name] }
        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    /// What a route hands back. A file body is streamed from disk in bounded
    /// chunks rather than read whole into memory — a 48-megapixel original is
    /// 25 MB and there is no reason for it ever to be resident.
    struct Response {
        var status: Int
        var reason: String
        var headers: [String: String] = [:]
        var body: Body = .empty

        enum Body {
            case empty
            case data(Data)
            case file(StreamedFile)

            /// Opens the file *now*, so what is promised is what is sent.
            ///
            /// Serving pops the queue, which removes the photograph's eviction
            /// protection at the moment its bytes go out — so the file can be
            /// deleted between the answer being decided and the pump reading
            /// it, and a `Content-Length` measured by a separate `stat` could
            /// promise bytes a later open cannot deliver. An open handle keeps
            /// the bytes alive whatever happens to the name, and the size is
            /// measured through the same handle, so the two cannot disagree.
            /// Nil is the race caught before any header is written: the caller
            /// skips, exactly as it would a card whose bytes were never there.
            static func streaming(contentsOf url: URL) -> Body? {
                StreamedFile(url: url).map { .file($0) }
            }
        }

        /// An open file and its size, ready to stream.
        ///
        /// `@unchecked Sendable` because the handle has exactly one consumer:
        /// the pump that streams it after the response crosses to the
        /// listener's queue. Nothing reads it twice and nothing reads it
        /// concurrently.
        final class StreamedFile: @unchecked Sendable {
            let handle: FileHandle
            let byteCount: Int64

            init?(url: URL) {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                let end = (try? handle.seekToEnd()) ?? 0
                guard (try? handle.seek(toOffset: 0)) != nil else {
                    try? handle.close()
                    return nil
                }
                self.handle = handle
                self.byteCount = Int64(end)
            }
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

    private let port: NWEndpoint.Port?
    private let queue = DispatchQueue(label: "com.sydpolk.photosgoround.http")
    private var listener: NWListener?
    private let route: @Sendable (Request) async -> Response
    /// Named in the ready message, so the line a person reads is one they can
    /// paste. Passed in rather than known here, since the listener routes
    /// nothing itself.
    private let advertising: String

    /// A ready listener reports the port it actually bound.
    private let onReady: @Sendable (UInt16) -> Void

    /// Called when the listener cannot bind, which for a fixed port means
    /// something else holds it. See `start()`.
    private let onFailure: @Sendable (String) -> Void

    /// `port` nil asks the kernel for a free one, which is what the tests do.
    /// The agent passes a number: `ServiceAddress.port` for its build, or
    /// whatever `--port` said.
    init(
        port: UInt16?,
        advertising: String,
        onReady: @escaping @Sendable (UInt16) -> Void = { _ in },
        onFailure: @escaping @Sendable (String) -> Void = { _ in },
        route: @escaping @Sendable (Request) async -> Response
    ) {
        self.port = port.flatMap { NWEndpoint.Port(rawValue: $0) }
        self.advertising = advertising
        self.onReady = onReady
        self.onFailure = onFailure
        self.route = route
    }

    /// The port actually bound, known only once the listener is ready. Zero
    /// until then, which is why `onReady` exists rather than callers polling
    /// this.
    private(set) var boundPort: UInt16 = 0

    /// Whether the fixed port was already refused once, so the fallback is
    /// tried once and not in a loop. Touched only from `queue`, as `boundPort`
    /// is.
    private var fellBack = false

    func start() throws {
        try bind(to: port)
    }

    private func bind(to port: NWEndpoint.Port?) throws {
        let parameters = NWParameters.tcp
        // Loopback only, and settled: every platform runs its own agent against
        // its own library, so nothing off this machine has any reason to reach
        // this listener.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let listener = try port.map { try NWListener(using: parameters, on: $0) }
            ?? NWListener(using: parameters)
        let wasFixed = port != nil
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.boundPort = listener.port?.rawValue ?? 0
                Console.recovered(
                    "serving pictures on http://localhost:\(self.boundPort)\(self.advertising)")
                Log.deck.notice("http listener ready on port \(self.boundPort, privacy: .public)")
                self.onReady(self.boundPort)
            case .failed(let error):
                let wanted = port.map { "port \($0.rawValue)" } ?? "a port"
                let words =
                    "http listener failed on \(wanted): \(error)"
                    + (port.map { "; what holds it: lsof -nP -iTCP:\($0.rawValue)" } ?? "")
                // The alert records it, and the agent's console mirror puts the
                // same words in the log. `Plans/Logging.md`, Phase 1.
                Console.alert(words, recording: .kind("listener.failed"))
                // **The fixed port is a preference, not a requirement.** Syd,
                // 2026-09-17: "If the agent can't get the port it wants, it
                // should fall back to what it does now." Which is a port from
                // the kernel, published for clients to read — the discovery
                // path is still there, it has just stopped being the ordinary
                // one. `Plans/Service Port Plan.md`.
                guard wasFixed, !self.fellBack else {
                    self.onFailure(words)
                    return
                }
                self.fellBack = true
                let falling = "taking a port from the kernel instead; clients read the published one"
                Console.note(falling)
                Log.deck.notice("\(falling, privacy: .public)")
                do { try self.bind(to: nil) } catch { self.onFailure("\(error)") }
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

    /// Reads until the blank line that ends the headers. For a `GET` that blank
    /// line is the whole message; anything with a `Content-Length` continues
    /// into `receiveBody`.
    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            guard error == nil else { connection.cancel(); return }

            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer[buffer.startIndex..<terminator.lowerBound]
                guard let request = Self.parse(String(decoding: head, as: UTF8.self)) else {
                    self.write(
                        .text("malformed request\n", status: 400, reason: "Bad Request"),
                        to: connection)
                    return
                }
                // Anything already read past the blank line is the beginning of
                // the body, not a second request: this listener closes the
                // connection after one, so there is never another to confuse it
                // with.
                self.receiveBody(
                    connection, request: request,
                    buffer: Data(buffer[terminator.upperBound...]))
                return
            }
            // A FIN before the blank line is a truncated request, not a large
            // one — the two refusals must not share a status, or a hung-up
            // client reads as a header-size problem in everyone's notes.
            guard !isComplete else {
                self.write(
                    .text("truncated request\n", status: 400, reason: "Bad Request"),
                    to: connection)
                return
            }
            // A header block this large is not a request we are interested in.
            guard buffer.count < 64 * 1024 else {
                self.write(.status(431, "Request Header Fields Too Large"), to: connection)
                return
            }
            self.receiveHead(connection, buffer: buffer)
        }
    }

    /// Reads `Content-Length` bytes, however many arrived with the head.
    ///
    /// A request with no body — every `GET` — takes the first branch and never
    /// waits, which is what keeps the picture path exactly as fast as it was
    /// before bodies existed.
    private func receiveBody(_ connection: NWConnection, request: Request, buffer: Data) {
        let expected = request.header("Content-Length").flatMap(Int.init) ?? 0
        guard expected > 0 else { return dispatch(request, on: connection) }
        guard expected <= Self.maximumBodyBytes else {
            write(
                .text("body too large\n", status: 413, reason: "Payload Too Large"),
                to: connection)
            return
        }
        guard buffer.count < expected else {
            var complete = request
            complete.body = buffer.prefix(expected)
            return dispatch(complete, on: connection)
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            guard error == nil else { connection.cancel(); return }

            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            // A client that hung up mid-body sent us half a request. Answering
            // it would mean acting on half a list of sources.
            guard !isComplete || buffer.count >= expected else {
                self.write(
                    .text("incomplete body\n", status: 400, reason: "Bad Request"),
                    to: connection)
                return
            }
            self.receiveBody(connection, request: request, buffer: buffer)
        }
    }

    /// **One lane per request**, so everything a request does between
    /// suspensions runs on a thread of its own. Until 2026-09-17 this was a
    /// bare `Task`, which put every request on the shared pool — see `Lane`
    /// and `Agent Performance Overhaul.md`, Phase 3.
    private func dispatch(_ request: Request, on connection: NWConnection) {
        let lane = Lane("request")
        Task { [route] in
            let response = await lane.run { await route(request) }
            self.write(response, to: connection)
        }
    }

    /// A body this large is not a source list, and reading it would be the only
    /// place in this process where memory scales with what a client sent.
    static let maximumBodyBytes = 1 << 20

    static func parse(
        _ head: String, body: Data = Data(), receivedAt: ContinuousClock.Instant = .now
    ) -> Request? {
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
            receivedAt: receivedAt,
            body: body
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
        case .file(let file):
            headers["Content-Length"] = String(file.byteCount)
        }

        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        connection.send(
            content: Data(head.utf8),
            completion: .contentProcessed { error in
                guard error == nil else {
                    if case .file(let file) = response.body { try? file.handle.close() }
                    connection.cancel()
                    return
                }
                switch response.body {
                case .empty:
                    connection.cancel()
                case .data(let data):
                    connection.send(
                        content: data,
                        completion: .contentProcessed { _ in connection.cancel() })
                case .file(let file):
                    // Streams from the handle opened when the answer was
                    // decided — the file's name may be gone by now, and the
                    // bytes are not.
                    FilePump(file: file, connection: connection).resume()
                }
            })
    }

    static let chunkSize = 256 * 1024
}

/// Reads an open file and writes it to a connection, one chunk at a time, so
/// memory does not scale with the picture: a ProRAW original is tens of
/// megabytes and the agent's whole resident size is supposed to be less than
/// that.
///
/// A type rather than a recursive local function, because the recursion crosses
/// a `@Sendable` completion handler — which is exactly the boundary Swift 6 is
/// right to object to. The object owns the handle, so closing it is not
/// something a closure has to remember on every exit path.
private final class FilePump: @unchecked Sendable {
    private let handle: FileHandle
    private let connection: NWConnection

    init(file: HTTPListener.Response.StreamedFile, connection: NWConnection) {
        self.handle = file.handle
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
