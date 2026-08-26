import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import PhotoGoRoundAgentAPI

/// Filling the queue with photographs that can actually be shown.
///
/// The cold start on 2026-08-25, with the database deleted and the cache empty:
///
/// ```
/// 15:45:58  SERVE: nothing to show — out of cards, walked 0     → 204
/// 15:45:58  DEAL ×20   (all from one iCloud source)
/// 15:46:01  SERVE: nothing to show — out of cards, walked 20    → 204
/// ```
///
/// The queue filled correctly and instantly, and then the walk went through all
/// twenty cards and could serve none of them, because every card's bytes were
/// still coming over the wire. Nothing was broken; the user still saw nothing.
///
/// A photograph is servable without fetching when it is `referenced` — on the
/// boot volume, read in place — or when its original is already cached.
@Suite("The servable seed")
struct ServableSeedTests {

    /// A pool split between photographs that need fetching and photographs that
    /// do not, with the fetchable ones ordered *first* by shuffle key so an
    /// unbiased deal would take them.
    private func library(
        referenced: Int, materialized: Int
    ) throws -> (TestLibrary, sourceID: Int64) {
        let library = try TestLibrary()
        let source = try library.addSource()
        // Low shuffle keys, so these are what an ordinary deal reaches first.
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
        return (library, source)
    }

    @Test("The seed prefers photographs that need no fetching")
    func prefersReferencedPhotographs() throws {
        let (library, _) = try library(referenced: 5, materialized: 100)
        let deck = library.deck

        var taken: [String] = []
        while taken.count < 5 {
            guard
                let card = try deck.nextServableCandidate(settings: .default, resident: [])
            else { break }
            taken.append(card.storage.rawValue)
            _ = try deck.markShown(photoID: card.id)
            try deck.releaseClaim(photoID: card.id)
        }

        #expect(taken.count == 5, "the seed found \(taken.count) of 5 servable photographs")
        #expect(
            taken.allSatisfy { $0 == PhotoStorage.referenced.rawValue },
            "the seed dealt a photograph that would have needed fetching: \(taken)"
        )
    }

    /// The other half: a warm restart still holds originals for photographs that
    /// are `materialized`, and those are servable too.
    @Test("A cached original counts as servable even when the file is remote")
    func cachedOriginalsAreServable() throws {
        let (library, _) = try library(referenced: 0, materialized: 20)
        let cached = try #require(
            try library.database.first("SELECT uuid FROM photo LIMIT 1;") {
                try $0.string("uuid")
            }
        )

        // Nothing is referenced, so without the cache there is nothing to take.
        #expect(try library.deck.nextServableCandidate(settings: .default, resident: []) == nil)

        // With that one original held, it becomes the only servable card.
        let card = try #require(
            try library.deck.nextServableCandidate(settings: .default, resident: [cached])
        )
        #expect(card.uuid == cached)
    }

    @Test("A small servable set reshuffles rather than waiting for a window that cannot open")
    func aSmallServableSetEndsItsPass() throws {
        // **The wedge of 2026-08-26, reduced.** `PLAN.md`'s algorithm is a
        // disjunction — eligible when more than *w* deals have passed, *or*
        // when not yet dealt this pass — and the pass exists as a floor for the
        // one case the window cannot answer: a population small enough that
        // waiting never frees anybody.
        //
        // Asked `servableOnly`, the population that can cycle is the cached
        // one, not the library. Measuring the library instead said "445 is
        // plenty, wait" while the twenty photographs with bytes were all inside
        // the window — and nothing serves, so the ordinal never advances, so
        // the window never opens. Live: 445 dealable, a 223 window, 133 cached,
        // and every walk answering `nothing to show`.
        let (library, _) = try library(referenced: 0, materialized: 400)
        let cached = try library.database.all(
            "SELECT id, uuid FROM photo ORDER BY id LIMIT 20;"
        ) { (id: try $0.int64("id"), uuid: try $0.string("uuid")) }
        let resident = Set(cached.map(\.uuid))

        // Every cached photograph shown a moment ago, so the window refuses all
        // twenty. The other 380 are eligible but have no bytes.
        try library.setDealSeq(5_000)
        for photo in cached { try library.setLastDealt(photo.id, seq: 5_000) }

        let card = try #require(
            try library.deck.nextServableCandidate(settings: .default, resident: resident),
            "a servable set the window can never free must reshuffle, not wait")
        #expect(resident.contains(card.uuid))
    }

    /// An entirely remote library with an empty cache has nothing to prefer, and
    /// must say so rather than inventing something — that is what tells the
    /// caller to fall back to ordinary dealing.
    @Test("An all-remote library with a cold cache offers nothing")
    func nothingServableIsAnHonestAnswer() throws {
        let (library, _) = try library(referenced: 0, materialized: 50)
        #expect(try library.deck.nextServableCandidate(settings: .default, resident: []) == nil)
        // And the ordinary deal is unaffected, so the fallback has something.
        #expect(try library.deck.nextCandidate(settings: .default) != nil)
    }

    /// The preference must not leak into ordinary dealing, or a local folder
    /// would crowd out every network source for ever.
    @Test("Ordinary dealing is unchanged and still reaches remote photographs")
    func ordinaryDealingIsUnbiased() throws {
        let (library, _) = try library(referenced: 5, materialized: 95)
        let deck = library.deck

        var storages: [String] = []
        for _ in 0..<40 {
            guard let card = try deck.nextCandidate(settings: .default) else { break }
            storages.append(card.storage.rawValue)
            _ = try deck.markShown(photoID: card.id)
            try deck.releaseClaim(photoID: card.id)
        }

        let remote = storages.filter { $0 == PhotoStorage.materialized.rawValue }.count
        #expect(
            remote > 20,
            "only \(remote) of \(storages.count) ordinary deals were remote; the seed's preference leaked"
        )
    }

    /// The temp table is per connection and is cleared around every use, so one
    /// seed cannot leave a stale set behind for the next.
    @Test("A seed does not leave its servable set behind")
    func servableSetDoesNotPersist() throws {
        let (library, _) = try library(referenced: 0, materialized: 10)
        let uuid = try #require(
            try library.database.first("SELECT uuid FROM photo LIMIT 1;") {
                try $0.string("uuid")
            }
        )
        let deck = library.deck

        let first = try deck.nextServableCandidate(settings: .default, resident: [uuid])
        #expect(first != nil)
        try deck.releaseClaim(photoID: try #require(first).id)

        // Asked again with nothing resident, the previous set must not still be
        // in force.
        #expect(try deck.nextServableCandidate(settings: .default, resident: []) == nil)
    }
}
