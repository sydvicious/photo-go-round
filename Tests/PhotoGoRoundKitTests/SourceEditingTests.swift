import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import PhotoGoRoundAgentAPI

/// The plumbing every source edit runs on, wherever the ask came from.
///
/// `pgr_ctl` calls this with the agent stopped and the service calls it for a
/// client that asked over HTTP, so these are the rules both of them inherit:
/// preferences are written first, the table is a projection reconciled from
/// them, and a batch is all-or-none.
@Suite("Editing sources")
struct SourceEditingTests {

    /// A throwaway defaults suite, so a test never writes into the preferences
    /// of whoever is running it. Torn down all three ways, because emptying the
    /// domain alone leaves a plist behind in `~/Library/Preferences`.
    private final class Scratch {
        let name = "com.sydpolk.photogoround.tests.\(UUID().uuidString)"
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        var preferences: Preferences { Preferences(defaults: defaults) }

        deinit {
            let defaults = UserDefaults(suiteName: name)
            defaults?.removePersistentDomain(forName: name)
            defaults?.removeSuite(named: name)
            let file = URL.homeDirectory.appending(path: "Library/Preferences/\(name).plist")
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Adding

    @Test("Adding writes preferences, and the row is the projection of that")
    func addWritesPreferencesAndProjects() throws {
        let scratch = Scratch()
        let folder = TemporaryFolder()
        let store = SourceStore(database: try TestLibrary().database)

        let addition = try store.add(
            [.folder(folder.path, recursive: true)], to: scratch.preferences)

        // Preferences are the durable half, and hold what the user chose.
        #expect(scratch.preferences.sources.map(\.locator) == [folder.path])
        #expect(scratch.preferences.sources.first?.recursive == true)

        // The row is the derived half, and carries the identity a client uses.
        #expect(addition.added.count == 1)
        #expect(addition.alreadyListed.isEmpty)
        let source = try #require(addition.added.first)
        #expect(source.locator == folder.path)
        #expect(source.kind == .folder)
        #expect(source.recursive == true)
        #expect(source.enabled)
        #expect(!source.uuid.isEmpty)
        #expect(try store.all().map(\.id) == [source.id])
    }

    @Test("A batch is one write, and every source in it lands")
    func addsABatch() throws {
        let scratch = Scratch()
        let one = TemporaryFolder()
        let two = TemporaryFolder()
        let three = TemporaryFolder()
        let store = SourceStore(database: try TestLibrary().database)

        let addition = try store.add(
            [.folder(one.path), .folder(two.path), .folder(three.path)], to: scratch.preferences)

        #expect(addition.added.map(\.locator) == [one.path, two.path, three.path])
        #expect(Set(scratch.preferences.sources.map(\.locator)) == [one.path, two.path, three.path])
        // Three sources, three uuids: identity is minted per row, never shared.
        #expect(Set(addition.added.map(\.uuid)).count == 3)
    }

    @Test("A file is a source in its own right, not a folder with one entry")
    func addsAFile() throws {
        let scratch = Scratch()
        let folder = TemporaryFolder()
        let file = folder.write("pinned.png")
        let store = SourceStore(database: try TestLibrary().database)

        let addition = try store.add(
            [.file(file.path(percentEncoded: false))], to: scratch.preferences)

        let source = try #require(addition.added.first)
        #expect(source.kind == .file)
        // Recursion is a folder's question, so a file carries no answer to it.
        #expect(source.recursive == nil)
    }

    // MARK: - All of them or none of them

    @Test("One missing path refuses the whole batch, and nothing is written")
    func aMissingPathRefusesEverything() throws {
        let scratch = Scratch()
        let real = TemporaryFolder()
        let store = SourceStore(database: try TestLibrary().database)
        let absent = "/nowhere/at/all"

        #expect(throws: SourceStore.EditFailure.pathsNotFound([absent])) {
            try store.add([.folder(real.path), .folder(absent)], to: scratch.preferences)
        }

        // The point of the rule: the good half of the batch is not left behind.
        #expect(scratch.preferences.sources.isEmpty)
        #expect(try store.all().isEmpty)
    }

    @Test("Every missing path is named, not only the first")
    func everyMissingPathIsNamed() throws {
        let scratch = Scratch()
        let store = SourceStore(database: try TestLibrary().database)
        do {
            try store.add(
                [.folder("/nowhere/one"), .folder("/nowhere/two")], to: scratch.preferences)
            Issue.record("a batch of two missing paths was accepted")
        } catch SourceStore.EditFailure.pathsNotFound(let paths) {
            #expect(paths == ["/nowhere/one", "/nowhere/two"])
        }
    }

