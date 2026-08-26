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
    private nonisolated final class Scratch {
        let name = "com.sydpolk.photogoround.tests.\(UUID().uuidString)"
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        var preferences: Preferences { Preferences(defaults: defaults) }

        init(port: UInt16? = 9999) {
            if let port { preferences.publishServicePort(port) }
        }

        deinit {
            let defaults = UserDefaults(suiteName: name)
            defaults?.removePersistentDomain(forName: name)
            defaults?.removeSuite(named: name)
            try? FileManager.default.removeItem(
                at: URL.homeDirectory.appending(path: "Library/Preferences/\(name).plist"))
        }
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

        var requests: [URLRequest] { lock.withLock { asked } }

        func answers(status: Int = 200, body: String) {
            lock.withLock {
                _status = status
                _body = Data(body.utf8)
            }
        }

        func answersNothing(status: Int) {
            lock.withLock {
                _status = status
                _body = Data()
            }
        }

        func transport() -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
            { [self] request in
                let (code, data) = lock.withLock {
                    asked.append(request)
                    return (_status, _body)
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

    private func service(_ wire: Wire, _ scratch: Scratch) -> SourceService {
        SourceService(preferences: scratch.preferences, transport: wire.transport())
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
        #expect(request.url?.path == "/v1/sources")
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
        #expect(request.url?.path == "/v1/sources")

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
        #expect(request.url?.path == "/v1/sources/abc")
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
        #expect(request.url?.path == "/v1/sources/abc")
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
