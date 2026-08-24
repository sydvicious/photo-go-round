import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd

/// The source endpoints, driven through `route` rather than through the kit
/// beneath them.
///
/// **In the front door on purpose.** `SourceStore.add` has its own tests and
/// they were all passing while the endpoint below it could still have had the
/// wrong status code, the wrong body, or no reconcile at all — the cache-miss
/// bug this suite's sibling exists for was exactly that shape. Where a decision
/// only exists at the wiring, there has to be a test that arrives over HTTP.
@Suite("Source endpoint")
struct SourceEndpointTests {

    /// Collects what the endpoint said it did, so the records can be read rather
    /// than watched.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [SourceEndpoint.Handled] = []

        func record(_ entry: SourceEndpoint.Handled) {
            lock.lock()
            entries.append(entry)
            lock.unlock()
        }

        var all: [SourceEndpoint.Handled] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    /// A library on disk with an endpoint over it, and a preferences suite that
    /// belongs to this test alone.
    ///
    /// On disk rather than in memory because the endpoint opens a connection per
    /// request — deliberately, since a `Database` belongs to one isolation
    /// domain — so an in-memory library would be a different library every time.
    private final class Library {
        let directory: URL
        let endpoint: SourceEndpoint
        let store: SourceStore
        /// The endpoint's record of what is on disk, so a test can ask what a
        /// removal actually freed rather than trusting that it did.
        let bytes: PhotoStore
        let preferences: Preferences
        let log = Collector()
        private let suite = "com.sydpolk.photogoround.tests.\(UUID().uuidString)"

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-src-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let path = directory.appending(path: "photogoround.sqlite")
                .path(percentEncoded: false)
            let database = try Database(path: path)
            try Migrator.migrate(database)
            store = SourceStore(database: database, bytes: PhotoStore(
                root: directory.appending(path: "cache")))

            preferences = Preferences(defaults: UserDefaults(suiteName: suite)!)
            bytes = PhotoStore(root: directory.appending(path: "cache"))
            let collector = log
            endpoint = SourceEndpoint(
                databasePath: path, preferences: preferences, bytes: bytes,
                log: { collector.record($0) })
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
            let defaults = UserDefaults(suiteName: suite)
            defaults?.removePersistentDomain(forName: suite)
            defaults?.removeSuite(named: suite)
            try? FileManager.default.removeItem(
                at: URL.homeDirectory.appending(path: "Library/Preferences/\(suite).plist"))
        }

        // MARK: Asking

        func get(_ target: String) async throws -> HTTPListener.Response {
            await endpoint.route(try #require(HTTPListener.parse("GET \(target) HTTP/1.1")))
        }

        func delete(_ target: String) async throws -> HTTPListener.Response {
            await endpoint.route(try #require(HTTPListener.parse("DELETE \(target) HTTP/1.1")))
        }

        func patch(_ json: String, to target: String) async throws -> HTTPListener.Response {
            try await send("PATCH", json, to: target)
        }

        func post(_ json: String, to target: String = SourceEndpoint.path) async throws
            -> HTTPListener.Response
        {
            try await send("POST", json, to: target)
        }

        private func send(_ method: String, _ json: String, to target: String) async throws
            -> HTTPListener.Response
        {
            let body = Data(json.utf8)
            return await endpoint.route(
                try #require(
                    HTTPListener.parse(
                        """
                        \(method) \(target) HTTP/1.1\r
                        Content-Type: application/json\r
                        Content-Length: \(body.count)
                        """, body: body)))
        }

        /// One folder with `photographs` files in it, ready to be added.
        @discardableResult
        func folder(_ name: String, photographs: Int = 0) -> URL {
            let folder = directory.appending(path: name)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<photographs {
                FileManager.default.createFile(
                    atPath: folder.appending(path: "photo-\(index).png")
                        .path(percentEncoded: false),
                    contents: Data(repeating: 0xAB, count: 32))
            }
            return folder
        }

        func path(of folder: URL) -> String {
            folder.standardizedFileURL.path(percentEncoded: false)
        }
    }

    // MARK: - Reading the body back

    private func sources(_ response: HTTPListener.Response) throws -> [SourceEndpoint.Wire] {
        try decoder().decode([SourceEndpoint.Wire].self, from: try bytes(response))
    }

