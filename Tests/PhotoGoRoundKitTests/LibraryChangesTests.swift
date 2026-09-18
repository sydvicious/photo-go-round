import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// Photographs added to and removed from the library since launch, by source:
/// counted where the rows are written, whichever way the change was noticed.
@Suite("Photographs added and removed since launch")
struct LibraryChangesTests {

    private struct Fixture {
        let folder: TemporaryFolder
        let cacheRoot: TemporaryFolder
        let library: TestLibrary
        let changes: LibraryChanges
        let errors = AgentErrors(recording: true)
        var store: SourceStore

        init(photos: [String], recording: Bool = true) throws {
            folder = TemporaryFolder(name: "pgr-changes-src")
            cacheRoot = TemporaryFolder(name: "pgr-changes-dst")
            for name in photos { folder.write(name, bytes: 2048) }
            library = try TestLibrary()
            changes = LibraryChanges(recording: recording)
            store = SourceStore(database: library.database, changes: changes)
            store.errors = errors
        }

        func addFolder() async throws -> Source {
            let source = try store.add(kind: .folder, locator: folder.path)
            _ = await store.refresh(source)
            return source
        }
    }

    @Test("A refresh counts what it adds and what it no longer finds, against its source")
    func refreshIsCounted() async throws {
        let fixture = try Fixture(photos: ["a.png", "b.png", "c.png"])
        let source = try await fixture.addFolder()
        #expect(fixture.changes.bySource == [source.id: .init(added: 3)])

        fixture.folder.remove("b.png")
        fixture.folder.write("d.png", bytes: 2048)
        _ = await fixture.store.refresh(source)
        #expect(fixture.changes.bySource == [source.id: .init(added: 4, removed: 1)])

        // Finding the same photographs again is not a change.
        _ = await fixture.store.refresh(source)
        #expect(fixture.changes.bySource == [source.id: .init(added: 4, removed: 1)])
    }

    @Test("Removing a source counts its photographs as removed, and keeps what it was called")
    func sourceRemovalIsCounted() async throws {
        let fixture = try Fixture(photos: ["a.png", "b.png"])
        let source = try await fixture.addFolder()

        try await fixture.store.remove(id: source.id)

        #expect(fixture.changes.bySource == [source.id: .init(added: 2, removed: 2)])
        #expect(fixture.changes.nameOfRemovedSource(source.id) == source.spokenName)
    }

    @Test("A photograph its source confirms gone when fetched is counted as removed")
    func goneAtFetchIsCounted() async throws {
        let fixture = try Fixture(photos: ["a.png"])
        let source = try await fixture.addFolder()
        try fixture.library.database.run("UPDATE photo SET storage = 'materialized';")
        let cache = PhotoCache(
            database: fixture.library.database,
            root: fixture.cacheRoot.url.appending(path: "cache"), sources: fixture.store)
        try await cache.prepare()
        let photo = try #require(
            try fixture.library.database.first("SELECT id FROM photo LIMIT 1;") { try $0.int64("id") })

        fixture.folder.remove("a.png")
        #expect(try await cache.cache(photoID: photo) == false)

        #expect(fixture.changes.bySource == [source.id: .init(added: 1, removed: 1)])
    }

    @Test("Nothing is counted until recording starts")
    func silentUntilStarted() async throws {
        let fixture = try Fixture(photos: ["a.png"], recording: false)
        let source = try await fixture.addFolder()
        #expect(fixture.changes.bySource.isEmpty)

        fixture.changes.startRecording()
        fixture.folder.write("b.png", bytes: 2048)
        _ = await fixture.store.refresh(source)
        #expect(fixture.changes.bySource == [source.id: .init(added: 1)])
    }

    /// Nothing will report a removed source available again, or not empty, so
    /// its conditions would otherwise stand for the rest of the run.
    @Test("Removing a source clears its standing conditions, and nobody else's")
    func sourceRemovalClearsItsConditions() async throws {
        let fixture = try Fixture(photos: ["a.png"])
        let source = try await fixture.addFolder()
        let other = AgentErrors.kind("source.empty", source: source.id + 100)
        fixture.errors.record(
            kind: AgentErrors.kind("source.unavailable", source: source.id), "unavailable",
            lasting: .standing)
        fixture.errors.record(kind: other, "empty", lasting: .standing)

        try await fixture.store.remove(id: source.id)

        #expect(fixture.errors.entries.compactMap(\.kind) == [other])
    }

    /// Kept here beside removal, which is the same rule: a source nothing will
    /// refresh has nothing to clear its conditions.
    @Test("Disabling a source clears its standing conditions, and enabling it does not")
    func disablingClearsItsConditions() async throws {
        let fixture = try Fixture(photos: ["a.png"])
        let source = try await fixture.addFolder()
        let unavailable = AgentErrors.kind("source.unavailable", source: source.id)
        let other = AgentErrors.kind("source.empty", source: source.id + 100)
        fixture.errors.record(kind: unavailable, "unavailable", lasting: .standing)
        fixture.errors.record(kind: other, "empty", lasting: .standing)

        try fixture.store.setEnabled(true, for: source.id)
        #expect(Set(fixture.errors.entries.compactMap(\.kind)) == [unavailable, other])

        try fixture.store.setEnabled(false, for: source.id)
        #expect(fixture.errors.entries.compactMap(\.kind) == [other])
    }
}
