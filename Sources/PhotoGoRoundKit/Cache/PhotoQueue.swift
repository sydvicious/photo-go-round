import Foundation

/// Pictures that are ready to be served, in order.
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
             ORDER BY q.position
             LIMIT :limit;
            """,
            ["limit": .int(Int64(count))]
        ) { try DeckCard(row: $0, dealSeq: nil) }
    }

    // MARK: - Filling

    /// Appends one entry. This is what a provider's answer amounts to.
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
                INSERT INTO queue (photo_id, source_id, queued_at)
                VALUES (:photo, :source, :now);
                """,
                ["photo": .int(photoID), "source": .int(sourceID), "now": SQLValue(now)]
            )
            return true
        }
    }

    // MARK: - Draining

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
                 ORDER BY q.position
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

    /// Drops a photo from the queue without serving it — the offline case, and
    /// what a removal from the pool does by cascade.
    @discardableResult
    public func remove(photoID: Int64) throws -> Int {
        try database.run("DELETE FROM queue WHERE photo_id = :id;", ["id": .int(photoID)])
        return database.changes
    }

}
