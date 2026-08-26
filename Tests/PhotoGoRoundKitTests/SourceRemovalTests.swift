import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import PhotoGoRoundAgentAPI

/// What happens to a photograph's *bytes* when the photograph stops belonging
/// to its source.
///
/// **A row without its bytes is a leak, and bytes without a row are worse.** The
/// rule these all check is one sentence: a photograph that is not supposed to be
/// there leaves the database and the cache together. It gets there two ways —
/// at serve time, where every picture is checked before any of it goes out, and
/// at removal time, where the rows are deleted deliberately.
///
/// Before this, both paths left the bytes behind for the next launch to notice
/// nothing claimed them, so removing a large source freed nothing until the
/// agent was restarted.
@Suite("Source removal and its bytes")
struct SourceRemovalTests {

    /// A throwaway defaults suite, so a test never writes into the preferences
    /// of whoever is running it.
    private final class Scratch {
        let name = "com.sydpolk.photogoround.tests.\(UUID().uuidString)"
        var preferences: Preferences { Preferences(defaults: UserDefaults(suiteName: name)!) }

        deinit {
            let defaults = UserDefaults(suiteName: name)
            defaults?.removePersistentDomain(forName: name)
            defaults?.removeSuite(named: name)
            try? FileManager.default.removeItem(
                at: URL.homeDirectory.appending(path: "Library/Preferences/\(name).plist"))
        }
    }

    /// A library whose photographs are materialized, so there really are bytes
    /// in the cache to account for.
    private struct Fixture {
        let folder: TemporaryFolder
        let cacheRoot: TemporaryFolder
        let library: TestLibrary
        let bytes: PhotoStore
        let store: SourceStore
        let cache: PhotoCache

        init(photos: [String] = [], nested: [String] = [], recursive: Bool = true) async throws {
            folder = TemporaryFolder(name: "pgr-removal-src")
            cacheRoot = TemporaryFolder(name: "pgr-removal-dst")
            for name in photos { folder.write(name, bytes: 4096) }
            for name in nested { folder.write("inside/\(name)", bytes: 4096) }

            library = try TestLibrary()
            bytes = PhotoStore(root: cacheRoot.url.appending(path: "cache"))
            store = SourceStore(database: library.database, bytes: bytes)
            cache = PhotoCache(
                database: library.database,
                root: cacheRoot.url.appending(path: "cache"),
                sources: store,
                store: bytes
            )
            try cache.prepare()
        }

        /// Adds the folder through the same call `pgr_ctl` and the service make.
        func add(to preferences: Preferences, recursive: Bool = true) throws -> Source {
            try #require(
                try store.add([.folder(folder.path, recursive: recursive)], to: preferences)
                    .added.first)
        }

        /// Fills the cache, so that what is on disk is real rather than assumed.
        func materialize(_ source: Source) async throws {
            _ = await store.refresh(source)
            try library.database.run("UPDATE photo SET storage = 'materialized';")
            _ = try await cache.fillCompletely()
        }

        /// What the cache is holding, counted from the index rather than from
        /// what anything claims it did.
        var held: Int64 { (try? cache.status())?.bytesOnDisk ?? 0 }

