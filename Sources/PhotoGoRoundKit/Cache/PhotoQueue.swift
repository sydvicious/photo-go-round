import Foundation
import PhotoGoRoundAgentAPI

/// Pictures that are ready to be served, in the order the deck dealt them.
///
/// **First-in-first-out, and honestly so.** It was not, between migrations 6
/// and 8: cards were placed at a random point among those already queued,
/// because two things arrived here and wanted opposite ends. A card freshly
/// dealt from a new source was invisible for a whole traversal at the tail; a
/// card returning from a completed fetch was warm and waited the same span.
/// Putting either at the head was worse — the order pictures appeared in became
/// the order they were *fetched* in, so the fastest source owned the front
/// whatever its share of the library.
///
/// Only one thing arrives now. A fetch completing does not put anything here;
/// it makes a photograph eligible, and the deck picks it up on its own terms.
/// With one arrival there is one sensible end, and `position` — monotonic since
/// the first schema — is the order.
///
/// The whole design is demand-driven and non-blocking:
///
/// - A client asks for a picture. The head of the queue is returned immediately.
/// - **Serving is the only thing that shortens the queue**, and therefore the
///   only thing that can notice it has run low. Dealing is paced to pictures
///   served, so the top-up rides serving; the heartbeat only seeds an empty
///   queue.
///
/// **The size is nominal, not a ceiling.** Nothing is evicted to shorten the
/// queue, so the depth floats around the target rather than being held at it.
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

    /// Adds one entry at the tail.
    ///
    /// `position` is `INTEGER PRIMARY KEY AUTOINCREMENT`, so the insert places
    /// the card and nothing else has to be computed or renumbered. What this
    /// replaces — a key drawn uniformly between the lowest and highest queued,
    /// widened by an average gap so the region above the top was reachable, and
    /// a respacing pass because the interval only ever shrank and reached zero
    /// in about a thousand cycles — was all in service of a second arrival that
    /// no longer exists.
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

    /// Removes and returns the head.
    ///
    /// Returns nil when the queue is empty, which is an ordinary answer rather
    /// than an error: a fresh install has nothing queued and nothing cached, so
    /// the first requests are answered with *no photos available* and pictures
    /// begin arriving as providers deliver.
    public func serve(at now: Date = Date()) throws -> DeckCard? {
        try database.transaction(.immediate) { try takeHead() }
    }

    /// The same pop, for a caller that is already `async`.
    ///
    /// **Popping the queue takes SQLite's single writer**, so it is one of the
    /// two statements a picture request contends on. Waiting for that writer by
    /// blocking costs the process a cooperative-pool thread — and serving is the
    /// operation that must never be the reason everything else stopped. This
    /// waits by suspending instead. See `Database.transaction`'s async form.
    public func serve(
        at now: Date = Date(),
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> DeckCard? {
        try await database.transaction(.immediate) { try takeHead() }
    }

    /// The head of the queue, removed. Assumes it is already inside a
    /// transaction, which is what lets the two forms above differ in nothing but
    /// how they wait.
    private func takeHead() throws -> DeckCard? {
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
