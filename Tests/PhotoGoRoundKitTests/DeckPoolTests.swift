import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// **The deck's pool is every available photograph, bytes or not, reachable
/// or not.**
///
/// Available means two things and only two: the source is enabled, and the
/// photograph is a still image. Residency is not one of them — that was the
/// rule from 2026-08-26 to 2026-09-05, and it paced a new source's arrival on
/// screen to the cache's download rate. Reachability is not one of them either:
/// it was tried on 2026-09-05 as a gate, then as a gate with a door for held
/// photographs, and taken out, because a held photograph serves from the cache
/// whatever its source is doing and an unheld one fails its fetch and is
/// dropped. See the plan's *Deal over everything, and the queue fetches its own
/// cards*.
///
/// This suite replaces the one that asserted residency as the gate. Two of its
/// cases — a servable subset ending its pass, and waiting below fraction 1.0 —
/// were about a population that no longer exists as a distinct thing; the pass
/// and window rules over the one population are held down in `DeckTests`.
@Suite("The deck's pool")
struct DeckPoolTests {

    /// A library split between photographs with bytes and photographs without,
    /// the ones without ordered *first* by shuffle key so a deal that filtered
    /// on residency would visibly avoid them.
    private func library(
        referenced: Int, materialized: Int, cached: Int = 0
    ) throws -> TestLibrary {
        let library = try TestLibrary()
        let source = try library.addSource()
        for index in 0..<materialized {
            try library.database.run(
                """
                INSERT INTO photo (uuid, source_id, external_id, media_type, source_enabled,
                                   storage, shuffle_key, added_at)
                VALUES (:uuid, :source, :external, 'image', 1, 'materialized', :key, 0);
                """,
                [
                    "uuid": .text(UUID().uuidString.lowercased()), "source": .int(source),
                    "external": .text("far-\(index).heic"),
                    "key": .double(Double(index) / Double(max(materialized, 1)) * 0.5),
                ]
            )
        }
        for index in 0..<referenced {
            try library.database.run(
                """
                INSERT INTO photo (uuid, source_id, external_id, media_type, source_enabled,
                                   storage, shuffle_key, added_at)
                VALUES (:uuid, :source, :external, 'image', 1, 'referenced', :key, 0);
                """,
                [
                    "uuid": .text(UUID().uuidString.lowercased()), "source": .int(source),
                    "external": .text("here-\(index).heic"),
                    "key": .double(0.5 + Double(index) / Double(max(referenced, 1)) * 0.5),
                ]
            )
        }
        if cached > 0 {
            try library.database.run(
                """
                UPDATE photo SET cached_at = 1
                 WHERE id IN (SELECT id FROM photo WHERE storage = 'materialized'
                               ORDER BY id LIMIT :limit);
                """,
                ["limit": .int(Int64(cached))])
        }
        return library
    }

    @Test("a photograph with no bytes is in the pool and is dealt")
    func unheldIsDealt() throws {
        let library = try library(referenced: 5, materialized: 100)

        #expect(try library.deck.poolSize() == 105)

        // A hundred cold cards with the lowest keys against five warm ones: a
        // deal blind to residency lands on a cold one nearly every time, and
        // twenty in a row landing warm would be one chance in ten billion.
        var storages: Set<PhotoStorage> = []
        for _ in 0..<20 {
            let card = try #require(try library.deck.nextCandidate(settings: .default))
            storages.insert(card.storage)
            _ = try library.deck.markShown(photoID: card.id)
        }
        #expect(storages.contains(.materialized), "never dealt a photograph without bytes")
    }

    @Test("an all-remote library with a cold cache deals")
    func aColdLibraryDeals() throws {
        // The case v2 answered with nothing. Now the first card is dealt at
        // once and the queue is what fetches it.
        let library = try library(referenced: 0, materialized: 50)

        #expect(try library.deck.poolSize() == 50)
        let card = try #require(try library.deck.nextCandidate(settings: .default))
        #expect(card.storage == .materialized)
    }

    @Test("caching a photograph changes nothing about whether it is dealt")
    func residencyIsNotAGate() throws {
        let library = try library(referenced: 0, materialized: 50, cached: 3)

        #expect(try library.deck.poolSize() == 50)
        #expect(try library.deck.unusedInCurrentPass() == 50)
    }

    @Test("an unreachable source is dealt like any other, held or not")
    func reachabilityIsNotAGate() throws {
        let library = try TestLibrary()
        let near = try library.addSource(locator: "/near")
        let far = try library.addSource(locator: "/far")
        let nearPhotos = Set(try library.addPhotos(4, to: near, namePrefix: "near"))
        let farHeld = Set(try library.addPhotos(2, to: far, namePrefix: "far-held"))
        let farCold = Set(try library.addPhotos(2, to: far, namePrefix: "far-cold", servable: false))

        // The scan marks the share unmounted. The deal does not read that
        // column: what we hold serves from the cache, and what we do not fails
        // its fetch and is dropped, so there is nothing for the deal to decide.
        try library.database.run(
            "UPDATE source SET available = 0 WHERE id = :id;", ["id": .int(far)])

        #expect(try library.deck.poolSize() == 8)
        #expect(try library.deck.repeatWindow(settings: .default) == 4)
        let dealt = Set(try library.drawSequence(count: 8, settings: DeckSettings(repeatWindowFraction: 1.0)))
        #expect(dealt == nearPhotos.union(farHeld).union(farCold))
    }

    @Test("the window is a fraction of the library, not of the cache")
    func theWindowMeasuresTheLibrary() throws {
        // The behaviour change a person feels, reversed from v2: on a library
        // much larger than its cache a photograph comes back after half the
        // *library*, whatever the cache holds.
        let library = try library(referenced: 0, materialized: 1_000, cached: 10)

        #expect(try library.deck.repeatWindow(settings: .default) == 500)
    }
}
