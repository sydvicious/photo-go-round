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
    /// **One order over every photograph we know about**, whatever state its
    /// source is in. Whether a card can actually be shown is not asked here and
    /// is not knowable here: it is found out by trying to show it, which is what
    /// serving does.
    /// **Choosing is reading; only the claim writes.**
    ///
    /// This used to run entirely inside one `BEGIN IMMEDIATE`, so every count,
    /// every piece of pass arithmetic, and the candidate select all held the
    /// database's single writer — for work that wrote nothing at all until the
    /// last statement. The cost is not theoretical: while a refresh inserts
    /// thousands of rows across its own connections, a deal cannot so much as
    /// begin, and `PhotoCache.deal` then reports the busy error as a deck with
    /// nothing left in it. Serving was measured at 122 seconds for a single
    /// request on 2026-08-25 for the same reason.
    ///
    /// So the lock is taken when there is something to write and not before.
    public func nextCandidate(
        settings: DeckSettings = .default,
        now: Date = Date()
    ) throws -> DeckCard? {
        // **Losing the claim race means somebody took *that* card, not that
        // there are none.** Choosing happens outside any transaction now, so two
        // producers can land on the same row; the loser must choose again rather
        // than report nothing, because "nothing" travels all the way up to a
        // queue that stops filling.
        //
        // The loop terminates because a card that was claimed is excluded from
        // every subsequent choice — each turn round costs exactly one competitor.
        // The cap is a backstop against a pathology nobody has seen, and is far
        // above the number of producers this process runs.
        for _ in 0..<Self.claimAttempts {
            guard let card = try chooseCandidate(settings: settings, now: now) else { return nil }

            // The one write, and the only place the writer is held.
            if try claim(card, now: now) { return card }
        }
        Log.deck.notice("gave up claiming a card after \(Self.claimAttempts, privacy: .public) attempts")
        return nil
    }

    /// How many times a chooser will try again after losing a claim.
    static let claimAttempts = 32

    /// A candidate that can be **shown right now** — no fetch, no wait.
    ///
    /// Two ways a photograph qualifies. It is `referenced`, meaning it lives on
    /// the boot volume and is read in place rather than copied, so there is
    /// nothing to fetch at all. Or its original is already in the cache, which
    /// `resident` carries because that index lives in memory rather than in the
    /// database.
    ///
    /// **This exists for the first tick after launch and nothing else.** A cold
    /// start deals a perfectly good queue of twenty cards and then cannot serve
    /// one of them, because every card's bytes are still coming over the wire —
    /// observed on 2026-08-25 as `out of cards, walked 20` with a full pool and
    /// an empty cache. Preferring what is already here turns that into a
    /// picture immediately.
    ///
    /// **Startup only, deliberately.** As a standing rule it would be a bias
    /// with no end: a local folder would crowd out every network source for
    /// ever, and the deck's single shuffle over the whole library would quietly
    /// stop being true. The ordinary candidate is what runs from the second tick
    /// onward.
    func nextServableCandidate(
        settings: DeckSettings = .default,
        now: Date = Date(),
        resident: Set<String>
    ) throws -> DeckCard? {
        try withServableSet(resident) {
            for _ in 0..<Self.claimAttempts {
                guard
                    let card = try chooseCandidate(
                        settings: settings, now: now, servableOnly: true)
                else { return nil }
                if try claim(card, now: now) { return card }
            }
            return nil
        }
    }

    /// Holds the resident set in a temp table for the duration of `body`.
    ///
    /// A temp table rather than a bound list because the set is as large as the
    /// cache — eight hundred entries on a warm restart — and because it is per
    /// connection, so two refreshers cannot see each other's.
    private func withServableSet<T>(_ resident: Set<String>, _ body: () throws -> T) throws -> T {
        try database.run(
            """
            CREATE TEMP TABLE IF NOT EXISTS servable_now (
              uuid TEXT PRIMARY KEY
            );
            """
        )
        try database.run("DELETE FROM servable_now;")
        if !resident.isEmpty {
            try database.transaction(.immediate) {
                for uuid in resident {
                    try database.run(
                        "INSERT OR IGNORE INTO servable_now (uuid) VALUES (:uuid);",
                        ["uuid": .text(uuid)]
                    )
                }
            }
        }
        defer { try? database.run("DELETE FROM servable_now;") }
        return try body()
    }

    /// The claim, shared by both candidate paths.
    private func claim(_ card: DeckCard, now: Date) throws -> Bool {
        try database.transaction(.immediate) {
            try database.run(
                """
                UPDATE photo
                   SET claimed_at = :now
                 WHERE id = :id
                   AND (claimed_at IS NULL OR claimed_at <= :expiry);
                """,
                [
                    "now": SQLValue(now), "id": .int(card.id),
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
        now: Date = Date(),
        servableOnly: Bool = false
    ) throws -> DeckCard? {
        let pool = try poolSize()
        guard pool > 0 else { return nil }

        let window = settings.repeatWindow(poolSize: pool)
        let claimedBefore = now.addingTimeInterval(-Self.claimTimeout)

        do {
            let state = try state()
            var threshold = Self.threshold(
                seq: state.dealSeq, passStartSeq: state.passStartSeq, window: window
            )

            var eligible = try countCandidates(
                threshold: threshold, claimedBefore: claimedBefore, servableOnly: servableOnly)
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
                let unconstrained = try countCandidates(
                    threshold: state.dealSeq, claimedBefore: claimedBefore,
                    servableOnly: servableOnly)
                guard unconstrained > 0 else { return nil }
                guard try dealablePopulation(servableOnly: servableOnly) <= window + 1
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
                eligible = try countCandidates(
                    threshold: threshold, claimedBefore: claimedBefore,
                    servableOnly: servableOnly)
            }
            guard eligible > 0 else { return nil }

            return try database.first(
                servableOnly ? Self.servableCandidateSQL : Self.candidateSQL,
                [
                    "threshold": .int(threshold),
                    "claimExpiry": SQLValue(claimedBefore),
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

    func countCandidates(
        threshold: Int64, claimedBefore: Date, servableOnly: Bool = false
    ) throws -> Int {
        try database.scalarInt(
            servableOnly ? Self.servableCandidateCountSQL : Self.candidateCountSQL,
            ["threshold": .int(threshold), "claimExpiry": SQLValue(claimedBefore)]
        ) ?? 0
    }

    /// The photographs that can actually cycle: dealable, and not retired.
    ///
    /// Distinct from `poolSize()`, which counts retired photographs too — the
    /// window is measured against this number, because a photograph that can
    /// never be dealt again can never be freed by waiting either.
    ///
    /// **`servableOnly` narrows it to the ones with bytes, and that is the
    /// whole of the 2026-08-26 wedge.** The pass fires when the population is
    /// small enough that waiting can never free anybody, and *which* population
    /// depends on what is being asked for. Asked for a servable card while
    /// measuring the library, the deck saw 445 against a 223 window, concluded
    /// that serving would open the window shortly, and waited — while the 133
    /// photographs that had bytes were every one of them inside it. Nothing
    /// served, so the ordinal never advanced, so the window never opened.
    /// Waiting is only ever the answer for a population that can actually free
    /// someone.
    func dealablePopulation(servableOnly: Bool = false) throws -> Int {
        try database.scalarInt(
            servableOnly ? Self.servablePopulationSQL : Self.dealablePopulationSQL) ?? 0
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

    private static let candidatePredicate = """
        p.source_enabled = 1
          AND p.media_type = 'image'
          AND (p.last_dealt_seq IS NULL OR p.last_dealt_seq <= :threshold)
          AND (p.claimed_at IS NULL OR p.claimed_at <= :claimExpiry)
          AND p.render_failures < \(Deck.renderFailureLimit)
          AND NOT EXISTS (SELECT 1 FROM queue q WHERE q.photo_id = p.id)
        """

    /// Servable *now*: read in place, or its original already cached.
    static let servablePredicate = """
        \(candidatePredicate)
          AND (p.storage = 'referenced'
               OR EXISTS (SELECT 1 FROM servable_now s WHERE s.uuid = p.uuid))
        """

    /// The servable half of `dealablePopulationSQL`: what can cycle *and* has
    /// bytes. Deliberately ignores the window and the claim, because it answers
    /// "how many could ever be freed", not "how many are free now".
    static let servablePopulationSQL = """
        SELECT COUNT(*) FROM photo p
         WHERE p.source_enabled = 1 AND p.media_type = 'image'
           AND p.render_failures < \(Deck.renderFailureLimit)
           AND (p.storage = 'referenced'
                OR EXISTS (SELECT 1 FROM servable_now s WHERE s.uuid = p.uuid));
        """

    static let servableCandidateCountSQL = """
        SELECT COUNT(*) FROM photo p WHERE \(servablePredicate);
        """

    static let servableCandidateSQL = """
        SELECT p.id, p.uuid, p.source_id, s.uuid AS source_uuid, p.external_id, p.storage
          FROM photo p JOIN source s ON s.id = p.source_id
         WHERE \(servablePredicate)
         ORDER BY p.shuffle_key
         LIMIT 1 OFFSET :offset;
        """

    static let candidateCountSQL = """
        SELECT COUNT(*) FROM photo p WHERE \(candidatePredicate);
        """

    static let dealablePopulationSQL = """
        SELECT COUNT(*) FROM photo p
         WHERE p.source_enabled = 1 AND p.media_type = 'image'
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
