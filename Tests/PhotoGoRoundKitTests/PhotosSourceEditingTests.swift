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

    private func store(_ database: Database, library: any PhotoLibrary) -> SourceStore {
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

    // MARK: - The name beside the identifier

    @Test("Adding an album stores what it is called, in the row and in the preference")
    func anAlbumIsStoredWithItsName() async throws {
        // **The client sent the identifier and nothing else.** The agent was
        // already asking the library whether the album resolves, and the
        // name, the kind, and the folders come back in the same breath. One
        // writer for the fact; `pgr_ctl` and a hand-written `defaults write`
        // get the same name without knowing to ask.
        let scratch = Scratch()
        let library = FakePhotoLibrary(
            titles: [album: "Kids 2019"],
            assets: [album: [LibraryAsset(identifier: "ASSET-0/L0/001")]],
            collections: [
                LibraryCollection(identifier: album, title: "Kids 2019", kind: .userAlbum)
            ],
            folders: [album: ["Family", "Trips"]])
        let store = store(try TestLibrary().database, library: library)
        let expected = SourceDescription(
            title: "Kids 2019", collectionKind: "userAlbum", folders: ["Family", "Trips"])

        let addition = try await store.add(
            [SourceRequest(kind: .photosCollection, path: album)], to: scratch.preferences)

        #expect(addition.added.first?.description == expected)
        #expect(try store.all().first?.description == expected)
        #expect(scratch.preferences.sources.first?.description == expected)
        // And the entry reads back through the plist round trip, folders as an
        // array rather than a joined string.
        let entry = try #require(
            scratch.defaults.array(forKey: "sources")?.first as? [String: Any])
        #expect(entry["title"] as? String == "Kids 2019")
        #expect(entry["collectionKind"] as? String == "userAlbum")
        #expect(entry["folders"] as? [String] == ["Family", "Trips"])
    }

    @Test("A preference entry from before the name was stored still loads, nameless")
    func anOldEntryLoadsWithoutADescription() throws {
        let spec = try #require(
            SourceSpec(propertyList: ["kind": "photos_collection", "locator": album]))
        #expect(spec.description == nil)
        #expect(spec.locator == album)

        // And a folder's entry never grows the three keys: its path names it.
        let folder = SourceSpec.folder("/Pictures")
        #expect(folder.propertyList["title"] == nil)
        #expect(folder.propertyList["folders"] == nil)
    }

    @Test("A rebuilt database gets the name back from the preference, and a refresh renews it")
    func theRowIsSeededAndThenRenewed() async throws {
        // The preference carries the name the album had when it was added; the
        // library is asked again on every refresh that finds the album, so a
        // rename in Photos shows through without anybody re-adding anything.
        let scratch = Scratch()
        let renamed = FakePhotoLibrary(
            titles: [album: "Kids 2019 — Maine"],
            assets: [album: [LibraryAsset(identifier: "ASSET-0/L0/001")]],
            collections: [
                LibraryCollection(identifier: album, title: "Kids 2019 — Maine", kind: .userAlbum)
            ])
        scratch.preferences.setSources([
            SourceSpec(
                kind: .photosCollection, locator: album,
                description: SourceDescription(title: "Kids 2019", collectionKind: "userAlbum"))
        ])
        let store = store(try TestLibrary().database, library: renamed)

        try store.reconcile(with: scratch.preferences)
        let seeded = try #require(try store.all().first)
        #expect(seeded.description?.title == "Kids 2019", "the row is seeded from the preference")

        await store.refresh(seeded)
        let refreshed = try #require(try store.source(id: seeded.id))
        #expect(refreshed.description?.title == "Kids 2019 — Maine", "the refresh renewed it")
        #expect(
            scratch.preferences.sources.first?.description?.title == "Kids 2019",
            "the preference is the seed, not the record")
    }

    // MARK: - Reconnecting

    private static let renumbered = "REBUILT-0000-0000-0000-000000000000/L0/041"
    private static let kids = SourceDescription(
        title: "Kids 2019", collectionKind: "userAlbum", folders: ["Family"])

    /// The library after a rebuild: the stored album is gone and `successors`
    /// stand where it was, each called "Kids 2019" in the Family folder.
    private func rebuilt(successors: [String]) -> FakePhotoLibrary {
        FakePhotoLibrary(
            titles: Dictionary(uniqueKeysWithValues: successors.map { ($0, "Kids 2019") }),
            assets: Dictionary(
                uniqueKeysWithValues: successors.map {
                    ($0, [LibraryAsset(identifier: "NEW-\($0)/L0/001")])
                }),
            collections: successors.map {
                LibraryCollection(identifier: $0, title: "Kids 2019", kind: .userAlbum)
            },
            folders: Dictionary(uniqueKeysWithValues: successors.map { ($0, ["Family"]) }))
    }

    /// A source added before the rebuild, in preferences and in the table,
    /// with the name it had then.
    private func missingAlbum(
        in store: SourceStore, preferences: Preferences
    ) async throws -> Source {
        preferences.setSources([
            SourceSpec(kind: .photosCollection, locator: album, description: Self.kids)
        ])
        try store.reconcile(with: preferences)
        let source = try #require(try store.all().first)
        await store.refresh(source)
        return try #require(try store.source(id: source.id))
    }

    @Test("Reconnecting moves the row and the preference together, and keeps the source")
    func reconnectMovesBothAndKeepsTheSource() async throws {
        let scratch = Scratch()
        let store = store(try TestLibrary().database, library: rebuilt(successors: [Self.renumbered]))
        let before = try await missingAlbum(in: store, preferences: scratch.preferences)
        #expect(before.available == false, "the refresh could not find it")

        let after = try await store.reconnect(before, in: scratch.preferences)

        #expect(after.uuid == before.uuid, "the source is the same source")
        #expect(after.id == before.id)
        #expect(after.locator == Self.renumbered)
        #expect(after.available, "it is there now, and says so without waiting for a refresh")
        #expect(after.description == Self.kids)
        #expect(scratch.preferences.sources.map(\.locator) == [Self.renumbered])
        #expect(scratch.preferences.sources.first?.description == Self.kids)

        // The two agree, so reconciling adds and removes nothing — which is
        // the whole reason they were written under one lock.
        let reconciled = try store.reconcile(with: scratch.preferences)
        #expect(reconciled.isEmpty)
        #expect(try store.all().map(\.uuid) == [before.uuid])
    }

    @Test("Reconnecting with no successor changes nothing, and says so")
    func reconnectWithNoMatchIsRefused() async throws {
        let scratch = Scratch()
        let store = store(try TestLibrary().database, library: rebuilt(successors: []))
        let before = try await missingAlbum(in: store, preferences: scratch.preferences)

        await #expect(throws: SourceStore.EditFailure.notReconnectable(matches: [])) {
            try await store.reconnect(before, in: scratch.preferences)
        }
        #expect(try store.source(id: before.id)?.locator == album)
        #expect(scratch.preferences.sources.map(\.locator) == [album])
    }

    @Test("Reconnecting with two successors is refused, naming both")
    func reconnectWithTwoMatchesIsRefused() async throws {
        let scratch = Scratch()
        let store = store(
            try TestLibrary().database, library: rebuilt(successors: [Self.renumbered, "OTHER/L0/042"]))
        let before = try await missingAlbum(in: store, preferences: scratch.preferences)

        await #expect(
            throws: SourceStore.EditFailure.notReconnectable(matches: ["Kids 2019", "Kids 2019"])
        ) {
            try await store.reconnect(before, in: scratch.preferences)
        }
        #expect(try store.source(id: before.id)?.locator == album)
        #expect(try store.source(id: before.id)?.available == false)
    }

    @Test("An album that is there cannot be reconnected, and neither can a folder")
    func reconnectIsOnlyForMissingAlbums() async throws {
        let scratch = Scratch()
        let store = store(try TestLibrary().database, library: resolvable())
        let addition = try await store.add(
            [SourceRequest(kind: .photosCollection, path: album)], to: scratch.preferences)
        let present = try #require(addition.added.first)

        await #expect(throws: SourceStore.EditFailure.notMissing) {
            try await store.reconnect(present, in: scratch.preferences)
        }

        let folder = TemporaryFolder()
        let added = try await store.add(kind: .folder, locator: folder.path)
        await #expect(throws: SourceStore.EditFailure.notMissing) {
            try await store.reconnect(added, in: scratch.preferences)
        }
    }

    @Test("An album that has gone missing keeps the name it last had")
    func aMissingAlbumKeepsItsName() async throws {
        // The whole point: a refresh that cannot find the album marks the
        // source unavailable and touches nothing else, so the panel can still
        // say which album it is talking about.
        let store = store(
            try TestLibrary().database,
            library: FakePhotoLibrary(titles: [:]))
        let source = try store.add(
            kind: .photosCollection, locator: album,
            description: SourceDescription(title: "Kids 2019", collectionKind: "userAlbum"))

        let result = await store.refresh(source)
        let after = try #require(try store.source(id: source.id))

        #expect(result.sourceUnavailable)
        #expect(after.available == false)
        #expect(after.description?.title == "Kids 2019")
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

    /// **The case that sent this back for a second look.** Adding a collection
    /// on a machine migrating a large library timed out at the client while the
    /// agent was still asking the library about the album — and the agent, once
    /// it had a bound of its own, went on to refuse the album outright because a
    /// library that would not answer looked exactly like one saying the album
    /// was not there.
    ///
    /// A library that says nothing has said nothing about this album. The source
    /// is recorded, marked unavailable with the reason, and the refresh pass
    /// retries it for as long as it takes.
    @Test("A library that will not answer records the source rather than refusing it")
    func aSilentLibraryRecordsTheSource() async throws {
        let scratch = Scratch()
        let silent = SilentLibraryTests.stalling()
        let store = store(try TestLibrary().database, library: silent)

        let added = try await store.add(
            [SourceRequest(kind: .photosCollection, path: album)], to: scratch.preferences)

        #expect(added.added.count == 1)
        #expect(added.added.first?.locator == album)
        #expect(scratch.preferences.sources.count == 1)
        // No name yet — the library never said one. `refresh` writes it with the
        // first scan that works, so nothing is permanently lost by not having it.
        #expect(added.added.first?.description == nil)
    }

    /// **The picker adds every ticked album in one request**, so the bound has
    /// to be spent once for the batch rather than once per album. Twenty albums
    /// against a silent library used to mean twenty waits, which is how a `POST`
    /// gets far past any client's patience however patient the client is.
    @Test("A batch against a silent library costs one wait, not one per album")
    func silenceIsPaidForOnce() async throws {
        let scratch = Scratch()
        let store = store(try TestLibrary().database, library: SilentLibraryTests.stalling())
        let albums = (0..<8).map {
            SourceRequest(kind: .photosCollection, path: "ALBUM-\($0)/L0/040")
        }

        let clock = ContinuousClock()
        let started = clock.now
        let added = try await store.add(albums, to: scratch.preferences)
        let spent = clock.now - started

        #expect(added.added.count == 8)
        // Comfortably under eight waits, and above none — the point is that it
        // does not scale with the number of albums.
        #expect(spent < SourceStore.validationLimit * 3)
    }

    /// The other half, and the reason the two are told apart: a library that
    /// answers *you may not look* has answered. Accepting then would store a
    /// source reported unavailable for ever, over something the person can fix
    /// in System Settings.
    @Test("A silent library and a denied one are not the same refusal")
    func silenceAndDenialDiffer() async throws {
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
