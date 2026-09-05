import Foundation
import PhotoGoRoundAgentAPI

/// Pictures dealt by the deck and waiting to be shown, **each placed at random
/// among the cards already queued**.
///
/// The order is `rank`, since migration 10. A new card lands anywhere from
/// second to last — never at the head, so the card about to be shown is never
/// displaced and every new card has at least one picture of fetch lead — and
/// the ranks at and above its slot are shifted up by one to make room. At
/// twenty cards that is one trivial `UPDATE` per deal, and the order is exact
/// for ever; the `REAL` key that migration 6 used for the same purpose shrank
/// toward a tie and needed respacing to stay honest.
///
/// **Why not the tail.** It was, between migrations 8 and 10, and honestly so:
/// only one thing arrives, so there was one end. But a card dealt from a newly
/// added source then waited a whole traversal before anybody saw it — about
/// three and a half minutes at twenty cards and ten seconds a picture — where
/// the requirement is results in seconds or a few minutes. A shorter queue
/// would have shortened the traversal and was declined on 2026-09-05: a deep
/// queue is what keeps pictures coming when the sources are hostile. Random
/// placement gives a new source its first showing within a picture or two and
/// leaves the depth alone — more immediate feedback that adding something to
/// the set worked.
///
/// **Why not the head.** Tried on 2026-08-23: the order pictures appear in
/// becomes the order they were dealt in, and a burst of deals from one source
/// owns the front of the queue whatever its share of the library.
///
/// The cost is fetch lead. The queue's fetcher works head first, and a card
/// placed second has one picture's worth of time for its bytes rather than a
/// whole traversal's. On average a new card has half the queue ahead of it.
///
/// **A card leaves by `remove(photoID:)`, and two things call it.** Serving,
/// once it has chosen a card and checked it — the `DELETE` under the write
/// lock is what settles two consumers choosing the same card. And a fetch that
/// did not produce bytes, whether the fetcher's or the wait in serving: the
/// card is dropped and the photograph goes back into the deck's contention.
/// There is deliberately no head-pop: since 2026-09-05 serving chooses first
/// and removes second, because the card it serves is not always the head.
///
/// Serving is what notices the queue has run low, so the top-up rides serving;
/// the heartbeat's top-up covers a queue shortened by a dropped card.
///
/// **The size is nominal, not a ceiling.** Nothing is evicted to shorten the
/// queue, so the depth floats around the target rather than being held at it.
public struct PhotoQueue {
    public let database: Database
    /// The size to top up toward. Not a maximum.
    public let nominalSize: Int
    /// Where a new card goes among `n` cards already queued: a slot from 1
    /// (second) to `n` (last). Injectable so tests can make placement
    /// deterministic; production draws uniformly.
    let placement: (Int) -> Int

    public init(database: Database, nominalSize: Int = 1000) {
        self.init(database: database, nominalSize: nominalSize, placement: Self.uniform)
    }

    init(database: Database, nominalSize: Int, placement: @escaping (Int) -> Int) {
        self.database = database
        self.nominalSize = max(1, nominalSize)
        self.placement = placement
    }

    /// Uniform over second to last. With nothing queued there is only the one
    /// place to be.
    static func uniform(_ present: Int) -> Int {
        present >= 1 ? Int.random(in: 1...present) : 0
    }

    /// Always the tail: the FIFO that migrations 8 to 10 shipped, kept for
    /// tests that are about order rather than placement.
    static func tail(_ present: Int) -> Int { present }

    // MARK: - Looking at it

