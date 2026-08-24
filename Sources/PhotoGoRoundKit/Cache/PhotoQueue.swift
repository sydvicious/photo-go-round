import Foundation

/// Pictures that are ready to be served, in an order nothing chose.
///
/// **Not first-in-first-out.** Every card is placed at a random point among the
/// cards already here — see `append` for why both of the orderly alternatives
/// are worse. "The head" below means the card with the smallest `sort_key`,
/// which is a position no caller can predict or rely on.
///
/// The whole design is demand-driven and non-blocking:
///
/// - A client asks for a picture. The head of the queue is returned immediately.
/// - **Serving is the only thing that shortens the queue**, and therefore the
///   only thing that can notice it has run low.
/// - If serving leaves it below nominal, a request goes out to every provider
///   with capacity to take it, and the client is not made to wait for any of
///   them.
/// - Providers answer whenever they answer, each appending one entry. Nothing is
///   evicted when an entry arrives.
///
/// **The size is nominal, not a ceiling.** Four providers with wildly different
/// latency will answer at four different times, so a queue of 1000 becomes 1001,
/// then 1002, and drains back through 1001 and 1000 as clients ask. Trying to
/// hold it at exactly 1000 would mean either blocking a provider that is only
/// being helpful or throwing away work already done. Both are worse than a
/// number that floats by the number of providers.
///
/// The overshoot is bounded by exactly that: one entry per provider, because a
/// provider with a request in flight is not asked again.
public struct PhotoQueue {
    public let database: Database
    /// The size to top up toward. Not a maximum.
    public let nominalSize: Int

    public init(database: Database, nominalSize: Int = 1000) {
        self.database = database
        self.nominalSize = max(1, nominalSize)
    }

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
             ORDER BY q.sort_key, q.position
             LIMIT :limit;
            """,
            ["limit": .int(Int64(count))]
        ) { try DeckCard(row: $0, dealSeq: nil) }
    }

    // MARK: - Filling

    /// Adds one entry, **at a random place in the queue**.
    ///
    /// Not a queue in the first-in-first-out sense, and deliberately so. The two
    /// things that arrive here want opposite ends of a FIFO and neither should
    /// get one: a card returning from a completed fetch is warm and would wait a
    /// whole traversal at the tail, and a card freshly dealt from a new source
    /// would be invisible for the same span. Putting either at the head instead
    /// makes the order pictures appear in the order they were *fetched* in, so
    /// the fastest source owns the front whatever its share of the library.
    ///
    /// The key is drawn uniformly between the smallest and largest currently
    /// queued, which places the card uniformly among the cards present without
    /// moving any of them. An empty queue spans nothing, so it gets `[0, 1)`;
    /// a queue of one has no interval either, so the new card is offset past it
    /// rather than tying.
    ///
    /// Nothing is evicted, nothing is capped, and an entry already queued is not
    /// added twice — a provider re-offering a picture we are already holding is
    /// answering honestly, it just has nothing new to contribute.
    @discardableResult
    public func append(photoID: Int64, sourceID: Int64, at now: Date = Date()) throws -> Bool {
        try database.transaction(.immediate) {
            let alreadyQueued =
                try database.scalarInt(
                    "SELECT COUNT(*) FROM queue WHERE photo_id = :id;", ["id": .int(photoID)]
                ) ?? 0
            guard alreadyQueued == 0 else { return false }

            try database.run(
                """
                INSERT INTO queue (photo_id, source_id, queued_at, sort_key)
                SELECT :photo, :source, :now,
                       CASE
                         WHEN lo IS NULL THEN :r
                         WHEN hi > lo    THEN lo + :r * (hi - lo)
                         ELSE lo + :r
                       END
                  FROM (SELECT MIN(sort_key) AS lo, MAX(sort_key) AS hi FROM queue);
                """,
                [
                    "photo": .int(photoID), "source": .int(sourceID), "now": SQLValue(now),
                    "r": .double(Double.random(in: 0..<1)),
                ]
            )
            try respaceIfCollapsing()
            return true
        }
    }

    /// The smallest key interval worth working in.
    ///
    /// Anything above zero would do for correctness; one is chosen because it
    /// leaves gaps of `1 / count` between neighbours, which is a colossal margin
    /// against the ~1e-16 relative spacing of a `Double` and needs no thought.
    private static let minimumSpan = 1.0

    /// Spreads the keys back out to `1…n`, keeping the order exactly.
    ///
    /// **The interval only ever shrinks, and fast.** A new key is drawn between
    /// the lowest and highest currently queued, so the highest never rises,
    /// while the lowest rises every time a card is served. Modelled over a queue
    /// of twenty, the span reaches *exactly zero* in about a thousand cycles —
    /// under three hours at ten seconds a picture. Keys then tie, ordering falls
    /// back to `position`, and the queue is quietly a FIFO again with random
    /// placement gone and nothing announcing it. That silent reversion is the
    /// reason this exists rather than the arithmetic.
    ///
    /// Renumbering rather than rescaling, because it is the same one statement
    /// either way and integers are what a person reading the table wants to see.
    /// Costs one `UPDATE` over a queue's worth of rows, roughly once every sixty
    /// cards dealt.
    private func respaceIfCollapsing() throws {
        let span =
            try database.first("SELECT MAX(sort_key) - MIN(sort_key) AS span FROM queue;") {
                try $0.double("span")
            } ?? 0
        guard span < Self.minimumSpan else { return }

        try database.run(
            """
            WITH ordered AS (
              SELECT position, ROW_NUMBER() OVER (ORDER BY sort_key, position) AS rank
                FROM queue
            )
            UPDATE queue
               SET sort_key = (SELECT rank * 1.0 FROM ordered WHERE ordered.position = queue.position);
            """
        )
    }

    /// Removes and returns the head.
    ///
    /// Returns nil when the queue is empty, which is an ordinary answer rather
    /// than an error: a fresh install has nothing queued and nothing cached, so
    /// the first requests are answered with *no photos available* and pictures
    /// begin arriving as providers deliver.
    public func serve(at now: Date = Date()) throws -> DeckCard? {
        try database.transaction(.immediate) {
            let head = try database.first(
                """
                SELECT q.position, p.id, p.uuid, p.source_id, s.uuid AS source_uuid,
                       p.external_id, p.storage
                  FROM queue q
                  JOIN photo p ON p.id = q.photo_id
                  JOIN source s ON s.id = p.source_id
                 ORDER BY q.sort_key, q.position
                 LIMIT 1;
                """
            ) { row in
                (position: try row.int64("position"), card: try DeckCard(row: row, dealSeq: nil))
            }
            guard let head else { return nil }

            try database.run(
                "DELETE FROM queue WHERE position = :position;",
                ["position": .int(head.position)]
            )
            return head.card
        }
    }
}
