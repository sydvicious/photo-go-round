import Foundation
import Network
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd

/// Reading a request body, over a real socket.
///
/// The listener answered `GET` and nothing else until sources arrived, so the
/// body path is new plumbing with no coverage anywhere else — and it is exactly
/// the kind that looks right and is not: a body that spans two TCP reads, a
/// `Content-Length` nobody honours, a client that hangs up halfway. None of that
/// is visible from `parse`, so these speak HTTP at a bound port.
@Suite("Request bodies")
struct RequestBodyTests {

    /// Every wait in this file is bounded by one of these, and none of them is
    /// generous — a listener that has decided not to answer will never change
    /// its mind, so waiting longer only turns a failure into a wedged suite with
    /// nothing to read.
    private enum Deadline {
        /// Long enough for a bind on a loaded machine, short enough that a
        /// listener that never becomes ready is a failed test rather than a
        /// stalled run.
        static let ready = Duration.seconds(2)
        /// The whole exchange is loopback and the pauses this file inserts
        /// between writes are milliseconds, so a reply that has not begun by now
        /// is not coming.
        static let reply = Duration.seconds(2)
    }

    private struct TimedOut: Error, CustomStringConvertible {
        let waitingFor: String
        var description: String { "timed out waiting for \(waitingFor)" }
    }

    /// A listener that reports what it was handed, so the assertion is about
    /// what arrived rather than about what any endpoint did with it.
    private final class Echo: @unchecked Sendable {
        let listener: HTTPListener
        private let ready = Ready()

        init() throws {
            listener = HTTPListener(
                port: nil, advertising: "/echo", onReady: { [ready] in ready.set($0) }
            ) { request in
                // One line, so an assertion is a suffix match rather than a
                // parse: the method and path prove it was routed, the count
                // proves the body was measured, and the text proves it arrived
                // in order.
                .text(
                    "\(request.method) \(request.path) \(request.body.count) "
                        + String(decoding: request.body, as: UTF8.self))
            }
            try listener.start()
        }

        deinit { listener.stop() }

        /// The bound port, waited for rather than assumed: binding is
        /// asynchronous and the number is only known once it has happened.
        func port() async throws -> UInt16 {
            let giveUp = ContinuousClock.now + Deadline.ready
            while ContinuousClock.now < giveUp {
                if let port = ready.value { return port }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw TimedOut(waitingFor: "the listener to bind a port")
        }

        private final class Ready: @unchecked Sendable {
            private let lock = NSLock()
            private var port: UInt16?
            func set(_ new: UInt16) {
                lock.lock()
                port = new
                lock.unlock()
            }
            var value: UInt16? {
                lock.lock()
                defer { lock.unlock() }
                return port
            }
        }
    }

    /// Sends the given pieces down one connection, pausing between them, and
    /// returns everything the server said before it closed.
    ///
    /// Raw rather than `URLSession`, because half of what is being tested is how
    /// the bytes are *divided* — a client library would decide that for us and
    /// would never produce the split this is looking for.
    ///
    /// **Nothing here waits indefinitely.** A pending `receive` is resumed only
    /// by the connection, so a server that goes quiet would otherwise park this
    /// task for ever and take the whole suite with it, with no output saying
    /// which test stopped. The watchdog tears the connection down instead, which
    /// completes the outstanding receive with an error and turns a hang into a
    /// named failure.
    private func speak(
        _ pieces: [String], to port: UInt16, thenHangUp: Bool = false
    ) async throws -> String {
        let connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        let queue = DispatchQueue(label: "pgr.test.client")
        connection.start(queue: queue)

        for (index, piece) in pieces.enumerated() {
            if index > 0 { try await Task.sleep(for: .milliseconds(50)) }
            connection.send(content: Data(piece.utf8), completion: .idempotent)
        }
        if thenHangUp {
            // `.finalMessage` is what actually puts a FIN on the wire; sending
            // nil content without it leaves the stream open, and the server then
            // waits for a body that is never coming while this waits for the
            // answer — a deadlock the watchdog below catches but nothing else
            // would.
            connection.send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in })
        }

