import Foundation
import Testing

@testable import PhotosGoRoundAgentAPI

/// What a person is told a source and a photograph are called — in the agent's
/// log, on its dashboard, and in the headers a client reads.
@Suite("Naming sources and photographs")
struct SourceNamingTests {

    private func source(
        _ kind: SourceKind, _ locator: String, _ description: SourceDescription? = nil
    ) -> Source {
        Source(
            id: 6, uuid: "u", kind: kind, locator: locator, description: description,
            addedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("A folder and a file are named by their paths")
    func paths() {
        #expect(source(.folder, "/Volumes/Photos/2019").spokenName == "/Volumes/Photos/2019")
        #expect(source(.file, "/Users/me/Pinned.jpeg").spokenName == "/Users/me/Pinned.jpeg")
    }

    @Test("A Photos album is named by its folders, outermost first, then its title")
    func albumInFolders() {
        let album = source(
            .photosCollection, "A1B2/L0/040",
            SourceDescription(title: "Holiday", collectionKind: "userAlbum", folders: ["Trips", "2019"]))
        #expect(album.spokenName == "Photos › Trips › 2019 › Holiday")
    }

    @Test("A top-level album is named by its title alone")
    func topLevelAlbum() {
        let album = source(
            .photosCollection, "A1B2/L0/040",
            SourceDescription(title: "Favorites", collectionKind: "favorites"))
        #expect(album.spokenName == "Photos › Favorites")
    }

    /// An empty title is a real answer — Photos lets an album be untitled —
    /// and `Photos › ` with nothing after it reads as a line cut short.
    @Test("An untitled album says so")
    func untitledAlbum() {
        let album = source(
            .photosCollection, "A1B2/L0/040",
            SourceDescription(title: "", collectionKind: "userAlbum", folders: ["Trips"]))
        #expect(album.spokenName == "Photos › Trips › Untitled album")
    }

    @Test("A Photos source with no stored description is just Photos, never its identifier")
    func photosWithoutDescription() {
        #expect(source(.photosCollection, "A1B2/L0/040").spokenName == "Photos")
        #expect(source(.photosAsset, "C3D4/L0/001").spokenName == "Photos")
    }

    @Test("A kind this build has not been taught is named by its title, else its locator")
    func unknownKind() {
        let described = source(
            .googleAlbum, "AF1Qip", SourceDescription(title: "Family", collectionKind: "album"))
        #expect(described.spokenName == "Family")
        #expect(source(.googleAlbum, "AF1Qip").spokenName == "AF1Qip")
    }

    @Test("A photograph with a recorded name is named by it, with its identifier kept")
    func namedPhotograph() {
        let card = DeckCard(
            id: 1, uuid: "u", sourceID: 6, sourceUUID: "s", externalID: "C3D4/L0/001",
            storage: .materialized, dealSeq: nil, originalFilename: "IMG_0042.HEIC")
        #expect(card.spokenName == "IMG_0042.HEIC (C3D4/L0/001)")
    }

    /// Every folder photograph, and every line that named one before this
    /// existed: nothing about them changes.
    @Test("A photograph with no recorded name is named by its identifier, as before")
    func unnamedPhotograph() {
        let card = DeckCard(
            id: 1, uuid: "u", sourceID: 6, sourceUUID: "s", externalID: "2019/IMG_1.jpg",
            storage: .referenced, dealSeq: nil)
        #expect(card.spokenName == "2019/IMG_1.jpg")
    }
}
