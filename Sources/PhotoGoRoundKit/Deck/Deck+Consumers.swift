import Foundation

public enum DeckError: Error, CustomStringConvertible, Sendable {
    case unknownConsumer(id: Int64)

    public var description: String {
        switch self {
        case .unknownConsumer(let id): "no consumer with id \(id)"
        }
    }
}

// MARK: - Consumers

extension Deck {

    /// Finds or creates the consumer for a surface, and marks it as seen.
    ///
    /// A registry and a heartbeat, and deliberately nothing more. Every surface
    /// serves from the same queue, so two displays get different pictures
    /// because serving removes the entry.
    @discardableResult
    public func register(
        kind: ConsumerKind,
        displayID: String? = nil,
        now: Date = Date()
    ) throws -> Consumer {
        try database.transaction(.immediate) {
            if let existing = try consumer(kind: kind, displayID: displayID) {
                try database.run(
                    "UPDATE consumer SET seen_at = :now WHERE id = :id;",
                    ["now": SQLValue(now), "id": .int(existing.id)]
                )
                return try consumer(id: existing.id)!
            }

            try database.run(
                """
                INSERT INTO consumer (kind, display_id, seen_at, created_at)
                VALUES (:kind, :display, :now, :now);
                """,
                ["kind": .text(kind.rawValue), "display": SQLValue(displayID), "now": SQLValue(now)]
            )
            let id = database.lastInsertRowID
            Log.deck.notice(
                "registered consumer \(id, privacy: .public) of kind \(kind.rawValue, privacy: .public)"
            )
            return try consumer(id: id)!
        }
    }

    public func consumer(id: Int64) throws -> Consumer? {
        try database.first(Self.selectConsumerSQL + " WHERE id = :id;", ["id": .int(id)]) {
            try Consumer(row: $0)
        }
    }

    public func consumer(kind: ConsumerKind, displayID: String?) throws -> Consumer? {
        try database.first(
            Self.selectConsumerSQL
                + " WHERE kind = :kind AND IFNULL(display_id, '') = IFNULL(:display, '');",
            ["kind": .text(kind.rawValue), "display": SQLValue(displayID)]
        ) { try Consumer(row: $0) }
    }

    public func consumers() throws -> [Consumer] {
        try database.all(Self.selectConsumerSQL + " ORDER BY kind, IFNULL(display_id, '');") {
            try Consumer(row: $0)
        }
    }

    /// The heartbeat. Cheap enough to call on every request.
    public func touch(consumerID: Int64, at now: Date = Date()) throws {
        try database.run(
            "UPDATE consumer SET seen_at = :now WHERE id = :id;",
            ["now": SQLValue(now), "id": .int(consumerID)]
        )
    }

    public func forget(consumerID: Int64) throws {
        try database.run("DELETE FROM consumer WHERE id = :id;", ["id": .int(consumerID)])
    }

    private static let selectConsumerSQL = """
        SELECT id, kind, display_id, seen_at, created_at FROM consumer
        """
}

// MARK: - Choosing what to queue next

extension Deck {

    /// One photo from this source that is worth adding to the queue.
    ///
    /// This is what a provider answers with when the queue asks it for a
    /// picture. The shuffle rules still apply — the pass, the repeat window, the
    /// random offset — but they apply *within* the source being asked, because
    /// the caller is asking this source specifically.
    ///
    /// Photos already queued are excluded, so asking twice in a row does not
    /// offer the same picture twice.
    public func nextCandidate(
        forSource sourceID: Int64,
        settings: DeckSettings = .default,
        now: Date = Date()
    ) throws -> DeckCard? {
        let pool = try poolSize()
        guard pool > 0 else { return nil }

        let state = try state()
        let window = settings.repeatWindow(poolSize: pool)
        var threshold = Self.threshold(
            seq: state.dealSeq, passStartSeq: state.passStartSeq, window: window
        )

        var eligible = try countCandidates(sourceID: sourceID, threshold: threshold)
        if eligible == 0 {
            // This source has nothing left unused in the current pass. Starting
            // a new pass is ordinary business, not a concession.
            threshold = state.dealSeq
            if threshold != state.passStartSeq {
                try database.run(
                    "UPDATE deck_state SET pass_start_seq = :pass WHERE id = 1;",
                    ["pass": .int(threshold)]
                )
                Log.deck.notice(
                    "deck reshuffled; new pass begins at ordinal \(threshold, privacy: .public)"
                )
                try recordEvent(kind: "pass", detail: "reshuffled at ordinal \(threshold)", at: now)
            }
            eligible = try countCandidates(sourceID: sourceID, threshold: threshold)
        }
        guard eligible > 0 else { return nil }

        return try database.first(
            Self.candidateSQL,
            [
                "source": .int(sourceID),
                "threshold": .int(threshold),
                "offset": .int(Int64(randomOffset(eligible))),
            ]
        ) { try DeckCard(row: $0, dealSeq: nil) }
    }

    func countCandidates(sourceID: Int64, threshold: Int64) throws -> Int {
        try database.scalarInt(
            Self.candidateCountSQL, ["source": .int(sourceID), "threshold": .int(threshold)]
        ) ?? 0
    }

    /// Marks a photo as shown. **This is the deal**: the ordinal advances,
    /// `times_shown` goes up, the shuffle key is re-rolled, and the repeat
    /// window starts counting.
    ///
    /// Called when a picture is served from the queue, not when it is added —
    /// so a picture prepared but never shown costs the rotation nothing.
    @discardableResult
    public func markShown(photoID: Int64, now: Date = Date()) throws -> Int64 {
        try database.transaction(.immediate) {
            let seq = try currentDealSeq() + 1
            try database.run(
                """
                UPDATE photo
                   SET times_shown    = times_shown + 1,
                       last_dealt_seq = :seq,
                       shuffle_key    = :key,
                       last_shown_at  = :now
                 WHERE id = :id;
                """,
                [
                    "seq": .int(seq), "key": .double(randomKey()),
                    "now": SQLValue(now), "id": .int(photoID),
                ]
            )
            try database.run(
                "UPDATE deck_state SET deal_seq = :seq WHERE id = 1;", ["seq": .int(seq)]
            )
            return seq
        }
    }

    private static let candidatePredicate = """
        p.source_id = :source
          AND p.source_enabled = 1
          AND p.media_type = 'image'
          AND (p.last_dealt_seq IS NULL OR p.last_dealt_seq <= :threshold)
          AND NOT EXISTS (SELECT 1 FROM queue q WHERE q.photo_id = p.id)
        """

    static let candidateCountSQL = """
        SELECT COUNT(*) FROM photo p WHERE \(candidatePredicate);
        """

    static let candidateSQL = """
        SELECT p.id, p.source_id, p.external_id, p.storage, p.cache_path
          FROM photo p
         WHERE \(candidatePredicate)
         ORDER BY p.shuffle_key
         LIMIT 1 OFFSET :offset;
        """
}
