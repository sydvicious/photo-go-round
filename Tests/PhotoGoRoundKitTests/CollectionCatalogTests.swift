import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// Listing is cheap and counting is not, so they happen at different times.
///
/// Every one of these runs against `FakePhotoLibrary` — no library, no grant,
/// and none of the 78 ms per collection that made this design necessary.
@Suite("The collection catalog")
struct CollectionCatalogTests {

    private static func library(
        _ named: [(id: String, title: String, kind: LibraryCollectionKind, photos: Int)],
        unresolvable: [(id: String, title: String)] = []
    ) -> FakePhotoLibrary {
        var titles: [String: String] = [:]
        var assets: [String: [LibraryAsset]] = [:]
        var collections: [LibraryCollection] = []
        for entry in named {
            titles[entry.id] = entry.title
            assets[entry.id] = (0..<entry.photos).map {
                LibraryAsset(identifier: "\(entry.id)-\($0)", pixelWidth: 1, pixelHeight: 1)
            }
            collections.append(
                LibraryCollection(identifier: entry.id, title: entry.title, kind: entry.kind))
        }
        // Listed but with no title behind it: a collection that stops resolving
        // between the listing and the count.
        for ghost in unresolvable {
            collections.append(
                LibraryCollection(identifier: ghost.id, title: ghost.title, kind: .userAlbum))
        }
        return FakePhotoLibrary(titles: titles, assets: assets, collections: collections)
    }

    private static func flatten(_ groups: [LibrarySectionGroup]) -> [LibraryCollection] {
        groups.flatMap(\.collections)
    }

    private static func find(
        _ title: String, in groups: [LibrarySectionGroup]
    ) -> LibraryCollection? {
        flatten(groups).first { $0.title == title }
    }

    // MARK: - Folders

    /// The point of the whole traversal: 31 titles in a real library of 439
    /// collections belong to more than one of them, and the folder is what
    /// Photos itself uses to tell them apart.
    @Test("A collection inside folders carries the path to it, outermost first")
    func foldersAreAttached() async throws {
        let library = FakePhotoLibrary(
            titles: ["A": "Christmas", "B": "Christmas"],
            assets: [:],
            collections: [
                LibraryCollection(identifier: "A", title: "Christmas", kind: .userAlbum),
                LibraryCollection(identifier: "B", title: "Christmas", kind: .userAlbum),
            ],
            folders: ["A": ["Family"], "B": ["Trips", "2024"]])
        let catalog = PhotosCollectionCatalog(library: library)

        let all = Self.flatten(await catalog.sections())
        let paths = all.map(\.folders)

        #expect(paths.contains(["Family"]))
        #expect(paths.contains(["Trips", "2024"]))
    }

    @Test("A collection at the top level carries no folders at all")
    func topLevelHasNoFolders() async throws {
        let catalog = PhotosCollectionCatalog(
            library: Self.library([(id: "A", title: "Holiday", kind: .userAlbum, photos: 1)]))

        #expect(Self.find("Holiday", in: await catalog.sections())?.folders.isEmpty == true)
    }

    /// Counting and the folder walk are separate passes over separate things,
    /// and a collection has to come out of both with what each gave it.
    @Test("Counting a collection does not lose the folder it is in")
    func countingKeepsTheFolder() async throws {
        let library = FakePhotoLibrary(
            titles: ["A": "Christmas"],
            assets: ["A": [LibraryAsset(identifier: "x", pixelWidth: 1, pixelHeight: 1)]],
            collections: [
                LibraryCollection(identifier: "A", title: "Christmas", kind: .userAlbum)
            ],
            folders: ["A": ["Family"]])
        let catalog = PhotosCollectionCatalog(library: library)

        _ = await catalog.sections()
        await catalog.countEverything()
        let christmas = Self.find("Christmas", in: await catalog.sections())

        #expect(christmas?.count == 1)
        #expect(christmas?.folders == ["Family"])
    }

    @Test("The first ask carries every name and no counts at all")
    func namesArriveFirst() async {
        let catalog = PhotosCollectionCatalog(
            library: Self.library([
                (id: "A", title: "Holiday", kind: .userAlbum, photos: 3),
                (id: "B", title: "Live Photos", kind: .mediaType, photos: 9),
            ]))

        let groups = await catalog.sections()
        let all = Self.flatten(groups)

        #expect(all.map(\.title) == ["Holiday", "Live Photos"])
        #expect(all.allSatisfy { $0.count == nil })
    }