    public func size() throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM queue;") ?? 0
    }

    /// True when serving has left the queue short and providers should be asked.
    public func needsTopUp() throws -> Bool {
        try size() < nominalSize
    }

    /// The head, without removing it. For inspection and for a display that
    /// wants to prepare the next image before it needs it.
    public func peek(_ count: Int = 1) throws -> [DeckCard] {
        try database.all(
            """
            SELECT p.id, p.uuid, p.source_id, s.uuid AS source_uuid, p.external_id, p.storage
              FROM queue q
              JOIN photo p ON p.id = q.photo_id
              JOIN source s ON s.id = p.source_id
             ORDER BY q.rank
             LIMIT :limit;
            """,
            ["limit": .int(Int64(count))]
        ) { try DeckCard(row: $0, dealSeq: nil) }
    }

    // MARK: - What the fetcher asks

    /// The first card past `rank` whose bytes are not here and which no lane is
    /// already fetching, with its rank — so a caller walking the queue can ask
    /// for the one after it.
    ///
    /// **Head first is the whole point of asking the queue rather than the
    /// library.** The card at the head is the one whose turn comes next.
    /// `cached_at` is the projection the store keeps of what it holds; the
    /// caller confirms against the store itself, because that is the truth.
    public func nextUnheld(
        after rank: Int64, claimedBefore expiry: Date
    ) throws -> (rank: Int64, card: DeckCard)? {
        try database.first(
            """
            SELECT q.rank, p.id, p.uuid, p.source_id, s.uuid AS source_uuid,
                   p.external_id, p.storage
              FROM queue q
              JOIN photo p ON p.id = q.photo_id
              JOIN source s ON s.id = p.source_id
             WHERE q.rank > :after
               AND p.storage = 'materialized'
               AND p.cached_at IS NULL
               AND (p.claimed_at IS NULL OR p.claimed_at <= :expiry)
               AND p.render_failures < :retired
             ORDER BY q.rank
             LIMIT 1;
            """,
            [
                "after": .int(rank), "expiry": SQLValue(expiry),
                "retired": .int(Int64(Deck.renderFailureLimit)),
            ]
        ) { row in
            (rank: try row.int64("rank"), card: try DeckCard(row: row, dealSeq: nil))
        }
    }

    /// Whether this photograph is queued right now. What a request waiting on
    /// a cold head card polls, so it notices the fetcher dropping the card.
    public func contains(photoID: Int64) throws -> Bool {
        (try database.scalarInt(
            "SELECT COUNT(*) FROM queue WHERE photo_id = :id;", ["id": .int(photoID)]) ?? 0) > 0
    }

    /// Takes a card out of the queue wherever it sits. True when it was there.
    ///
    /// **This is how a card leaves the queue**, whichever way it goes: served,
    /// or dropped because its bytes never came. Serving takes the card it has
    /// chosen — usually the head, but the first card with bytes once a request
    /// has stopped waiting — and two consumers choosing the same card are
    /// settled here: the `DELETE` runs under `BEGIN IMMEDIATE`, so exactly one
    /// sees a change and the other goes round again.
    @discardableResult
    public func remove(photoID: Int64) throws -> Bool {
        try database.transaction(.immediate) {
            try database.run(
                "DELETE FROM queue WHERE photo_id = :id;", ["id": .int(photoID)])
            return database.changes > 0
        }
    }

    /// The same removal, for a caller that is already `async`. Taking the
    /// writer by suspending rather than blocking, for the reason `serve` does.
    @discardableResult
    public func remove(
        photoID: Int64,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Bool {
        try await database.transaction(.immediate) {
            try database.run(
                "DELETE FROM queue WHERE photo_id = :id;", ["id": .int(photoID)])
            return database.changes > 0
        }
    }

    // MARK: - Filling

    /// Adds one entry, placed at random among the cards present.
    ///
    /// The slot comes from `placement`: 1 is second from the head, `n` is last.
    /// The card holding that slot and everything behind it move up one rank,
    /// and the new card takes the rank they vacated. An empty queue has only
    /// one place to be. **The head is never displaced**: whatever is about to
    /// be shown stays about to be shown.
    ///
    /// Nothing is evicted, nothing is capped, and an entry already queued is
    /// not added twice: the deck re-offering a picture we are already holding
    /// is answering honestly, it just has nothing new to contribute.
    @discardableResult
    public func append(photoID: Int64, sourceID: Int64, at now: Date = Date()) throws -> Bool {
        try database.transaction(.immediate) {
            let alreadyQueued =
                try database.scalarInt(
                    "SELECT COUNT(*) FROM queue WHERE photo_id = :id;", ["id": .int(photoID)]
                ) ?? 0
            guard alreadyQueued == 0 else { return false }

            let present = try database.scalarInt("SELECT COUNT(*) FROM queue;") ?? 0
            let slot = present >= 1 ? min(max(placement(present), 1), present) : 0
            let rank: Int64
            if slot >= present {
                rank = Int64(try database.scalarInt("SELECT IFNULL(MAX(rank), 0) FROM queue;") ?? 0) + 1
            } else {
                // The rank of the card currently in that slot, which it and
                // everything behind it now give up.
                let taken = try database.scalarInt(
                    "SELECT rank FROM queue ORDER BY rank LIMIT 1 OFFSET :slot;",
                    ["slot": .int(Int64(slot))]
                ) ?? 0
                rank = Int64(taken)
                try database.run(
                    "UPDATE queue SET rank = rank + 1 WHERE rank >= :rank;", ["rank": .int(rank)])
            }

            try database.run(
                """
                INSERT INTO queue (photo_id, source_id, queued_at, rank)
                VALUES (:photo, :source, :now, :rank);
                """,
                [
                    "photo": .int(photoID), "source": .int(sourceID), "now": SQLValue(now),
                    "rank": .int(rank),
                ]
            )
            return true
        }
    }

}
