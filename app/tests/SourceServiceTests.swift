import Foundation
import PhotoGoRoundAgentAPI
import Testing

@testable import Photo_Go_Round

/// What the app sends, and what it makes of what comes back.
///
/// **No agent is involved.** The transport is a stub, so these assert the shape
/// of the request and the reading of the answer — which is the whole of what
/// this type does. Whether the service behaves as described is the service's own
/// suite's business, and it has one.
@Suite("Source service")
@MainActor
struct SourceServiceTests {

    /// A defaults suite of this test's own, with a port published in it so the
    /// client believes there is an agent to talk to.
    /// A throwaway preference domain that leaves nothing behind.
    ///
    /// **A path domain from `scratchSuiteName`, not a dotted one.** A dotted
    /// name lands in `~/Library/Preferences`, which `cfprefsd` owns and writes
    /// on its own schedule — including after the process that asked is gone.
    /// That is how the `removePersistentDomain` teardown that used to be here
    /// lost its race and left one plist per test behind, until a later
    /// `swift test` failed on them. See `ScratchPreferences`.
    private nonisolated final class Scratch {
        let name = scratchSuiteName("source-service")
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        var preferences: Preferences { Preferences(defaults: defaults) }

        init(port: UInt16? = 9999) {
            if let port { preferences.publishServicePort(port) }
        }

        deinit { discardScratchSuite(name) }
    }

    /// Records what was asked and answers with what it was told to.
    ///
    /// `nonisolated` because the transport is called from whatever context the
    /// client happens to be on, and this target compiles with `MainActor` as the
    /// default isolation — so without it the stub would be main-actor bound and
    /// unable to answer at all.
    private nonisolated final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [URLRequest] = []
        private var _status = 200
        private var _body = Data("[]".utf8)
        private var _silent = false

        var requests: [URLRequest] { lock.withLock { asked } }

        func answers(status: Int = 200, body: String) {
            lock.withLock {
                _status = status
                _body = Data(body.utf8)
            }
        }

        /// Accepts the request and never answers it.
        ///
        /// **The agent that is running and stuck**, which a refused connection
        /// cannot stand in for: one is a `URLError` arriving at once, the other
        /// is a silence that lasts until somebody gives up on it.
        func saysNothing() {
            lock.withLock { _silent = true }
        }

        func answersNothing(status: Int) {
            lock.withLock {
                _status = status
                _body = Data()
            }
        }

