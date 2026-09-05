import Foundation
import PhotoGoRoundAgentAPI

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

    /// The next card for the deck, chosen from every available photograph —
    /// whether or not its bytes are here. The queue fetches what it holds.
    ///
    /// **It takes no claim.** A claim exists because a fetch happens between
    /// drawing a photograph and storing its bytes, and it belongs to the queue's
    /// fetcher, which draws queued cards and downloads them. Dealing reads a row
    /// and writes a row, with nothing in between for a claim to protect.
    ///
    /// What stops two fillers dealing the same card is the queue. Appending
    /// ignores a photograph already queued, and the candidate predicate
    /// excludes anything the queue holds.
    ///
    /// **Choosing is reading; nothing here writes.** This used to run inside
    /// one `BEGIN IMMEDIATE`, so every count and every piece of pass arithmetic
    /// held the database's single writer for work that wrote nothing — and
    /// while a refresh inserted thousands of rows, a deal could not begin, and
    /// the busy error was reported as a deck with nothing left in it. Serving
    /// was measured at 122 seconds for one request on 2026-08-25 for that
    /// reason.
    public func nextCandidate(
        settings: DeckSettings = .default,
        now: Date = Date()
    ) throws -> DeckCard? {
        try chooseCandidate(settings: settings, now: now)
    }

    /// The claim: taken by the queue's fetcher before a fetch, and by nothing
    /// else. True when this caller now holds it; false when another lane got
    /// there first and its claim has not expired.
    public func claim(photoID: Int64, now: Date = Date()) throws -> Bool {
        try database.transaction(.immediate) {
            try database.run(
                """
                UPDATE photo
                   SET claimed_at = :now
                 WHERE id = :id
                   AND (claimed_at IS NULL OR claimed_at <= :expiry);
                """,
                [
                    "now": SQLValue(now), "id": .int(photoID),
                    "expiry": SQLValue(now.addingTimeInterval(-Self.claimTimeout)),
                ]
            )
            return database.changes > 0
        }
    }

    /// Everything that decides *which* card, with no write in it.
    ///
    /// Internal rather than private so a test can hold the writer on another
    /// connection and prove that choosing still works — which is the whole
    /// property this split exists to provide.
    func chooseCandidate(
        settings: DeckSettings = .default,
        now: Date = Date()
    ) throws -> DeckCard? {
        let pool = try poolSize()
        guard pool > 0 else { return nil }

        let window = settings.repeatWindow(poolSize: pool)

        do {
            let state = try state()
            var threshold = Self.threshold(
                seq: state.dealSeq, passStartSeq: state.passStartSeq, window: window
            )

            var eligible = try countCandidates(threshold: threshold)
            if eligible == 0 {
                // Nothing eligible is three states, and only one of them ends
                // the pass. Queued and claimed photographs are staged, not used
                // up — so when everything dealable is already in play there is
                // nothing to deal and no pass to end. And when the population
                // that can cycle is large enough for the window ever to free
                // someone, waiting is the answer: serving keeps advancing the
                // ordinal and the window opens on its own, where declaring a
                // pass would nullify the window — the photograph just served
                // becomes eligible again at once, with a reshuffle event
                // recorded for every picture.
                //
                // The pass therefore fires only where it was designed to: a
                // population the window can never leave a candidate in, which
                // is fraction 1.0 and the too-small library. A photograph is
                // freed `window + 1` deals after it was dealt, so at most
                // `window + 1` photographs can be blocked at once — a larger
                // population always frees one as serving advances, and a
                // population at or under it never would. Retired photographs
                // are not part of that population: they cannot cycle, and a
                // mostly-blacklisted library must reshuffle rather than wait
                // for a release that cannot come.
                let unconstrained = try countCandidates(threshold: state.dealSeq)
                guard unconstrained > 0 else { return nil }
                guard try dealablePopulation() <= window + 1
                else { return nil }
                threshold = state.dealSeq
                if threshold != state.passStartSeq {
                    // A write, so it takes the writer — and only here, where
                    // there is finally something to write.
                    try database.transaction(.immediate) {
                        try database.run(
                            "UPDATE deck_state SET pass_start_seq = :pass WHERE id = 1;",
                            ["pass": .int(threshold)]
                        )
                        try recordEvent(
                            kind: "pass", detail: "reshuffled at ordinal \(threshold)", at: now)
                    }
                    Log.deck.notice(
                        "deck reshuffled; new pass begins at ordinal \(threshold, privacy: .public)"
                    )
                }
                eligible = try countCandidates(threshold: threshold)
            }
            guard eligible > 0 else { return nil }

            return try database.first(
                Self.candidateSQL,
                [
                    "threshold": .int(threshold),
                    "offset": .int(Int64(randomOffset(eligible))),
                ]
            ) { try DeckCard(row: $0, dealSeq: nil) }
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

    func countCandidates(threshold: Int64) throws -> Int {
        try database.scalarInt(
            Self.candidateCountSQL, ["threshold": .int(threshold)]) ?? 0
    }

    /// The photographs that can actually cycle: dealable, and not retired.
    ///
    /// Distinct from `poolSize()`, which counts retired photographs too — the
    /// window is measured against this number, because a photograph that can
    /// never be dealt again can never be freed by waiting either.
    ///
    func dealablePopulation() throws -> Int {
        try database.scalarInt(Self.dealablePopulationSQL) ?? 0
    }

    /// Marks a photo as shown. **This is the deal**: the ordinal advances,
    /// `times_shown` goes up, the shuffle key is re-rolled, and the repeat
    /// window starts counting.
    ///
    /// Called when a picture is served from the queue, not when it is added —
    /// so a picture prepared but never shown costs the rotation nothing.
    ///
    /// **Not the same as `markDelivered`, below**, which counts what actually
    /// reached a client. This one fires when serving *chooses* a card, before
    /// any rendering has been attempted.
    public func markShown(photoID: Int64, now: Date = Date()) throws -> Int64 {
        try database.transaction(.immediate) { try recordShown(photoID: photoID, now: now) }
    }

    /// The same deal, for a caller that is already `async`.
    ///
    /// **The second of the two statements a picture request contends on**, after
    /// popping the queue. It advances the single ordinal every consumer shares,
    /// so it takes the writer — and serving must never hold a cooperative-pool
    /// thread waiting for it. This suspends instead.
    public func markShown(
        photoID: Int64,
        now: Date = Date(),
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Int64 {
        try await database.transaction(.immediate) {
            try recordShown(photoID: photoID, now: now)
        }
    }

    /// Assumes it is already inside a transaction, so the two forms above differ
    /// in nothing but how they wait.
    private func recordShown(photoID: Int64, now: Date) throws -> Int64 {
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

    /// Records that a photograph's bytes actually left the process.
    ///
    /// **Separate from `markShown`, and deliberately not folded into it.** That
    /// one fires when serving *chooses* a card, which has to happen there
    /// because the shuffle key and the repeat window are re-rolled in the same
    /// statement. This one fires when the endpoint has a 200 in its hand. The
    /// gap between them is every photograph the deck believes it showed and
    /// nobody saw: a file that would not decode, a rendering that failed, a
    /// source that went away between selection and read.
    ///
    /// Touches nothing the deck orders by — no shuffle key, no ordinal, no
    /// claim. It is a statistic, and it is safe to call from the endpoint after
    /// the fact for exactly that reason.
    public func markDelivered(photoID: Int64, now: Date = Date()) throws {
        try database.run(
            """
            UPDATE photo
               SET times_delivered   = times_delivered + 1,
                   last_delivered_at = :now
             WHERE id = :id;
            """,
            ["now": SQLValue(now), "id": .int(photoID)]
        )
    }

    // MARK: - Reporting

    /// How many remote assets are not held.
    ///
    /// For `pgr_ctl deck stats` and the panel. The cache's random draw, which
    /// used this as its stop condition, went on 2026-09-05; what fetches now is
    /// the queue, and it needs no count.
    public func unheldRemoteCount() throws -> Int {
        try database.scalarInt(Self.unheldRemoteCountSQL) ?? 0
    }

    static let unheldRemoteCountSQL = """
        SELECT COUNT(*) FROM photo p
         WHERE p.source_enabled = 1
           AND p.media_type = 'image'
           AND p.storage = 'materialized'
           AND p.render_failures < \(Deck.renderFailureLimit)
           AND p.cached_at IS NULL;
        """

    /// **No claim check.** A claimed photograph is one the queue's fetcher is
    /// downloading, and it is already queued — which the `NOT EXISTS` below
    /// excludes on its own. Nothing happens between dealing a card and serving
    /// it that a claim would protect.
    private static let candidatePredicate = """
        \(Deck.availablePredicate)
          AND (p.last_dealt_seq IS NULL OR p.last_dealt_seq <= :threshold)
          AND p.render_failures < \(Deck.renderFailureLimit)
          AND NOT EXISTS (SELECT 1 FROM queue q WHERE q.photo_id = p.id)
        """

    static let candidateCountSQL = """
        SELECT COUNT(*) FROM photo p WHERE \(candidatePredicate);
        """

    static let dealablePopulationSQL = """
        SELECT COUNT(*) FROM photo p
         WHERE \(Deck.availablePredicate)
           AND p.render_failures < \(Deck.renderFailureLimit);
        """

    static let candidateSQL = """
        SELECT p.id, p.uuid, p.source_id, s.uuid AS source_uuid, p.external_id, p.storage
          FROM photo p JOIN source s ON s.id = p.source_id
         WHERE \(candidatePredicate)
         ORDER BY p.shuffle_key
         LIMIT 1 OFFSET :offset;
        """
}