    @Test("A kind with no provider is refused rather than added and never scanned")
    func unsupportedKindIsRefused() throws {
        let scratch = Scratch()
        let store = SourceStore(database: try TestLibrary().database)

        #expect(throws: SourceStore.EditFailure.unsupportedKind(.photosCollection)) {
            try store.add(
                [SourceRequest(kind: .photosCollection, path: "album-id")], to: scratch.preferences)
        }
        #expect(scratch.preferences.sources.isEmpty)
        #expect(try store.all().isEmpty)
    }

    // MARK: - Asking twice

    @Test("Adding the same folder twice adds it once, and says so")
    func duplicatesAreNotAnError() throws {
        let scratch = Scratch()
        let folder = TemporaryFolder()
        let store = SourceStore(database: try TestLibrary().database)

        let first = try store.add([.folder(folder.path)], to: scratch.preferences)
        let second = try store.add([.folder(folder.path)], to: scratch.preferences)

        #expect(first.added.count == 1)
        #expect(second.added.isEmpty)
        #expect(second.alreadyListed == [folder.path])
        #expect(scratch.preferences.sources.count == 1)
        #expect(try store.all().count == 1)
        // The same row, so nothing it holds — its uuid, its cache directory, its
        // photographs — was thrown away and re-minted.
        #expect(try store.all().first?.uuid == first.added.first?.uuid)
    }

    @Test("A batch of one new path and one already listed adds the new one")
    func aBatchCanBePartlyKnown() throws {
        let scratch = Scratch()
        let known = TemporaryFolder()
        let fresh = TemporaryFolder()
        let store = SourceStore(database: try TestLibrary().database)

        try store.add([.folder(known.path)], to: scratch.preferences)
        let addition = try store.add(
            [.folder(known.path), .folder(fresh.path)], to: scratch.preferences)

        #expect(addition.added.map(\.locator) == [fresh.path])
        #expect(addition.alreadyListed == [known.path])
    }

    // MARK: - Removing

    @Test("Removing drops it from preferences, from the table, and from the pool")
    func removeTakesThePhotographsWithIt() async throws {
        let scratch = Scratch()
        let folder = TemporaryFolder()
        folder.write("one.png")
        folder.write("two.png")
        let store = SourceStore(database: try TestLibrary().database)

        let source = try #require(
            try store.add([.folder(folder.path)], to: scratch.preferences).added.first)
        _ = await store.refresh(source)
        #expect(try store.pool.size(forSource: source.id) == 2)

        try store.remove(source, from: scratch.preferences)

        #expect(scratch.preferences.sources.isEmpty)
        #expect(try store.all().isEmpty)
        // By cascade, not by a second delete: the photographs were only ever the
        // source's, and nothing on disk was touched.
        #expect(try store.pool.size(forSource: source.id) == 0)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("A row that was never in preferences is still removed")
    func removesARowPreferencesNeverKnewAbout() throws {
        let scratch = Scratch()
        let folder = TemporaryFolder()
        let store = SourceStore(database: try TestLibrary().database)

        // Straight into the table, which is what a hand-written row or a
        // half-finished experiment leaves behind. Reconciling is what deletes
        // it, so removing has to work without a preferences entry to drop.
        let orphan = try store.add(kind: .folder, locator: folder.path)
        #expect(scratch.preferences.sources.isEmpty)

        try store.remove(orphan, from: scratch.preferences)
        #expect(try store.all().isEmpty)
    }

    @Test("Removing one leaves the others alone")
    func removeIsNarrow() throws {
        let scratch = Scratch()
        let one = TemporaryFolder()
        let two = TemporaryFolder()
        let store = SourceStore(database: try TestLibrary().database)

        let added = try store.add(
            [.folder(one.path), .folder(two.path)], to: scratch.preferences
        ).added
        try store.remove(added[0], from: scratch.preferences)

        #expect(scratch.preferences.sources.map(\.locator) == [two.path])
        #expect(try store.all().map(\.locator) == [two.path])
    }

    // MARK: - Naming one

    @Test("A source is found by the uuid it was minted with, not by its row id")
    func foundByUUID() throws {
        let scratch = Scratch()
        let folder = TemporaryFolder()
        let store = SourceStore(database: try TestLibrary().database)

        let source = try #require(
            try store.add([.folder(folder.path)], to: scratch.preferences).added.first)

        let found = try #require(try store.source(uuid: source.uuid))
        #expect(found.id == source.id)
        #expect(found.locator == folder.path)
        #expect(try store.source(uuid: UUID().uuidString.lowercased()) == nil)
    }
}