    @Test("Sections are grouped and ordered on the way out")
    func groupedOnTheWayOut() async {
        let catalog = PhotosCollectionCatalog(
            library: Self.library([
                (id: "A", title: "Screenshots", kind: .mediaType, photos: 1),
                (id: "B", title: "Holiday", kind: .userAlbum, photos: 1),
                (id: "C", title: "Family", kind: .sharedAlbum, photos: 1),
            ]))

        let groups = await catalog.sections()

        #expect(groups.map(\.section) == [.albums, .sharing, .mediaTypes])
    }

    @Test("Counting fills the numbers in, and the names do not move")
    func countingFillsIn() async {
        let catalog = PhotosCollectionCatalog(
            library: Self.library([
                (id: "A", title: "Holiday", kind: .userAlbum, photos: 3),
                (id: "B", title: "Live Photos", kind: .mediaType, photos: 9),
            ]))

        _ = await catalog.sections()
        await catalog.countEverything()
        let all = Self.flatten(await catalog.sections())

        #expect(all.map(\.title) == ["Holiday", "Live Photos"])
        #expect(all.map(\.count) == [3, 9])
    }

    @Test("An empty collection counts zero rather than staying uncounted")
    func emptyCountsZero() async {
        let catalog = PhotosCollectionCatalog(
            library: Self.library([(id: "A", title: "Empty", kind: .userAlbum, photos: 0)]))

        _ = await catalog.sections()
        await catalog.countEverything()

        #expect(Self.flatten(await catalog.sections()).first?.count == 0)
    }

    /// Otherwise it is retried on every pass forever, which is 78 ms a time
    /// against a collection that is never going to answer.
    @Test("A collection that stops resolving is recorded as zero, not left to be retried")
    func theUnresolvableIsSettled() async {
        let catalog = PhotosCollectionCatalog(
            library: Self.library(
                [(id: "A", title: "Holiday", kind: .userAlbum, photos: 2)],
                unresolvable: [(id: "GHOST", title: "Gone")]))

        _ = await catalog.sections()
        await catalog.countEverything()
        let progress = await catalog.progress()

        #expect(progress == (counted: 2, total: 2))
        let ghost = Self.flatten(await catalog.sections()).first { $0.identifier == "GHOST" }
        #expect(ghost?.count == 0)
    }

    @Test("Progress is what has been counted against what there is to count")
    func progressReportsBoth() async {
        let catalog = PhotosCollectionCatalog(
            library: Self.library([
                (id: "A", title: "One", kind: .userAlbum, photos: 1),
                (id: "B", title: "Two", kind: .userAlbum, photos: 1),
            ]))

        _ = await catalog.sections()
        let before = await catalog.progress()
        await catalog.countEverything()
        let after = await catalog.progress()

        #expect(before.total == 2)
        #expect(after == (counted: 2, total: 2))
    }

    /// A count is kept across relistings — that is the whole point of caching
    /// it — but it must not outlive the collection it belongs to, or the
    /// dictionary grows for as long as somebody keeps reorganising.
    @Test("A collection that goes away takes its count with it")
    func countsDoNotOutliveTheirCollections() async {
        let full = Self.library([
            (id: "A", title: "Holiday", kind: .userAlbum, photos: 3),
            (id: "B", title: "Gone Soon", kind: .userAlbum, photos: 5),
        ])
        let catalog = PhotosCollectionCatalog(library: full)
        _ = await catalog.sections()
        await catalog.countEverything()
        #expect(await catalog.progress() == (counted: 2, total: 2))

        // The same catalog, told a smaller library.
        let smaller = Self.library([(id: "A", title: "Holiday", kind: .userAlbum, photos: 3)])
        let second = PhotosCollectionCatalog(library: smaller)
        _ = await second.sections()
        await second.countEverything()

        #expect(await second.progress() == (counted: 1, total: 1))
    }

    @Test("Counting twice does not re-ask for what is already known")
    func countingIsNotRepeated() async {
        let catalog = PhotosCollectionCatalog(
            library: Self.library([(id: "A", title: "Holiday", kind: .userAlbum, photos: 3)]))

        _ = await catalog.sections()
        await catalog.countEverything()
        // Nothing left uncounted, so this returns without asking the library
        // anything at all.
        await catalog.countEverything()

        #expect(await catalog.progress() == (counted: 1, total: 1))
        #expect(Self.flatten(await catalog.sections()).first?.count == 3)
    }

    @Test("A library with nothing in it is no sections and no counting")
    func anEmptyLibrary() async {
        let catalog = PhotosCollectionCatalog(library: Self.library([]))

        let groups = await catalog.sections()
        await catalog.countEverything()

        #expect(groups.isEmpty)
        #expect(await catalog.progress() == (counted: 0, total: 0))
    }
}
