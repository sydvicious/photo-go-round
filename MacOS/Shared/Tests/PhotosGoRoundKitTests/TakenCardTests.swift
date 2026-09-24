import Foundation
import Testing

@testable import PhotosGoRoundKit
@testable import PhotosGoRoundAgentAPI

/// A served card is taken, and dealt off the client's path.
///
/// Since 2026-09-24 the pop is the only write a picture request waits for. The
/// card stays on the queue, marked taken, until `Deck.settle` deletes the row
/// and deals it — which is what keeps the filler from dealing it straight back
/// in the meantime. `SchemaV14`; `Plans/Startup Performance.md`.
@Suite("Taken cards")
struct TakenCardTests {

    private func count(_ sql: String, _ library: TestLibrary, id: Int64) throws -> Int {
        try library.database.scalarInt(sql, ["id": .int(id)]) ?? -1
    }

    private func timesShown(_ id: Int64, in library: TestLibrary) throws -> Int {
        try count("SELECT times_shown FROM photo WHERE id = :id;", library, id: id)
    }

    private func timesDelivered(_ id: Int64, in library: TestLibrary) throws -> Int {
        try count("SELECT times_delivered FROM photo WHERE id = :id;", library, id: id)
    }

    private func rows(_ id: Int64, in library: TestLibrary) throws -> Int {
        try count("SELECT COUNT(*) FROM queue WHERE photo_id = :id;", library, id: id)
    }

    @Test("A taken card is no longer waiting, and only one caller takes it")
    func takenIsNotWaiting() async throws {
        let (library, ids) = try TestLibrary.withPhotos(2)
        let queue = PhotoQueue(database: library.database)
        try #require(try queue.append(photoID: ids[0], sourceID: 1))
        try #require(try queue.append(photoID: ids[1], sourceID: 1))
        let head = try #require(try queue.peek().first)

        #expect(try await queue.take(photoID: head.id))
        #expect(try await !queue.take(photoID: head.id), "a second consumer goes round again")

        #expect(try queue.size() == 1)
        #expect(try queue.peek().first?.id != head.id)
        #expect(try !queue.contains(photoID: head.id))
        #expect(try rows(head.id, in: library) == 1, "the row stays until the deal")
    }

    /// **The race the row closes.** The candidate query excludes what is on
    /// the queue and what was dealt within the window. A card popped and not
    /// yet dealt was neither.
    @Test("A taken card cannot be dealt again until its deal is written")
    func takenIsNotDealtAgain() async throws {
        let (library, ids) = try TestLibrary.withPhotos(1)
        let queue = PhotoQueue(database: library.database)
        let photo = ids[0]
        try #require(try queue.append(photoID: photo, sourceID: 1))
        try #require(try await queue.take(photoID: photo))

        #expect(try library.deck.nextCandidate(settings: .default) == nil)
        #expect(try !queue.append(photoID: photo, sourceID: 1))

        try await library.deck.settle(Deck.Settlement(dealing: photo))
        #expect(try rows(photo, in: library) == 0)
    }

    @Test("Settling deals the card, counts its delivery, and marks the consumer seen")
    func settleWritesAllThree() async throws {
        let (library, ids) = try TestLibrary.withPhotos(1)
        let queue = PhotoQueue(database: library.database)
        let photo = ids[0]
        try #require(try queue.append(photoID: photo, sourceID: 1))
        try #require(try await queue.take(photoID: photo))

        let seq = try await library.deck.settle(
            Deck.Settlement(
                dealing: photo, delivered: photo, consumer: .screensaver, displayID: "DISPLAY"))

        #expect(seq == 1)
        #expect(try timesShown(photo, in: library) == 1)
        #expect(try timesDelivered(photo, in: library) == 1)
        #expect(try rows(photo, in: library) == 0)
        #expect(try library.deck.consumer(kind: .screensaver, displayID: "DISPLAY") != nil)
    }

    /// The deal and the delivery are two settlements in the agent: the deal
    /// the moment the card is taken, the delivery when the request ends.
    @Test("A delivery settled on its own deals nothing")
    func deliveryAlone() async throws {
        let (library, ids) = try TestLibrary.withPhotos(1)
        let photo = ids[0]

        let seq = try await library.deck.settle(
            Deck.Settlement(delivered: photo, consumer: .wallpaper))

        #expect(seq == nil)
        #expect(try timesShown(photo, in: library) == 0)
        #expect(try timesDelivered(photo, in: library) == 1)
        #expect(try library.database.scalarInt("SELECT deal_seq FROM deck_state WHERE id = 1;") == 0)
        #expect(try library.deck.consumer(kind: .wallpaper, displayID: nil) != nil)
    }

    @Test("A card left taken by an agent that stopped is dealt at launch, not delivered")
    func abandonedAreDealt() async throws {
        let (library, ids) = try TestLibrary.withPhotos(3)
        let queue = PhotoQueue(database: library.database)
        for id in ids { try #require(try queue.append(photoID: id, sourceID: 1)) }
        try #require(try await queue.take(photoID: ids[0]))
        try #require(try await queue.take(photoID: ids[1]))

        #expect(try library.deck.settleAbandoned() == 2)

        #expect(try queue.taken().isEmpty)
        #expect(try queue.size() == 1, "the card still waiting is left alone")
        for id in ids.prefix(2) {
            #expect(try timesShown(id, in: library) == 1)
            #expect(try timesDelivered(id, in: library) == 0)
        }
        #expect(try timesShown(ids[2], in: library) == 0)
    }
}
