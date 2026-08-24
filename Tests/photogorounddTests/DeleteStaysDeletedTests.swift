import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd

/// Deleting a source in the app, and it staying deleted.
///
/// Reported from a running library: the row went, the agent then said it was
/// refreshing the source it had just been told to forget, and it came back in
/// the panel. The `source` table is a projection of the durable list, so
/// anything that reconciles from a stale copy of that list re-creates what was
/// removed — which makes the agent's own loop the first suspect.
@Suite("A deleted source stays deleted")
struct DeleteStaysDeletedTests {

    private final class Library {
        let directory: URL
        let endpoint: SourceEndpoint
        let store: SourceStore
        let preferences: Preferences
        let folder: URL
        private let suite = "com.sydpolk.photogoround.tests.\(UUID().uuidString)"

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-del-\(UUID().uuidString)")
            folder = directory.appending(path: "photos")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<3 {
                FileManager.default.createFile(
                    atPath: folder.appending(path: "p\(index).png").path(percentEncoded: false),
                    contents: Data(repeating: 0xAB, count: 64))
            }

            let path = directory.appending(path: "photogoround.sqlite")
                .path(percentEncoded: false)
            let database = try Database(path: path)
            try Migrator.migrate(database)
            let bytes = PhotoStore(root: directory.appending(path: "cache"))
            store = SourceStore(database: database, bytes: bytes)
            preferences = Preferences(defaults: UserDefaults(suiteName: suite)!)
            endpoint = SourceEndpoint(
                databasePath: path, preferences: preferences, bytes: bytes, log: { _ in })
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
            let defaults = UserDefaults(suiteName: suite)
            defaults?.removePersistentDomain(forName: suite)
            defaults?.removeSuite(named: suite)
            try? FileManager.default.removeItem(
                at: URL.homeDirectory.appending(path: "Library/Preferences/\(suite).plist"))
        }

        func post(_ json: String) async throws -> HTTPListener.Response {
            let body = Data(json.utf8)
            return await endpoint.route(
                try #require(
                    HTTPListener.parse(
                        "POST /v1/sources HTTP/1.1\r\nContent-Length: \(body.count)", body: body)))
        }

        func delete(_ uuid: String) async throws -> HTTPListener.Response {
            await endpoint.route(
                try #require(HTTPListener.parse("DELETE /v1/sources/\(uuid) HTTP/1.1")))
        }

        func uuids() throws -> [String] { try store.all().map(\.uuid) }
    }

    /// The panel's own path: add, then delete by `uuid`.
    private func addThenDelete(_ library: Library, path: String) async throws {
        let created = try await library.post(#"[{"path": "\#(path)"}]"#)
        #expect(created.status == 201)
        let uuid = try #require(try library.uuids().first)
        #expect(try await library.delete(uuid).status == 204)
    }

    @Test("It is gone from the durable list as well as from the table")
    func deletingRemovesItFromBoth() async throws {
        let library = try Library()
        try await addThenDelete(library, path: library.folder.path(percentEncoded: false))

        #expect(try library.store.all().isEmpty)
        #expect(library.preferences.sources.isEmpty, "it is still in the list it is projected from")
    }

    /// **The one the report points at.** The agent reconciles the table against
    /// the durable list every thirty seconds and whenever the doorbell rings. If
    /// the delete left anything behind in that list, this is where the source
    /// comes back — and it comes back *scanning*, which is what was seen.
    @Test("The agent's next reconcile does not bring it back")
    func reconcilingDoesNotResurrectIt() async throws {
        let library = try Library()
        try await addThenDelete(library, path: library.folder.path(percentEncoded: false))

        let changes = try library.store.reconcile(with: library.preferences)
        #expect(changes.added == 0, "the reconcile re-created a source that was deleted")
        #expect(try library.store.all().isEmpty)
    }

    @Test("A path given with a trailing slash is deleted by the same path without one")
    func trailingSlashesDoNotStrand() async throws {
        let library = try Library()
        // What `NSOpenPanel` hands back for a directory.
        try await addThenDelete(library, path: library.folder.path(percentEncoded: false) + "/")

        #expect(library.preferences.sources.isEmpty)
        #expect(try library.store.reconcile(with: library.preferences).added == 0)
        #expect(try library.store.all().isEmpty)
    }

    /// **The one the report points at.** The agent's loop reads the durable
    /// list, then walks its sources for as long as that takes — minutes, over a
    /// network share. A source deleted during that walk used to come back at the
    /// reconcile, because the loop was reconciling against the list as it had
    /// been *before* the delete.
    ///
    /// It cannot now: reconciling reads the list itself, so there is no copy for
    /// anyone to hold. This asserts the shape rather than the timing, because a
    /// timing test here would be a race dressed up as an assertion.
    @Test("A reconcile after a delete reads the list as it now is, not as it was")
    func reconcilingCannotUseAStaleList() async throws {
        let library = try Library()
        let created = try await library.post(
            #"[{"path": "\#(library.folder.path(percentEncoded: false))"}]"#)
        #expect(created.status == 201)

        // What the loop would have been holding.
        let asItWas = library.preferences.sources
        #expect(asItWas.count == 1)

        let uuid = try #require(try library.uuids().first)
        #expect(try await library.delete(uuid).status == 204)

        // The loop reconciles. It has no way to pass `asItWas` — the public
        // call takes the preferences and reads them — so the delete stands.
        _ = try library.store.reconcile(with: library.preferences)

        #expect(try library.store.all().isEmpty)
        #expect(library.preferences.sources.isEmpty)
    }
}