    private func source(_ response: HTTPListener.Response) throws -> SourceEndpoint.Wire {
        try decoder().decode(SourceEndpoint.Wire.self, from: try bytes(response))
    }

    private func failure(_ response: HTTPListener.Response) throws -> SourceEndpoint.Failure {
        try decoder().decode(SourceEndpoint.Failure.self, from: try bytes(response))
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func bytes(_ response: HTTPListener.Response) throws -> Data {
        guard case .data(let data) = response.body else {
            Issue.record("the response carried no body")
            throw CancellationError()
        }
        return data
    }

    // MARK: - Listing

    @Test("An empty library lists no sources, which is an answer rather than an error")
    func emptyListIsAnEmptyArray() async throws {
        let library = try Library()
        let response = try await library.get(SourceEndpoint.path)

        #expect(response.status == 200)
        #expect(response.headers["Content-Type"] == "application/json; charset=utf-8")
        #expect(try sources(response).isEmpty)
    }

    @Test("The list carries the identity, the options, the state, and the count")
    func listJoinsTheCountAndTheState() async throws {
        let library = try Library()
        let folder = library.folder("wallpaper", photographs: 3)
        _ = try await library.post(
            """
            [{"kind": "folder", "path": "\(library.path(of: folder))", "recursive": true}]
            """)

        // The scan is the agent's job and the endpoint does not wait for it, so
        // the count only exists once something has refreshed.
        for source in try library.store.all() {
            _ = await library.store.refresh(source)
        }

        let listed = try sources(try await library.get(SourceEndpoint.path))
        #expect(listed.count == 1)
        let entry = try #require(listed.first)
        #expect(entry.kind == "folder")
        #expect(entry.locator == library.path(of: folder))
        #expect(entry.recursive == true)
        #expect(entry.enabled)
        #expect(entry.available)
        #expect(entry.unavailableReason == nil)
        #expect(entry.photos == 3)
        #expect(entry.scannedAt != nil)
        // The uuid is the thing a client names it by, and it has to be usable.
        #expect(UUID(uuidString: entry.uuid) != nil)
    }

    @Test("A source that has not been scanned is listed with no count, not withheld")
    func anUnscannedSourceIsStillListed() async throws {
        let library = try Library()
        let folder = library.folder("fresh", photographs: 5)
        _ = try await library.post("""
            [{"path": "\(library.path(of: folder))"}]
            """)

        let entry = try #require(try sources(try await library.get(SourceEndpoint.path)).first)
        #expect(entry.photos == 0)
        #expect(entry.scannedAt == nil)
    }

    @Test("An unavailable source says so, and says why the last scan thought so")
    func unavailabilityIsReported() async throws {
        let library = try Library()
        let folder = library.folder("unplugged")
        _ = try await library.post(#"[{"path": "\#(library.path(of: folder))"}]"#)
        let source = try #require(try library.store.all().first)
        try library.store.markUnavailable(sourceID: source.id, reason: "volume not mounted")

        let entry = try #require(try sources(try await library.get(SourceEndpoint.path)).first)
        #expect(!entry.available)
        #expect(entry.unavailableReason == "volume not mounted")
        // Still listed and still enabled: unavailable is a state, not a removal.
        #expect(entry.enabled)
    }

    /// **This endpoint does not stop to look**, and that is deliberate. It
    /// reports what the agent knows. A client that can see the path checks it
    /// itself and gets a fresher answer than a round trip could carry — the Mac
    /// app is unsandboxed and does exactly that — and a client that cannot see
    /// the path is not helped by this one looking either.
    @Test("It reports what the scan concluded rather than stopping to check")
    func availabilityIsReportedNotRechecked() async throws {
        let library = try Library()
        let folder = library.folder("present")
        _ = try await library.post(#"[{"path": "\#(library.path(of: folder))"}]"#)
        let source = try #require(try library.store.all().first)

        // The folder is right there, and the row says otherwise. The row wins,
        // because reading it is all this does.
        try library.store.markUnavailable(sourceID: source.id, reason: "volume not mounted")
        let entry = try #require(try sources(try await library.get(SourceEndpoint.path)).first)
        #expect(!entry.available)
    }

    // MARK: - One source, and the options it was added with

    @Test("A source is fetched by its uuid, with the options it was added with")
    func oneSourceByUUID() async throws {
        let library = try Library()
        let folder = library.folder("nested")
        let created = try sources(
            try await library.post(
                """
                [{"kind": "folder", "path": "\(library.path(of: folder))", "recursive": true}]
                """))
        let uuid = try #require(created.first?.uuid)

        let response = try await library.get("\(SourceEndpoint.path)/\(uuid)")
        #expect(response.status == 200)

        let one = try source(response)
        #expect(one.uuid == uuid)
        #expect(one.locator == library.path(of: folder))
        #expect(one.recursive == true)
        #expect(one.enabled)
    }

    @Test("A file source reports no recursion at all, rather than false")
    func aFileHasNoRecursionOption() async throws {
        let library = try Library()
        let folder = library.folder("pinned", photographs: 1)
        let file = folder.appending(path: "photo-0.png").path(percentEncoded: false)
        let created = try sources(
            try await library.post("""
                [{"kind": "file", "path": "\(file)"}]
                """))

        let one = try source(
            try await library.get("\(SourceEndpoint.path)/\(try #require(created.first?.uuid))"))
        #expect(one.kind == "file")
        #expect(one.recursive == nil)
    }

    @Test("An unknown uuid is 404, and says so in the same shape as every failure")
    func unknownUUIDIsNotFound() async throws {
        let library = try Library()
        let response = try await library.get(
            "\(SourceEndpoint.path)/\(UUID().uuidString.lowercased())")

        #expect(response.status == 404)
        #expect(try failure(response).error == "no such source")
    }

    // MARK: - Adding

    @Test("A folder is added, projected, and described in the answer")
    func addAFolder() async throws {
        let library = try Library()
        let folder = library.folder("sunsets", photographs: 2)
        let response = try await library.post(
            """
            [{"kind": "folder", "path": "\(library.path(of: folder))", "recursive": true}]
            """)

        #expect(response.status == 201)
        let created = try sources(response)
        #expect(created.count == 1)
        #expect(created.first?.locator == library.path(of: folder))
        #expect(created.first?.recursive == true)

        // Preferences are the durable list, and the endpoint writes them on the
        // client's behalf — that is the whole reversal this endpoint exists for.
        #expect(library.preferences.sources.map(\.locator) == [library.path(of: folder)])
        // And the table is in step before the answer goes out, so the uuid in
        // the body names something that exists.
        #expect(try library.store.all().count == 1)
        #expect(try library.store.source(uuid: try #require(created.first?.uuid)) != nil)
    }

    @Test("`kind` is optional and means folder, which is what a dialog produces")
    func kindDefaultsToFolder() async throws {
        let library = try Library()
        let folder = library.folder("plain")
        let created = try sources(
            try await library.post("""
                [{"path": "\(library.path(of: folder))"}]
                """))
        #expect(created.first?.kind == "folder")
        #expect(created.first?.recursive == false)
    }

    @Test("An array of three is one request, one write, and three sources")
    func addsABatch() async throws {
        let library = try Library()
        let paths = ["one", "two", "three"].map { library.path(of: library.folder($0)) }
        let response = try await library.post(
            "[" + paths.map { #"{"path": "\#($0)"}"# }.joined(separator: ",") + "]")

        #expect(response.status == 201)
        #expect(try sources(response).map(\.locator) == paths)
        #expect(library.preferences.sources.map(\.locator) == paths)
    }

    @Test("One path that is not there refuses the whole batch and names it")
    func aMissingPathRefusesTheBatch() async throws {
        let library = try Library()
        let real = library.path(of: library.folder("real"))
        let response = try await library.post(
            """
            [{"path": "\(real)"}, {"path": "/nowhere/at/all"}]
            """)

        #expect(response.status == 400)
        let refusal = try failure(response)
        #expect(refusal.error == "not found")
        #expect(refusal.missing == ["/nowhere/at/all"])

        // Nothing was added — not even the half of the batch that resolved.
        #expect(library.preferences.sources.isEmpty)
        #expect(try library.store.all().isEmpty)
    }

    @Test("A file added as a folder refuses the batch and names the path")
    func aFileAddedAsAFolderIsRefused() async throws {
        let library = try Library()
        let folder = library.folder("real", photographs: 1)
        let file = library.path(of: folder.appending(path: "photo-0.png"))

        let response = try await library.post(#"[{"kind": "folder", "path": "\#(file)"}]"#)
        #expect(response.status == 400)
        let refusal = try failure(response)
        #expect(refusal.mismatched == [file])

        // A source that exists but is the wrong shape would be accepted, never
        // produce anything, and read as broken — so nothing was written.
        #expect(library.preferences.sources.isEmpty)
        #expect(try library.store.all().isEmpty)
    }

    @Test("A folder added as a file refuses the batch the same way")
    func aFolderAddedAsAFileIsRefused() async throws {
        let library = try Library()
        let folder = library.path(of: library.folder("directory"))

        let response = try await library.post(#"[{"kind": "file", "path": "\#(folder)"}]"#)
        #expect(response.status == 400)
        #expect(try failure(response).mismatched?.count == 1)
        #expect(library.preferences.sources.isEmpty)
    }

    @Test("Recursion on a file source is refused at add, exactly as PATCH refuses it")
    func recursionOnAFileIsRefusedAtAdd() async throws {
        let library = try Library()
        let folder = library.folder("real", photographs: 1)
        let file = library.path(of: folder.appending(path: "photo-0.png"))

        // PATCH refuses this with 400; silently dropping the option at POST
        // would make the two verbs disagree about whether it is an error.
        let response = try await library.post(
            #"[{"kind": "file", "path": "\#(file)", "recursive": true}]"#)
        #expect(response.status == 400)
        #expect(try failure(response).error == "a file source has no recursive option")
        #expect(library.preferences.sources.isEmpty)
    }

    @Test("Adding the same folder twice is not an error, and does not add it twice")
    func addingTwiceIsNotAnError() async throws {
        let library = try Library()
        let folder = library.path(of: library.folder("repeat"))
        _ = try await library.post(#"[{"path": "\#(folder)"}]"#)
        let second = try await library.post(#"[{"path": "\#(folder)"}]"#)

        // 200 rather than 201: nothing was created, and saying `Created` would
        // be a lie a client might act on.
        #expect(second.status == 200)
        #expect(try sources(second).isEmpty)
        #expect(library.preferences.sources.count == 1)
        #expect(try library.store.all().count == 1)
    }

    @Test("A kind with no provider is refused rather than accepted and never scanned")
    func unsupportedKindIsRefused() async throws {
        let library = try Library()
        let response = try await library.post(
            """
            [{"kind": "photos_collection", "path": "some-album-identifier"}]
            """)

        #expect(response.status == 400)
        #expect(try failure(response).error == "photos_collection sources cannot be added")
        #expect(library.preferences.sources.isEmpty)
    }

    @Test("A body that is not an array of sources is a bad request, not a crash")
    func malformedBodiesAreRefused() async throws {
        let library = try Library()
        for body in ["", "{", #"{"path": "/tmp"}"#, "[1, 2, 3]", #"[{"kind": "folder"}]"#] {
            let response = try await library.post(body)
            #expect(response.status == 400, "body: \(body)")
            #expect(try failure(response).error.hasPrefix("expected a JSON array"))
        }
        #expect(library.preferences.sources.isEmpty)
    }

    @Test("An empty array asks for nothing and gets nothing, without complaint")
    func anEmptyArrayAddsNothing() async throws {
        let library = try Library()
        let response = try await library.post("[]")
        #expect(response.status == 200)
        #expect(try sources(response).isEmpty)
        #expect(library.preferences.sources.isEmpty)
    }

    // MARK: - Changing the options it was added with

    @Test("Recursion is switched off through the uuid, and the answer says so")
    func recursionIsChanged() async throws {
        let library = try Library()
        let folder = library.folder("nested", photographs: 1)
        let created = try sources(
            try await library.post(
                """
                [{"path": "\(library.path(of: folder))", "recursive": true}]
                """))
        let uuid = try #require(created.first?.uuid)

        let response = try await library.patch(
            #"{"recursive": false}"#, to: "\(SourceEndpoint.path)/\(uuid)")

        #expect(response.status == 200)
        let updated = try source(response)
        #expect(updated.uuid == uuid, "the source kept its identity rather than being replaced")
        #expect(updated.recursive == false)
        // The durable list is what a change has to land in; the row is the
        // projection of it.
        #expect(library.preferences.sources.first?.recursive == false)
        #expect(try library.store.source(uuid: uuid)?.recursive == false)
    }

    @Test("And back on again, without the source losing anything")
    func recursionGoesBothWays() async throws {
        let library = try Library()
        let folder = library.folder("flat")
        let uuid = try #require(
            try sources(try await library.post(#"[{"path": "\#(library.path(of: folder))"}]"#))
                .first?.uuid)

        _ = try await library.patch(
            #"{"recursive": true}"#, to: "\(SourceEndpoint.path)/\(uuid)")
        #expect(try library.store.source(uuid: uuid)?.recursive == true)

        let off = try await library.patch(
            #"{"recursive": false}"#, to: "\(SourceEndpoint.path)/\(uuid)")
        #expect(try source(off).recursive == false)
        #expect(try library.store.all().count == 1)
    }

    @Test("A file source has no recursion to change, and is told so")
    func aFileCannotBeMadeRecursive() async throws {
        let library = try Library()
        let folder = library.folder("pinned", photographs: 1)
        let file = folder.appending(path: "photo-0.png").path(percentEncoded: false)
        let uuid = try #require(
            try sources(try await library.post(#"[{"kind": "file", "path": "\#(file)"}]"#))
                .first?.uuid)

        let response = try await library.patch(
            #"{"recursive": true}"#, to: "\(SourceEndpoint.path)/\(uuid)")
        #expect(response.status == 400)
        #expect(try failure(response).error == "a file source has no recursive option")
    }

    @Test("A change that asks for nothing is refused rather than answered with a lie")
    func anEmptyChangeIsRefused() async throws {
        let library = try Library()
        let folder = library.folder("unchanged")
        let uuid = try #require(
            try sources(try await library.post(#"[{"path": "\#(library.path(of: folder))"}]"#))
                .first?.uuid)

        let response = try await library.patch("{}", to: "\(SourceEndpoint.path)/\(uuid)")
        #expect(response.status == 400)
        #expect(try failure(response).error == "no change was asked for")
    }

    @Test("Changing something that is not there is 404, and a bad body is 400")
    func changingWhatIsNotThere() async throws {
        let library = try Library()
        let missing = try await library.patch(
            #"{"recursive": true}"#,
            to: "\(SourceEndpoint.path)/\(UUID().uuidString.lowercased())")
        #expect(missing.status == 404)

        let folder = library.folder("real")
        let uuid = try #require(
            try sources(try await library.post(#"[{"path": "\#(library.path(of: folder))"}]"#))
                .first?.uuid)
        let garbage = try await library.patch("not json", to: "\(SourceEndpoint.path)/\(uuid)")
        #expect(garbage.status == 400)
        #expect(try failure(garbage).error.hasPrefix("expected a JSON object"))
    }

    @Test("A change is a member verb, and the collection refuses it")
    func patchingTheCollectionIsRefused() async throws {
        let library = try Library()
        let response = try await library.patch(#"{"recursive": true}"#, to: SourceEndpoint.path)
        #expect(response.status == 405)
    }

    // MARK: - Removing

    @Test("Removing takes the source out of preferences, the table, and the pool")
    func removeASource() async throws {
        let library = try Library()
        let folder = library.folder("doomed", photographs: 4)
        let created = try sources(
            try await library.post(#"[{"path": "\#(library.path(of: folder))"}]"#))
        let uuid = try #require(created.first?.uuid)
        let identifier = try #require(try library.store.source(uuid: uuid)).id
        for source in try library.store.all() { _ = await library.store.refresh(source) }
        #expect(try library.store.pool.size(forSource: identifier) == 4)

        let response = try await library.delete("\(SourceEndpoint.path)/\(uuid)")
        #expect(response.status == 204)

        #expect(library.preferences.sources.isEmpty)
        #expect(try library.store.all().isEmpty)
        #expect(try library.store.pool.size(forSource: identifier) == 0)
        // Removal is not deletion: the folder and its files are untouched.
        #expect(FileManager.default.fileExists(atPath: library.path(of: folder)))
    }

    @Test("Removing one leaves the others where they were")
    func removeIsNarrow() async throws {
        let library = try Library()
        let paths = ["keep", "drop"].map { library.path(of: library.folder($0)) }
        let created = try sources(
            try await library.post(
                "[" + paths.map { #"{"path": "\#($0)"}"# }.joined(separator: ",") + "]"))

        _ = try await library.delete(
            "\(SourceEndpoint.path)/\(try #require(created.last?.uuid))")

        #expect(library.preferences.sources.map(\.locator) == [paths[0]])
        #expect(try library.store.all().map(\.locator) == [paths[0]])
    }

    @Test("Removing something that is not there is 404, and changes nothing")
    func removingAnUnknownSourceIsNotFound() async throws {
        let library = try Library()
        let folder = library.path(of: library.folder("kept"))
        _ = try await library.post(#"[{"path": "\#(folder)"}]"#)

        let response = try await library.delete(
            "\(SourceEndpoint.path)/\(UUID().uuidString.lowercased())")
        #expect(response.status == 404)
        #expect(library.preferences.sources.count == 1)
    }

    // MARK: - The shape of the surface

    @Test("Only the four verbs are served, and the rest are told which they are not")
    func otherMethodsAreRefused() async throws {
        let library = try Library()
        let folder = library.path(of: library.folder("shape"))
        let uuid = try #require(
            try sources(try await library.post(#"[{"path": "\#(folder)"}]"#)).first?.uuid)

        // Adding is a collection verb; removing is a member verb. Neither works
        // where the other belongs.
        let postToMember = try await library.post("[]", to: "\(SourceEndpoint.path)/\(uuid)")
        #expect(postToMember.status == 405)
        let deleteTheCollection = try await library.delete(SourceEndpoint.path)
        #expect(deleteTheCollection.status == 405)
    }

    @Test("A trailing slash is the collection, not a source with an empty name")
    func trailingSlashIsTheCollection() async throws {
        let library = try Library()
        let response = try await library.get(SourceEndpoint.path + "/")
        #expect(response.status == 200)
        #expect(try sources(response).isEmpty)
    }

    @Test("The router sends source paths here and everything else to the pictures")
    func theRouterSplitsOnThePath() {
        #expect(SourceEndpoint.claims("/v1/sources"))
        #expect(SourceEndpoint.claims("/v1/sources/"))
        #expect(SourceEndpoint.claims("/v1/sources/abc-123"))
        #expect(!SourceEndpoint.claims("/v1/next"))
        // Not a source route: the prefix has to end at a boundary, or
        // `/v1/sourcesomething` would arrive here.
        #expect(!SourceEndpoint.claims("/v1/sourcesomething"))

        #expect(SourceEndpoint.identifier(in: "/v1/sources") == nil)
        #expect(SourceEndpoint.identifier(in: "/v1/sources/") == nil)
        #expect(SourceEndpoint.identifier(in: "/v1/sources/abc-123") == "abc-123")
        #expect(SourceEndpoint.identifier(in: "/v1/sources/abc-123/") == "abc-123")
    }

    // MARK: - What it says it did

    @Test("Every request produces exactly one record, including the ones refused")
    func oneRecordPerRequest() async throws {
        let library = try Library()
        let folder = library.path(of: library.folder("logged"))

        _ = try await library.get(SourceEndpoint.path)
        _ = try await library.post(#"[{"path": "\#(folder)"}]"#)
        _ = try await library.post(#"[{"path": "/nowhere"}]"#)
        _ = try await library.delete("\(SourceEndpoint.path)/\(UUID().uuidString)")

        let records = library.log.all
        #expect(records.count == 4)
        #expect(records.map(\.status) == [200, 201, 400, 404])
        #expect(records.map(\.method) == ["GET", "POST", "POST", "DELETE"])
        #expect(records.allSatisfy { $0.milliseconds >= 0 })
        // The refusal says which path was missing, because that is the fact
        // somebody reading the console needs.
        #expect(records[2].detail.contains("/nowhere"))
    }
}