        var pooled: Int { (try? library.deck.poolSize()) ?? 0 }
    }

    // MARK: - Removing a source

    @Test("Removing a source deletes its photographs and their cached bytes")
    func removingASourceFreesItsBytes() async throws {
        let scratch = Scratch()
        let fixture = try await Fixture(photos: ["one.png", "two.png", "three.png"])
        let source = try fixture.add(to: scratch.preferences)
        try await fixture.materialize(source)

        #expect(try fixture.store.pool.size(forSource: source.id) == 3)
        let before = fixture.held
        #expect(before > 0, "nothing was cached, so this proves nothing about deleting it")

        let freed = try fixture.store.remove(source, from: scratch.preferences)

        #expect(try fixture.store.all().isEmpty)
        #expect(try fixture.store.pool.size(forSource: source.id) == 0)
        // The number it reported and the number that actually went.
        #expect(freed == before)
        #expect(fixture.held == 0)
        // And on disk, which is the claim that matters.
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.cache.root.appending(path: source.uuid)
                    .path(percentEncoded: false)))
        // Removal is not deletion: the photographs themselves are untouched.
        #expect(FileManager.default.fileExists(atPath: fixture.folder.path))
    }

    @Test("A source with nothing cached frees nothing, and says so rather than guessing")
    func removingAnEmptySourceFreesNothing() async throws {
        let scratch = Scratch()
        let fixture = try await Fixture(photos: ["one.png"])
        let source = try fixture.add(to: scratch.preferences)
        _ = await fixture.store.refresh(source)

        // Referenced, never copied — so there is nothing of ours to delete.
        #expect(try fixture.store.remove(source, from: scratch.preferences) == 0)
        #expect(try fixture.store.all().isEmpty)
    }

    @Test("A store with no byte index removes the rows and reports freeing nothing")
    func withoutAByteIndexNothingIsFreedAndItShows() async throws {
        let scratch = Scratch()
        let fixture = try await Fixture(photos: ["one.png", "two.png"])
        let source = try fixture.add(to: scratch.preferences)
        try await fixture.materialize(source)
        #expect(fixture.held > 0)

        // The same database, through a store that was handed no index. This is
        // the shape of a caller that forgot: the rows still go, and the zero is
        // how it announces itself rather than leaking quietly.
        let blind = SourceStore(database: fixture.library.database)
        #expect(try blind.remove(source, from: scratch.preferences) == 0)
        #expect(try blind.all().isEmpty)
    }

    // MARK: - Recursion, which is the same rule in another spelling

    @Test("Turning recursion off drops the nested photographs and their bytes when reached")
    func recursionOffDropsNestedPhotographs() async throws {
        let scratch = Scratch()
        let fixture = try await Fixture(photos: ["top.png"], nested: ["deep.png"])
        let source = try fixture.add(to: scratch.preferences, recursive: true)
        try await fixture.materialize(source)

        #expect(try fixture.store.pool.size(forSource: source.id) == 2)
        let before = fixture.held

        // The user unticks the box. Nothing on disk moved.
        let flat = try fixture.store.setRecursive(false, for: source, in: scratch.preferences)
        #expect(flat.recursive == false)

        // Serving is where it is noticed: the nested photograph is not in this
        // source any more, however healthily it sits on disk, so it is dropped
        // rather than shown — and its bytes go with it.
        var served: [String] = []
        while let next = try await fixture.cache.serve() { served.append(next.card.externalID) }

        #expect(served == ["top.png"])
        #expect(try fixture.store.pool.size(forSource: source.id) == 1)
        #expect(fixture.held < before)
    }

    @Test("A refresh drops them too, without waiting for anyone to ask for a picture")
    func recursionOffIsAlsoNoticedByARefresh() async throws {
        let scratch = Scratch()
        let fixture = try await Fixture(photos: ["top.png"], nested: ["deep.png", "deeper.png"])
        let source = try fixture.add(to: scratch.preferences, recursive: true)
        try await fixture.materialize(source)
        #expect(try fixture.store.pool.size(forSource: source.id) == 3)

        let flat = try fixture.store.setRecursive(false, for: source, in: scratch.preferences)
        let result = await fixture.store.refresh(flat)

        #expect(result.removed == 2)
        #expect(result.bytesFreed > 0)
        #expect(try fixture.store.pool.size(forSource: source.id) == 1)
    }

    @Test("Turning recursion back on finds them again at the next refresh")
    func recursionOnFindsThemAgain() async throws {
        let scratch = Scratch()
        let fixture = try await Fixture(photos: ["top.png"], nested: ["deep.png"])
        let source = try fixture.add(to: scratch.preferences, recursive: false)
        _ = await fixture.store.refresh(source)
        #expect(try fixture.store.pool.size(forSource: source.id) == 1)

        let deep = try fixture.store.setRecursive(true, for: source, in: scratch.preferences)
        _ = await fixture.store.refresh(deep)
        #expect(try fixture.store.pool.size(forSource: source.id) == 2)
    }

    @Test("Recursion is a folder's option, and a file source refuses it")
    func aFileHasNoRecursion() async throws {
        let scratch = Scratch()
        let fixture = try await Fixture(photos: ["one.png"])
        let file = fixture.folder.url.appending(path: "one.png").path(percentEncoded: false)
        let source = try #require(
            try fixture.store.add([.file(file)], to: scratch.preferences).added.first)

        #expect(throws: SourceStore.EditFailure.optionNotAvailable(option: "recursive", kind: .file)) {
            try fixture.store.setRecursive(true, for: source, in: scratch.preferences)
        }
    }

    // MARK: - Serving checks both halves

    @Test("An offline source with nothing cached is skipped, and nothing is deleted")
    func offlineAndUncachedIsSkippedNotDeleted() async throws {
        let scratch = Scratch()
        let fixture = try await Fixture(photos: ["one.png", "two.png"])
        let source = try fixture.add(to: scratch.preferences)
        _ = await fixture.store.refresh(source)
        // Referenced, so the bytes *are* the files on the source. Nothing of
        // ours is holding a copy.
        for _ in 0..<10 { _ = try await fixture.cache.fillCompletely() }
        #expect(fixture.pooled == 2)

        // The drive is unplugged: the folder is unreachable, which says nothing
        // at all about whether the photographs still exist.
        try fixture.library.database.run(
            "UPDATE source SET locator = :locator WHERE id = :id;",
            ["locator": "/Volumes/NotMounted/photos", "id": .int(source.id)]
        )

        // Nothing can be served, because nothing is readable — and that is the
        // whole of it. The rows stay, the deal history stays, and plugging the
        // drive back in restores everything.
        #expect(try await fixture.cache.serve() == nil)
        #expect(fixture.pooled == 2)
        #expect(try fixture.store.all().count == 1)
    }
}
