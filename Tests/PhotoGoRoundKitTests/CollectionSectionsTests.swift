import Foundation
import Testing

@testable import PhotoGoRoundKit

/// How the picker groups and orders what the library hands back.
///
/// These are the judgment calls the `PhotoLibrary` seam exists to make
/// testable: every one of them runs with no library, no TCC grant, and no
/// PhotoKit type in sight.
@Suite("Collections, in the sections Photos uses")
struct CollectionSectionsTests {

    private static func collection(
        _ title: String, _ kind: LibraryCollectionKind, count: Int? = nil
    ) -> LibraryCollection {
        LibraryCollection(
            identifier: "ID-\(title)", title: title, kind: kind, count: count)
    }

    // MARK: - Which section a kind belongs to

    @Test("Every kind lands in exactly one section, and none is left unplaced")
    func everyKindIsPlaced() {
        // `CaseIterable` is the point: a kind added later fails to compile
        // rather than quietly falling into a default.
        for kind in LibraryCollectionKind.allCases {
            #expect(LibrarySection.allCases.contains(kind.section))
        }
    }

    @Test("Media types are their own section rather than miscellany")
    func mediaTypesAreNotUtilities() {
        #expect(LibraryCollectionKind.mediaType.section == .mediaTypes)
        #expect(LibraryCollectionKind.mediaType.section != .utilities)
    }

    @Test("Shared albums and Photo Stream are Sharing")
    func sharingIsSharing() {
        #expect(LibraryCollectionKind.sharedAlbum.section == .sharing)
        #expect(LibraryCollectionKind.photoStream.section == .sharing)
    }

    /// Photos puts these three above its sections, in a group with no heading.
    /// There is no fifth group here, and hiding the three things a person is
    /// most likely to want would be worse than placing them.
    @Test("Library, Favorites and Recents go in Albums, where Photos has no section for them")
    func theHomelessThreeGoInAlbums() {
        #expect(LibraryCollectionKind.wholeLibrary.section == .albums)
        #expect(LibraryCollectionKind.favorites.section == .albums)
        #expect(LibraryCollectionKind.recentlyAdded.section == .albums)
    }

    @Test("Imports and Hidden are Utilities, as Photos files them")
    func utilitiesAreUtilities() {
        #expect(LibraryCollectionKind.imported.section == .utilities)
        #expect(LibraryCollectionKind.hidden.section == .utilities)
        #expect(LibraryCollectionKind.unableToUpload.section == .utilities)
    }

    /// A subtype Apple adds after this ships must appear somewhere. A
    /// collection a person can see in Photos and not here is a bug they cannot
    /// diagnose.
    @Test("A kind this build does not know is still listed")
    func theUnknownIsStillShown() {
        #expect(LibraryCollectionKind.otherSmartAlbum.section == .utilities)
    }

    // MARK: - Grouping

    @Test("Sections come back in Photos' sidebar order, not in the order collections arrived")
    func sectionOrderIsFixed() {
        let groups = LibrarySectionGroup.grouped([
            Self.collection("Screenshots", .mediaType),
            Self.collection("Hidden", .hidden),
            Self.collection("Holiday", .userAlbum),
            Self.collection("Family", .sharedAlbum),
        ])
        #expect(groups.map(\.section) == [.albums, .sharing, .mediaTypes, .utilities])
    }

    @Test("A section nothing falls into is omitted rather than shown empty")
    func emptySectionsAreOmitted() {
        let groups = LibrarySectionGroup.grouped([Self.collection("Holiday", .userAlbum)])
        #expect(groups.count == 1)
        #expect(groups.first?.section == .albums)
    }

    @Test("Nothing at all is no sections, not four empty ones")
    func nothingIsNothing() {
        #expect(LibrarySectionGroup.grouped([]).isEmpty)
    }

    @Test("Within a section, collections sort by name")
    func sortedByName() {
        let groups = LibrarySectionGroup.grouped([
            Self.collection("Zermatt", .userAlbum),
            Self.collection("apples", .userAlbum),
            Self.collection("Barcelona", .userAlbum),
        ])
        #expect(groups.first?.collections.map(\.title) == ["apples", "Barcelona", "Zermatt"])
    }

    /// `localizedStandardCompare`, which is what the Finder does — so a person
    /// who numbered their albums sees them in the order they numbered them.
    @Test("Numbers in names sort the way a person reads them")
    func numbersSortNumerically() {
        let groups = LibrarySectionGroup.grouped([
            Self.collection("Album 10", .userAlbum),
            Self.collection("Album 2", .userAlbum),
        ])
        #expect(groups.first?.collections.map(\.title) == ["Album 2", "Album 10"])
    }

    @Test("Sorting is by name and not by count, however lopsided the counts are")
    func countDoesNotDecideOrder() {
        let groups = LibrarySectionGroup.grouped([
            Self.collection("Zermatt", .userAlbum, count: 9_000),
            Self.collection("Apples", .userAlbum, count: 1),
        ])
        #expect(groups.first?.collections.map(\.title) == ["Apples", "Zermatt"])
    }

    // MARK: - Counts

    @Test("A collection arrives uncounted, and counting is a separate act")
    func countingIsSeparate() {
        let uncounted = Self.collection("Holiday", .userAlbum)
        #expect(uncounted.count == nil)
        #expect(uncounted.counted(12).count == 12)
    }

    /// Zero and "not counted yet" are different answers and the picker will
    /// draw them differently — one is an empty album, the other is a number
    /// still on its way.
    @Test("Zero is a count; nil is the absence of one")
    func zeroIsNotAbsence() {
        #expect(Self.collection("Videos", .mediaType, count: 0).count == 0)
        #expect(Self.collection("Videos", .mediaType, count: 0).count != nil)
    }

    @Test("Counting keeps everything else about the collection")
    func countingChangesOnlyTheCount() {
        let before = Self.collection("Holiday", .userAlbum)
        let after = before.counted(7)
        #expect(after.identifier == before.identifier)
        #expect(after.title == before.title)
        #expect(after.kind == before.kind)
    }
}
