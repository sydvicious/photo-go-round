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

    /// One photo from this source that is worth adding to the queue, **claimed
    /// so that nobody else picks it while its bytes are being fetched**.
    ///
    /// This is what a provider answers with when the queue asks it for a
    /// picture. The shuffle rules still apply — the pass, the repeat window, the
    /// random offset — but they apply *within* the source being asked, because
    /// the caller is asking this source specifically.
    ///
    /// Photos already queued are excluded, so asking twice in a row does not
    /// offer the same picture twice.
    ///
    /// **Selecting and claiming are one transaction, and that is the point.**
    /// A fetch happens between selection and queuing, so without the claim two
    /// producers asking the same source could pick the same picture and both
    /// download it — reachable rather than theoretical, since a source runs
    /// several fetches at once. Under `BEGIN IMMEDIATE` the loser sees the
    /// winner's claim and picks something else.
    ///
    /// The caller must release the claim when it is done with the picture,
    /// whatever the outcome; `PhotoCache.produce` does it in a `defer`. A caller
    /// that dies first releases nothing, which is why the claim expires — see
    /// `claimTimeout`.
    public func nextCandidate(
        forSource sourceID: Int64,
        settings: DeckSettings = .default,
        now: Date = Date()
    ) throws -> DeckCard? {
        let pool = try poolSize()
        guard pool > 0 else { return nil }

        let window = settings.repeatWindow(poolSize: pool)
        let claimedBefore = now.addingTimeInterval(-Self.claimTimeout)

        return try database.transaction(.immediate) {
            let state = try state()
            var threshold = Self.threshold(
                seq: state.dealSeq, passStartSeq: state.passStartSeq, window: window
            )

            var eligible = try countCandidates(
                sourceID: sourceID, threshold: threshold, claimedBefore: claimedBefore)
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
                eligible = try countCandidates(
                    sourceID: sourceID, threshold: threshold, claimedBefore: claimedBefore)
            }
            guard eligible > 0 else { return nil }

            let card = try database.first(
                Self.candidateSQL,
                [
                    "source": .int(sourceID),
                    "threshold": .int(threshold),
                    "claimExpiry": SQLValue(claimedBefore),
                    "offset": .int(Int64(randomOffset(eligible))),
                ]
            ) { try DeckCard(row: $0, dealSeq: nil) }
            guard let card else { return nil }

            try database.run(
                "UPDATE photo SET claimed_at = :now WHERE id = :id;",
                ["now": SQLValue(now), "id": .int(card.id)]
            )
            return card
        }
    }

    /// How long a claim counts for.
    ///
    /// Long enough that no honest fetch expires under it — an iCloud original
    /// over a slow connection is minutes rather than seconds — and short enough
    /// that a producer killed mid-fetch does not sideline a photo for a session.
    /// Nothing depends on the exact number: expiring early costs one duplicated
    /// download, which is the very thing the claim exists to avoid, and expiring
    /// late costs one photo its turn. Both are cheaper than a reaper.
    public static let claimTimeout: TimeInterval = 300

    /// How many failed renders retire a photograph.
    ///
    /// More than one because a decode can fail from memory pressure or from a
    /// file caught mid-copy, neither of which says anything permanent about it.
    /// Few enough that a genuinely bad file stops costing cards quickly.
    public static let renderFailureLimit = 3

    /// Records that this photograph could not be rendered, and answers how many
    /// times that has now happened.
    ///
    /// At `renderFailureLimit` it stops being offered. The row stays — removing
    /// it would not work, since the file is still on disk and the next refresh
    /// would find it and add it back.
    @discardableResult
    public func recordRenderFailure(photoID: Int64, now: Date = Date()) throws -> Int {
        try database.transaction(.immediate) {
            try database.run(
                "UPDATE photo SET render_failures = render_failures + 1 WHERE id = :id;",
                ["id": .int(photoID)]
            )
            let count =
                try database.scalarInt(
                    "SELECT render_failures FROM photo WHERE id = :id;", ["id": .int(photoID)]
                ) ?? 0
            if count >= Self.renderFailureLimit {
                Log.deck.notice(
                    "photo \(photoID, privacy: .public) failed to render \(count, privacy: .public) times; retiring it"
                )
                try recordEvent(
                    kind: "blacklist", detail: "photo \(photoID) after \(count) render failures",
                    at: now)
            }
            return count
        }
    }

    /// Photographs retired for failing to render, so the tool can show them.
    public func blacklisted() throws -> [(id: Int64, externalID: String, failures: Int)] {
        try database.all(
            """
            SELECT id, external_id, render_failures FROM photo
             WHERE render_failures >= :limit ORDER BY id;
            """,
            ["limit": .int(Int64(Self.renderFailureLimit))]
        ) {
            (
                id: try $0.int64("id"), externalID: try $0.string("external_id"),
                failures: try $0.int("render_failures")
            )
        }
    }

    /// Puts them back in contention, for when the cause was the machine rather
    /// than the file.
    @discardableResult
    public func clearRenderFailures() throws -> Int {
        try database.run("UPDATE photo SET render_failures = 0 WHERE render_failures > 0;")
        return database.changes
    }

    /// Gives a claimed photo back, whether or not it made it to the queue.
    ///
    /// Queued is its own exclusion, so releasing on success is not a hole; the
    /// release that matters is the failing one, where the photo would otherwise
    /// wait out the timeout before anyone offered it again.
    public func releaseClaim(photoID: Int64) throws {
        try database.run(
            "UPDATE photo SET claimed_at = NULL WHERE id = :id;", ["id": .int(photoID)]
        )
    }

    func countCandidates(sourceID: Int64, threshold: Int64, claimedBefore: Date) throws -> Int {
        try database.scalarInt(
            Self.candidateCountSQL,
            [
                "source": .int(sourceID), "threshold": .int(threshold),
                "claimExpiry": SQLValue(claimedBefore),
            ]
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
                       last_shown_at  = :now,
                       claimed_at     = NULL
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
          AND (p.claimed_at IS NULL OR p.claimed_at <= :claimExpiry)
          AND p.render_failures < \(Deck.renderFailureLimit)
          AND NOT EXISTS (SELECT 1 FROM queue q WHERE q.photo_id = p.id)
        """

    static let candidateCountSQL = """
        SELECT COUNT(*) FROM photo p WHERE \(candidatePredicate);
        """

    static let candidateSQL = """
        SELECT p.id, p.uuid, p.source_id, s.uuid AS source_uuid, p.external_id, p.storage
          FROM photo p JOIN source s ON s.id = p.source_id
         WHERE \(candidatePredicate)
         ORDER BY p.shuffle_key
         LIMIT 1 OFFSET :offset;
        """
}