        func transport() -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
            { [self] request in
                let (code, data, silent) = lock.withLock {
                    asked.append(request)
                    return (_status, _body, _silent)
                }
                if silent {
                    // Far longer than any bound a test sets, so the deadline is
                    // always what ends the wait.
                    try await Task.sleep(for: .seconds(300))
                }
                return (
                    data,
                    HTTPURLResponse(
                        url: request.url!, statusCode: code, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!
                )
            }
        }
    }

    private func service(
        _ wire: Wire, _ scratch: Scratch,
        read: Duration = SourceService.defaultReadLimit,
        write: Duration = SourceService.defaultWriteLimit
    ) -> SourceService {
        SourceService(
            preferences: scratch.preferences, read: read, write: write,
            transport: wire.transport())
    }

    // MARK: - An agent that is running and stuck

    /// **The fault the bounds exist for.** A wedged photo library costs the
    /// agent the cooperative threads it needs to answer anything, so it takes
    /// the connection and then says nothing. Before there was a deadline the
    /// panel waited on that for as long as it lasted.
    @Test("An agent that accepts the connection and says nothing is silent, not unreachable")
    func silence() async throws {
        let scratch = Scratch()
        let wire = Wire()
        wire.saysNothing()

        await #expect(throws: SourceService.Failure.silent(limit: .milliseconds(50))) {
            try await service(wire, scratch, read: .milliseconds(50)).list()
        }
    }

    /// Each kind of ask waits its own length — reading is polled and gives up
    /// quickly, changing is real work and is given room. A wiring mistake would
    /// silently hand one of them the other's patience.
    @Test("Reading and changing each report the bound they were given")
    func eachAskHasItsOwnBound() async throws {
        let scratch = Scratch()
        let wire = Wire()
        wire.saysNothing()
        let service = service(
            wire, scratch, read: .milliseconds(30), write: .milliseconds(60))

        await #expect(throws: SourceService.Failure.silent(limit: .milliseconds(30))) {
            try await service.list()
        }
        await #expect(throws: SourceService.Failure.silent(limit: .milliseconds(60))) {
            try await service.remove("abc")
        }
    }

    /// A refusal that arrives promptly is not a silence, and reporting it as one
    /// would hide what the agent actually said.
    @Test("An agent that answers quickly is never reported as silent")
    func promptRefusalIsNotSilence() async throws {
        let scratch = Scratch()
        let wire = Wire()
        wire.answers(status: 400, body: "{\"error\": \"no such source\"}")

        await #expect(throws: SourceService.Failure.refused(status: 400, reason: "no such source")) {
            try await service(wire, scratch, read: .milliseconds(50)).list()
        }
    }

    private func body(of request: URLRequest) throws -> Any {
        try JSONSerialization.jsonObject(with: try #require(request.httpBody))
    }

    // MARK: - Reading

    @Test("The list is a GET, and its fields survive the trip")
    func listDecodes() async throws {
        let scratch = Scratch()
        let wire = Wire()
        wire.answers(
            body: """
            [{"uuid": "abc", "kind": "folder", "locator": "/Users/me/Pictures/Sunsets",
              "recursive": true, "enabled": true, "available": true, "photos": 1284,
              "addedAt": "2026-08-23T18:04:11Z", "scannedAt": "2026-08-23T18:04:12Z"}]
            """)

        let sources = try await service(wire, scratch).list()

        let request = try #require(wire.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v2/sources")
        #expect(request.url?.port == 9999)

        let source = try #require(sources.first)
        #expect(source.uuid == "abc")
        #expect(source.recursive == true)
        #expect(source.photos == 1284)
        #expect(source.scannedAt != nil)
        // The leaf is what a list shows; the full path is shown under it.
        #expect(source.name == "Sunsets")
        #expect(source.isFolder)
    }

    @Test("A source the agent describes with fields we do not know still decodes")
    func unknownFieldsAreIgnored() async throws {
        let scratch = Scratch()
        let wire = Wire()
        wire.answers(
            body: """
            [{"uuid": "abc", "kind": "folder", "locator": "/x", "enabled": true,
              "available": true, "photos": 0, "addedAt": "2026-08-23T18:04:11Z",
              "somethingNewerAgentsSend": 42}]
            """)

        // A newer agent must not break an older panel, which is the whole reason
        // the wire is a shape rather than a shared module.
        #expect(try await service(wire, scratch).list().count == 1)
    }

    @Test("A file source reports no recursion, which is what disables Configure")
    func aFileHasNoRecursion() async throws {
        let scratch = Scratch()
        let wire = Wire()
        wire.answers(
            body: """
            [{"uuid": "abc", "kind": "file", "locator": "/x/one.png", "enabled": true,
              "available": true, "photos": 1, "addedAt": "2026-08-23T18:04:11Z"}]
            """)

        let source = try #require(try await service(wire, scratch).list().first)
        #expect(source.recursive == nil)
        #expect(!source.isFolder)
    }

    // MARK: - Writing

    @Test("Several files are one POST carrying an array, not a request each")
    func filesGoInOneRequest() async throws {
        let scratch = Scratch()
        let wire = Wire()
        let files = [URL(filePath: "/x/one.png"), URL(filePath: "/x/two.png")]

        _ = try? await service(wire, scratch).add(files: files)

        // One request, because adding two hundred one at a time would ask the
        // agent to refresh two hundred times.
        #expect(wire.requests.count == 1)
        let request = try #require(wire.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v2/sources")

        let sent = try #require(try body(of: request) as? [[String: Any]])
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0["kind"] as? String == "file" })
        #expect(sent.map { $0["path"] as? String } == ["/x/one.png", "/x/two.png"])
    }

    @Test("A folder carries its own answer about nested folders")
    func folderCarriesRecursion() async throws {
        let scratch = Scratch()
        let wire = Wire()

        _ = try? await service(wire, scratch)
            .add(folder: URL(filePath: "/x/Pictures"), recursive: true)

        let request = try #require(wire.requests.first)
        let sent = try #require(try body(of: request) as? [[String: Any]])
        #expect(sent.count == 1)
        #expect(sent[0]["kind"] as? String == "folder")
        #expect(sent[0]["recursive"] as? Bool == true)
    }

    @Test("Configure sends only the field it changed")
    func recursionIsPatched() async throws {
        let scratch = Scratch()
        let wire = Wire()
        wire.answers(
            body: """
            {"uuid": "abc", "kind": "folder", "locator": "/x", "recursive": false,
             "enabled": true, "available": true, "photos": 3,
             "addedAt": "2026-08-23T18:04:11Z"}
            """)

        let updated = try await service(wire, scratch).setRecursive(false, of: "abc")

        let request = try #require(wire.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/v2/sources/abc")
        #expect(try body(of: request) as? [String: Bool] == ["recursive": false])
        #expect(updated.recursive == false)
    }

    @Test("Removing names the source in the path and carries no body")
    func removeIsADelete() async throws {
        let scratch = Scratch()
        let wire = Wire()
        wire.answersNothing(status: 204)

        try await service(wire, scratch).remove("abc")

        let request = try #require(wire.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/v2/sources/abc")
        #expect(request.httpBody == nil)
    }

    // MARK: - What a refusal becomes

    @Test("Paths the agent could not find come back named")
    func missingPathsAreNamed() async throws {
        let scratch = Scratch()
        let wire = Wire()
        wire.answers(status: 400, body: #"{"error": "not found", "missing": ["/gone", "/also-gone"]}"#)

        await #expect(throws: SourceService.Failure.notFound(["/gone", "/also-gone"])) {
            try await service(wire, scratch).add(files: [URL(filePath: "/gone")])
        }
    }

    @Test("Any other refusal keeps the reason the agent gave")
    func refusalsKeepTheirReason() async throws {
        let scratch = Scratch()
        let wire = Wire()
        wire.answers(status: 400, body: #"{"error": "a file source has no recursive option"}"#)

        await #expect(
            throws: SourceService.Failure.refused(
                status: 400, reason: "a file source has no recursive option")
        ) {
            try await service(wire, scratch).setRecursive(true, of: "abc")
        }
    }

    @Test("With no port published there is nothing to ask, and no request is made")
    func noPortMeansNoAgent() async throws {
        let scratch = Scratch(port: nil)
        let wire = Wire()

        await #expect(throws: SourceService.Failure.noAgent) {
            try await service(wire, scratch).list()
        }
        #expect(wire.requests.isEmpty)
    }

    @Test("An answer that will not decode is said so rather than read as empty")
    func anUnreadableAnswerIsNotAnEmptyList() async throws {
        let scratch = Scratch()
        let wire = Wire()
        wire.answers(body: "<html>who are you</html>")

        await #expect(throws: SourceService.Failure.unreadable) {
            try await service(wire, scratch).list()
        }
    }
}