        let timedOut = Flag()
        let watchdog = DispatchWorkItem {
            timedOut.raise()
            connection.forceCancel()
        }
        queue.asyncAfter(
            deadline: .now() + Deadline.reply.totalSeconds + Double(pieces.count) * 0.05,
            execute: watchdog)
        defer { watchdog.cancel() }

        var received = Data()
        while true {
            let (chunk, done) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    data, _, isComplete, error in
                    continuation.resume(returning: (data, isComplete || error != nil))
                }
            }
            if let chunk { received.append(chunk) }
            if done { break }
        }
        // The watchdog fires on a stalled *and* on a slow-but-alive exchange, so
        // what makes this a failure is that it fired, not that nothing arrived.
        guard !timedOut.lower() else {
            throw TimedOut(waitingFor: "a reply after sending \(pieces.count) piece(s)")
        }
        return String(decoding: received, as: UTF8.self)
    }

    private func head(_ target: String, contentLength: Int) -> String {
        """
        POST \(target) HTTP/1.1\r
        Host: localhost\r
        Content-Type: application/json\r
        Content-Length: \(contentLength)\r
        \r

        """
    }

    // MARK: - Parsing

    @Test("A body handed to the parser is carried on the request")
    func parseCarriesTheBody() throws {
        let body = Data(#"[{"path": "/tmp"}]"#.utf8)
        let request = try #require(
            HTTPListener.parse("POST /v1/sources HTTP/1.1", body: body))

        #expect(request.method == "POST")
        #expect(request.path == "/v1/sources")
        #expect(request.body == body)
    }

    @Test("A request with no body has an empty one, not a missing one")
    func aBodylessRequestHasAnEmptyBody() throws {
        let request = try #require(HTTPListener.parse("GET /v1/next?w=100&h=100 HTTP/1.1"))
        #expect(request.body.isEmpty)
    }

    // MARK: - Over the wire

    @Test("A body sent with the head arrives whole")
    func bodyArrivesWithTheHead() async throws {
        let echo = try Echo()
        let body = #"[{"path": "/tmp/one"}]"#
        let answer = try await speak(
            [head("/v1/sources", contentLength: body.utf8.count) + body],
            to: try await echo.port())

        #expect(answer.contains("200 OK"))
        #expect(answer.hasSuffix("POST /v1/sources \(body.utf8.count) \(body)"))
    }

    @Test("A body that arrives after the head is waited for, not answered without")
    func bodyArrivingLaterIsAssembled() async throws {
        let echo = try Echo()
        let body = #"[{"path": "/tmp/two"}]"#
        // Head first, body 50ms later: the server has to hold the request open
        // rather than answering the moment the blank line lands.
        let answer = try await speak(
            [head("/v1/sources", contentLength: body.utf8.count), body],
            to: try await echo.port())

        #expect(answer.contains("200 OK"))
        #expect(answer.hasSuffix("POST /v1/sources \(body.utf8.count) \(body)"))
    }

    @Test("A body split across several writes is assembled in order")
    func aSplitBodyIsAssembledInOrder() async throws {
        let echo = try Echo()
        let pieces = [#"[{"path":"#, #" "/tmp/three""#, "}]"]
        let body = pieces.joined()
        let answer = try await speak(
            [head("/v1/sources", contentLength: body.utf8.count)] + pieces,
            to: try await echo.port())

        #expect(answer.hasSuffix("POST /v1/sources \(body.utf8.count) \(body)"))
    }

    @Test("A `GET` is answered without waiting for a body it never said it had")
    func getIsUnaffected() async throws {
        let echo = try Echo()
        let answer = try await speak(
            ["GET /v1/next?w=10&h=10 HTTP/1.1\r\nHost: localhost\r\n\r\n"],
            to: try await echo.port())

        #expect(answer.contains("200 OK"))
        #expect(answer.hasSuffix("GET /v1/next 0 "))
    }

    // MARK: - What is promised is delivered

    @Test("A file body decided on is delivered whole, even deleted before it streams")
    func aDeletedFileStillStreams() async throws {
        // The eviction race, reified: serving pops the card, which removes its
        // photograph's eviction protection at the moment it is being sent. The
        // route below decides its answer and then loses the file — exactly
        // what maintenance, a removal, or a source delete can do in that
        // window — and the client must still receive every byte it was
        // promised, because a 200 that lies about its body is worse than any
        // failed transfer.
        let directory = URL.temporaryDirectory.appending(path: "pgr-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "picture.bin")
        // ASCII, so the byte-for-byte comparison survives the UTF-8 decode the
        // test client does; several chunks' worth, so the pump loops.
        let payload = String(repeating: "0123456789", count: 60_000)
        try Data(payload.utf8).write(to: file)

        final class Ready: @unchecked Sendable {
            private let lock = NSLock()
            private var port: UInt16?
            func set(_ new: UInt16) { lock.lock(); port = new; lock.unlock() }
            var value: UInt16? { lock.lock(); defer { lock.unlock() }; return port }
        }
        let ready = Ready()
        let listener = HTTPListener(
            port: nil, advertising: "/file", onReady: { [ready] in ready.set($0) }
        ) { _ in
            guard let body = HTTPListener.Response.Body.streaming(contentsOf: file) else {
                return .text("could not open\n", status: 500, reason: "Internal Server Error")
            }
            // Decided, then deleted. The bytes must already be safe.
            try? FileManager.default.removeItem(at: file)
            return HTTPListener.Response(status: 200, reason: "OK", body: body)
        }
        try listener.start()
        defer { listener.stop() }

        var port: UInt16?
        for _ in 0..<100 {
            if let bound = ready.value { port = bound; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let bound = try #require(port)

        let answer = try await speak(["GET /file HTTP/1.1\r\n\r\n"], to: bound)
        #expect(answer.contains("200 OK"))
        #expect(answer.contains("Content-Length: \(payload.utf8.count)"))
        #expect(answer.hasSuffix(String(payload.suffix(100))), "the body was cut short")
        let body = answer.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        #expect(body.utf8.count == payload.utf8.count)
    }

    // MARK: - What is refused

    @Test("A body larger than the cap is refused before any of it is read")
    func anEnormousBodyIsRefused() async throws {
        let echo = try Echo()
        // The head alone, claiming far more than the cap. Nothing follows it,
        // which is the point: the refusal cannot depend on reading the body.
        let answer = try await speak(
            [head("/v1/sources", contentLength: HTTPListener.maximumBodyBytes + 1)],
            to: try await echo.port())

        #expect(answer.contains("413 Payload Too Large"))
    }

    @Test("A client that hangs up mid-head gets 400, not a complaint about header size")
    func aTruncatedHeadIsBadRequest() async throws {
        let echo = try Echo()
        // A FIN before the blank line ever arrives. The request is truncated,
        // not oversized, and the refusal should say which.
        let answer = try await speak(
            ["GET /v1/nex"], to: try await echo.port(), thenHangUp: true)

        #expect(answer.contains("400 Bad Request"))
        #expect(!answer.contains("431"))
    }

    @Test("A header block past the cap is refused as too large")
    func anEnormousHeadIsRefused() async throws {
        let echo = try Echo()
        // Well past the 64 KB cap, with no terminating blank line — the genuine
        // case the 431 exists for.
        let filler = "X-Filler: " + String(repeating: "a", count: 70 * 1024) + "\r\n"
        let answer = try await speak(
            ["GET /echo HTTP/1.1\r\n" + filler], to: try await echo.port())

        #expect(answer.contains("431"))
    }

    @Test("A client that hangs up mid-body gets a refusal, not half a request")
    func anIncompleteBodyIsRefused() async throws {
        let echo = try Echo()
        let answer = try await speak(
            [head("/v1/sources", contentLength: 64) + "[{\"path\":"],
            to: try await echo.port(), thenHangUp: true)

        #expect(answer.contains("400 Bad Request"))
        // Half a list of sources is not a list of sources.
        #expect(!answer.contains("200 OK"))
    }
}
