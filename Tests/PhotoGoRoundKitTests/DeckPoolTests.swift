import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// **The deck's pool is what can be shown right now, and nothing else.**
///
/// This suite replaces `ServableSeedTests`, which asserted the same property
/// from the other side: the deck used to deal from the whole library and a
/// *seed* preferred the photographs that happened to be servable, for the first
/// tick after launch only. The preference is now the rule, so the seed, its
/// temp table, and its startup-only fencing are all gone — but four of the six
/// things that suite proved are still true and still worth holding down.
///
/// The one assertion deliberately *not* carried over is "ordinary dealing is
/// unchanged and still reaches remote photographs". It is exactly false now,
/// and its inverse is `anAllRemoteLibraryWithAColdCacheDealsNothing` below.
@Suite("The deck's pool")
struct DeckPoolTests {

    /// A pool split between photographs that can be shown and photographs that
    /// cannot, with the unservable ones ordered *first* by shuffle key so an
    /// unfiltered deal would take them.
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
        // The cache has landed on the first `cached` remote assets.
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

    @Test("a photograph with no bytes is not in the pool")
    func unservableIsInvisible() throws {
        let library = try library(referenced: 5, materialized: 100)

        // A hundred remote assets with the lowest shuffle keys, and the deck
        // does not know any of them exist.
        #expect(try library.deck.poolSize() == 5)

        for _ in 0..<20 {
            let card = try #require(try library.deck.nextCandidate(settings: .default))
            #expect(card.storage == .referenced, "dealt a photograph it cannot show")
            _ = try library.deck.markShown(photoID: card.id)
        }
    }

    @Test("a cached original counts as servable even though its source is remote")
    func cachedRemoteIsServable() throws {
        let library = try library(referenced: 0, materialized: 50, cached: 3)

        #expect(try library.deck.poolSize() == 3)

        let card = try #require(try library.deck.nextCandidate(settings: .default))
        #expect(card.storage == .materialized)
    }

    @Test("an all-remote library with a cold cache deals nothing")
    func anAllRemoteLibraryWithAColdCacheDealsNothing() throws {
        let library = try library(referenced: 0, materialized: 50)

        #expect(try library.deck.poolSize() == 0)
        // Honest rather than inventive. A card dealt here could not be served,
        // and the answer to an empty pool is the refresher, not a fallback.
        #expect(try library.deck.nextCandidate(settings: .default) == nil)
    }

    @Test("one landed download makes the deck deal exactly that photograph")
    func oneDownloadIsEnough() throws {
        let library = try library(referenced: 0, materialized: 50)
        #expect(try library.deck.nextCandidate(settings: .default) == nil)

        let uuid = try #require(
            try library.database.first(
                "SELECT uuid FROM photo ORDER BY id LIMIT 1;") { try $0.string("uuid") })
        try library.database.run(
            "UPDATE photo SET cached_at = 1 WHERE uuid = :uuid;", ["uuid": .text(uuid)])

        let card = try #require(try library.deck.nextCandidate(settings: .default))
        #expect(card.uuid == uuid)
    }

    @Test("a small servable set reshuffles rather than waiting for a window that cannot open")
    func aSmallServableSetEndsItsPass() throws {
        // **The wedge of 2026-08-26, and the reason it cannot come back.**
        //
        // The algorithm is a disjunction — eligible when more than *w* deals
        // have passed, *or* when not yet dealt this pass — and the pass is the
        // floor for the one case the window cannot answer: a population small
        // enough that waiting never frees anybody.
        //
        // The bug was that the population asked about was not the population
        // answered from. Measuring the whole library said "445 is plenty, so
        // waiting will open the window", while the 133 photographs that had
        // bytes were every one of them inside it — and nothing serves, so the
        // ordinal never advances, so the window never opens.
        //
        // v2 removes the mismatch by construction rather than by remembering to
        // pass a flag: there is only one population now, and it is the servable
        // one. This test is what says so out loud.
        let library = try library(referenced: 0, materialized: 400, cached: 20)
        let cached = try library.database.all(
            "SELECT id FROM photo WHERE cached_at IS NOT NULL ORDER BY id;"
        ) { try $0.int64("id") }
        #expect(cached.count == 20)

        // Every servable photograph shown a moment ago, so the window refuses
        // all twenty. The other 380 are eligible on recency and have no bytes.
        try library.setDealSeq(5_000)
        for id in cached { try library.setLastDealt(id, seq: 5_000) }

        // **Fraction 1.0, because that is the only setting at which the pass
        // does any work.** The window is then the whole pool by construction
        // and can never be satisfied, so the population is always within
        // `w + 1` and the pass is what releases a photograph. Below 1.0 the
        // window is half the pool, the pool is always larger than half of
        // itself plus one, and waiting genuinely does open it — which is why
        // this test used to need the servable set measured separately and now
        // does not.
        let settings = DeckSettings(repeatWindowFraction: 1.0)

        let card = try #require(
            try library.deck.nextCandidate(settings: settings),
            "a servable set the window can never free must reshuffle, not wait")
        #expect(cached.contains(card.id))
    }

    @Test("below 1.0 the deck waits, because serving will open the window")
    func belowOneItWaits() throws {
        // The other half of the rule, and the reason the wedge cannot come
        // back. Waiting is correct exactly when the population can free
        // somebody — and in v2 the population asked about and the population
        // answered from are the same set by construction, so the arithmetic
        // cannot disagree with itself the way it did on 2026-08-26.
        let library = try library(referenced: 0, materialized: 400, cached: 20)
        let cached = try library.database.all(
            "SELECT id FROM photo WHERE cached_at IS NOT NULL ORDER BY id;"
        ) { try $0.int64("id") }
        try library.setDealSeq(5_000)
        for id in cached { try library.setLastDealt(id, seq: 5_000) }

        // Twenty servable, a window of ten: eleven deals from now the oldest is
        // free again, so there is nothing to reshuffle for.
        #expect(try library.deck.nextCandidate(settings: .default) == nil)
    }

    @Test("the window is a fraction of what can be shown, not of what exists")
    func theWindowMeasuresThePool() throws {
        // The behaviour change a person actually feels: on a library much
        // larger than its cache, a photograph comes back after half the
        // *cache* rather than half the library.
        let library = try library(referenced: 0, materialized: 1_000, cached: 10)

        #expect(try library.deck.repeatWindow(settings: .default) == 5)
    }
}
