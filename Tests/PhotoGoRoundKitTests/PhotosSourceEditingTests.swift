import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// Admitting a source that is not a path.
///
/// The only part of the Photos work that is not additive. Everything the store
/// does to a request — refusing an unknown kind, resolving it, deciding on one
/// spelling for its locator — was written when every source was a path, and
/// each of those is the wrong question for an album identifier.
@Suite("A source that is not a path")
struct PhotosSourceEditingTests {

    private let album = "DAD90FB7-1F24-463E-8688-A8504D7283C7/L0/040"

    /// A preference suite of its own, thrown away afterwards, so a test never
    /// writes into a domain a real agent reads.
    private final class Scratch {
        let name = scratchSuiteName("photos-source")
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        var preferences: Preferences { Preferences(defaults: defaults) }

        deinit { discardScratchSuite(name) }
    }

    private func store(_ database: Database, library: FakePhotoLibrary) -> SourceStore {
        SourceStore(
            database: database,
            providers: [
                FolderSourceProvider(fileAccess: UnsandboxedFileAccess()),
                FileSourceProvider(fileAccess: UnsandboxedFileAccess()),
                PhotosCollectionSourceProvider(library: library),
            ])
    }

    private func resolvable() -> FakePhotoLibrary {
        FakePhotoLibrary(
            titles: [album: "Favorites"],
            assets: [album: [LibraryAsset(identifier: "ASSET-0/L0/001")]])
    }

    @Test("An album that resolves is added, and its identifier is stored untouched")
    func anAlbumCanBeAdded() async throws {
        let scratch = Scratch()
        let store = store(try TestLibrary().database, library: resolvable())

        let addition = try await store.add(
            [SourceRequest(kind: .photosCollection, path: album)], to: scratch.preferences)

        #expect(addition.added.count == 1)
        // **No trailing slash.** A folder gets one because a picker and a
        // command line spell the same directory two ways; an album identifier
        // has exactly one spelling already, and appending to it would store
        // something PhotoKit will never return.
        #expect(addition.added.first?.locator == album)
        #expect(scratch.preferences.sources.first?.locator == album)
        #expect(try store.all().first?.kind == .photosCollection)
    }

    @Test("The identifier survives the slashes PhotoKit puts in one")
    func slashesInsideAreNotPathSeparators() async throws {
        // `PHAssetCollection.localIdentifier` has the form `UUID/L0/040`. It is
        // opaque here: nothing standardizes it, `stat`s it, or asks whether it
        // is a directory.
        let scratch = Scratch()
        let store = store(try TestLibrary().database, library: resolvable())
        try await store.add(
            [SourceRequest(kind: .photosCollection, path: album)], to: scratch.preferences)

        let stored = try #require(try store.all().first)
        #expect(stored.locator == album)
        #expect(!stored.locator.hasSuffix("/"))
        #expect(stored.locator.contains("/L0/"))
    }

    @Test("An album that names nothing is refused, and says which one")
    func anUnknownAlbumIsRefused() async throws {
        let scratch = Scratch()
        let store = store(try TestLibrary().database, library: resolvable())

        await #expect(throws: SourceStore.EditFailure.locatorsNotFound(["NOPE/L0/040"])) {
            try await store.add(
                [SourceRequest(kind: .photosCollection, path: "NOPE/L0/040")],
                to: scratch.preferences)
        }
        #expect(scratch.preferences.sources.isEmpty)
        #expect(try store.all().isEmpty)
    }

    @Test("A library that cannot be read refuses rather than accepting blind")
    func anUnreadableLibraryRefuses() async throws {
        // Accepting an album nobody can see would store a source that is
        // reported unavailable forever — which is exactly what the refusal
        // exists to prevent.
        let scratch = Scratch()
        let denied = FakePhotoLibrary(
            authorization: .denied, titles: [album: "Favorites"], assets: [album: []])
        let store = store(try TestLibrary().database, library: denied)

        await #expect(throws: SourceStore.EditFailure.locatorsNotFound([album])) {
            try await store.add(
                [SourceRequest(kind: .photosCollection, path: album)], to: scratch.preferences)
        }
        #expect(scratch.preferences.sources.isEmpty)
    }

    @Test("One bad identifier refuses the whole batch, folders included")
    func allOrNoneSpansBothKinds() async throws {
        // The rule that already governs a batch of paths has to govern a mixed
        // one, or the library ends up in a state that depends on the order the
        // sources were typed in.
        let scratch = Scratch()
        let folder = TemporaryFolder()
        let store = store(try TestLibrary().database, library: resolvable())

        await #expect(throws: (any Error).self) {
            try await store.add(
                [
                    .folder(folder.path),
                    SourceRequest(kind: .photosCollection, path: album),
                    SourceRequest(kind: .photosCollection, path: "NOPE/L0/040"),
                ], to: scratch.preferences)
        }
        #expect(scratch.preferences.sources.isEmpty)
        #expect(try store.all().isEmpty)
    }

    @Test("A folder and an album can be added in one act")
    func mixedBatchesWork() async throws {
        let scratch = Scratch()
        let folder = TemporaryFolder()
        let store = store(try TestLibrary().database, library: resolvable())

        let addition = try await store.add(
            [.folder(folder.path), SourceRequest(kind: .photosCollection, path: album)],
            to: scratch.preferences)

        #expect(addition.added.count == 2)
        let kinds = Set(addition.added.map(\.kind))
        #expect(kinds == [.folder, .photosCollection])
        // One write, and therefore one doorbell, for both.
        #expect(scratch.preferences.sources.count == 2)
    }

    @Test("Recursion is refused for an album, as it is for a file")
    func albumsHaveNoRecursion() async throws {
        let scratch = Scratch()
        let store = store(try TestLibrary().database, library: resolvable())

        await #expect(throws: (any Error).self) {
            try await store.add(
                [SourceRequest(kind: .photosCollection, path: album, recursive: true)],
                to: scratch.preferences)
        }
        #expect(scratch.preferences.sources.isEmpty)
    }
}
