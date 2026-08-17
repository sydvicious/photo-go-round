import Foundation

/// The shared deck: one sequence, dealt from by every surface.
///
/// The deck runs in **passes**. A pass is a random permutation of the pool: a
/// photo is unused in the current pass while its deal ordinal is at or below
/// `pass_start_seq`, and when nothing unused is left the deck reshuffles —
/// `pass_start_seq` moves up to the current ordinal and every photo becomes
/// eligible again. At repeat-window fraction 1.0 that is the whole algorithm,
/// and it gives exact fairness with a different order every time through.
///
/// The **repeat window** lets photos come back before the pass ends. At
/// fraction *f* a photo is also eligible once `round(f × pool)` deals have gone
/// by, whatever the pass is doing. The two rules are a single comparison —
/// eligible when `last_dealt_seq <= max(pass_start_seq, seq - w - 1)` — so
/// there is no branch and no special case. At fraction 1.0 the window term is
/// always the smaller of the two and drops out on its own.
///
/// Two consequences worth knowing. A photo dealt at the end of one pass can be
/// dealt again at the start of the next, so the minimum gap is not the window;
/// this is a deliberate acceptance rather than an oversight. And running out of
/// cards mid-pass is not a failure to be degraded around — it is the end of the
/// pass, which is ordinary business.
///
/// **Selection takes a uniformly random offset into the eligible set, never its
/// first row.** `ORDER BY shuffle_key LIMIT 1` takes the *minimum*, and only the
/// winner's key is re-rolled — so below fraction 1.0, where a pass does not
/// guarantee everyone a turn, a photo whose key lands high loses, keeps its high
/// key because it never won, and loses again, permanently. Fraction 1.0 hides
/// this, which is why it is worth stating rather than assuming.
/// `shuffle_key` keeps both of its jobs: it supplies the index that makes
/// selection cheap, and its re-roll on deal keeps a hand's contiguous block from
/// being the same neighbourhood twice running.
///
/// The deck contains no timers and no opinion about when it is called. The Mac
/// agent drives it from a continuous loop; an iOS widget will drive it from a
/// timeline provider. That difference lives entirely on the host side.
public struct Deck {
    public let database: Database

    /// Injectable so tests can make the shuffle deterministic. Production uses
    /// the system generator.
    let randomKey: () -> Double
    /// Chooses a position within an eligible set of the given size.
    let randomOffset: (Int) -> Int

    public init(database: Database) {
        self.init(
            database: database,
            randomKey: { Double.random(in: 0..<1) },
            randomOffset: { $0 > 0 ? Int.random(in: 0..<$0) : 0 }
        )
    }

    init(
        database: Database,
        randomKey: @escaping () -> Double,
        randomOffset: @escaping (Int) -> Int = { $0 > 0 ? Int.random(in: 0..<$0) : 0 }
    ) {
        self.database = database
        self.randomKey = randomKey
        self.randomOffset = randomOffset
    }

    // MARK: - State

    /// Photos the deck could deal, ignoring the pass and the window: enabled
    /// source, available, and a still image.
    ///
    /// Cache residency is deliberately *not* part of this. Cards are reserved
    /// ahead of being needed and the prefetcher materialises what has been
    /// reserved, so requiring resident bytes here would mean the cache could
    /// never lead the deck.
    public func poolSize() throws -> Int {
        try database.scalarInt(Self.poolSizeSQL) ?? 0
    }

    /// The single monotonic ordinal, advanced by every card played anywhere in
    /// the system, and the ordinal at which the current pass began.
    public func state() throws -> (dealSeq: Int64, passStartSeq: Int64) {
        try database.first("SELECT deal_seq, pass_start_seq FROM deck_state WHERE id = 1;") {
            (try $0.int64("deal_seq"), try $0.int64("pass_start_seq"))
        } ?? (0, 0)
    }

    public func currentDealSeq() throws -> Int64 {
        try state().dealSeq
    }

    /// The repeat window in cards, given the current pool.
    public func repeatWindow(settings: DeckSettings = .default) throws -> Int {
        settings.repeatWindow(poolSize: try poolSize())
    }

    /// The single comparison both rules collapse into: a photo is eligible when
    /// it has never been dealt, or was last dealt at or below this ordinal.
    static func threshold(seq: Int64, passStartSeq: Int64, window: Int) -> Int64 {
        max(passStartSeq, seq - Int64(window) - 1)
    }

    /// How many photos are eligible at the given threshold.
    func countEligible(threshold: Int64, ignoringOutstandingHands: Bool) throws -> Int {
        try database.scalarInt(
            ignoringOutstandingHands ? Self.countIgnoringHandsSQL : Self.countSQL,
            ["threshold": .int(threshold)]
        ) ?? 0
    }

    /// Photos not yet dealt in the current pass. Counts down to zero, at which
    /// point the deck reshuffles.
    public func unusedInCurrentPass() throws -> Int {
        let state = try state()
        return try countEligible(threshold: state.passStartSeq, ignoringOutstandingHands: true)
    }

    // MARK: - Dealing

    /// The result of a deal: a card, plus whatever the deck had to give up to
    /// produce it.
    public struct Deal: Sendable, Equatable {
        public let card: DeckCard
        public let relaxations: [DeckRelaxation]
        /// True when this card was the first of a fresh pass.
        public let startedNewPass: Bool
    }

    /// Deals one card and advances the deal ordinal.
    ///
    /// `BEGIN IMMEDIATE` takes the write lock up front rather than discovering
    /// the conflict at COMMIT, and `UPDATE … RETURNING` makes the deal and the
    /// read one round trip. Two processes racing are serialised by SQLite, and
    /// the loser gets the *next* card rather than the same one.
    ///
    /// Returns nil only when there is genuinely nothing to deal — an empty
    /// library.
    public func deal(settings: DeckSettings = .default, now: Date = Date()) throws -> Deal? {
        try database.transaction(.immediate) {
            let pool = try poolSize()
            guard pool > 0 else { return nil }

            let state = try state()
            let seq = state.dealSeq + 1
            let window = settings.repeatWindow(poolSize: pool)

            var threshold = Self.threshold(seq: seq, passStartSeq: state.passStartSeq, window: window)
            var passStart = state.passStartSeq
            var startedNewPass = false
            var relaxations: [DeckRelaxation] = []

            var eligible = try countEligible(threshold: threshold, ignoringOutstandingHands: false)

            if eligible == 0 {
                // The pass is spent. Reshuffle: everything dealt so far becomes
                // unused again, which is strictly more permissive than any
                // window could be, so there is nothing further to degrade.
                passStart = seq - 1
                threshold = passStart
                startedNewPass = passStart != state.passStartSeq
                eligible = try countEligible(threshold: threshold, ignoringOutstandingHands: false)
            }

            if eligible > 0,
                let card = try dealOne(
                    sql: Self.dealSQL, seq: seq, threshold: threshold,
                    offset: randomOffset(eligible), now: now
                )
            {
                try commit(seq: seq, passStart: passStart, startedNewPass: startedNewPass,
                           relaxations: relaxations, now: now)
                return Deal(card: card, relaxations: relaxations, startedNewPass: startedNewPass)
            }

            // Every free card is spoken for by somebody's outstanding hand.
            // Overlap rather than starve: three displays and one photo means
            // all three show that photo.
            let anyCard = try countEligible(threshold: threshold, ignoringOutstandingHands: true)
            if anyCard > 0 {
                relaxations.append(.reservedCardsReused)
                if let card = try dealOne(
                    sql: Self.dealIgnoringHandsSQL, seq: seq, threshold: threshold,
                    offset: randomOffset(anyCard), now: now
                ) {
                    try commit(seq: seq, passStart: passStart, startedNewPass: startedNewPass,
                               relaxations: relaxations, now: now)
                    return Deal(card: card, relaxations: relaxations, startedNewPass: startedNewPass)
                }
            }

            // A fresh pass with hands ignored matches every dealable photo, so
            // reaching here means the pool count and the deal predicate have
            // drifted apart.
            Log.deck.fault("pool reported \(pool, privacy: .public) photos but nothing was dealable")
            return nil
        }
    }

    private func dealOne(sql: String, seq: Int64, threshold: Int64, offset: Int, now: Date) throws -> DeckCard? {
        try database.first(
            sql,
            [
                "seq": .int(seq),
                "threshold": .int(threshold),
                "offset": .int(Int64(offset)),
                "key": .double(randomKey()),
                "now": SQLValue(now),
            ]
        ) { try DeckCard(row: $0, dealSeq: seq) }
    }

    private func commit(
        seq: Int64,
        passStart: Int64,
        startedNewPass: Bool,
        relaxations: [DeckRelaxation],
        now: Date
    ) throws {
        try database.run(
            "UPDATE deck_state SET deal_seq = :seq, pass_start_seq = :pass WHERE id = 1;",
            ["seq": .int(seq), "pass": .int(passStart)]
        )
        if startedNewPass {
            Log.deck.notice("deck reshuffled; new pass begins at ordinal \(seq, privacy: .public)")
            try recordEvent(kind: "pass", detail: "reshuffled at ordinal \(seq)", at: now)
        }
        for relaxation in relaxations {
            try record(relaxation, at: now)
        }
    }

    // MARK: - Selecting without dealing

    /// The eligibility query on its own, without advancing anything.
    ///
    /// This is what hand reservation is built from: reservation marks cards as
    /// spoken for, and only *playing* a card assigns it a deal ordinal and
    /// starts its window clock.
    ///
    /// The block is contiguous in shuffle order from a random starting point,
    /// wrapping if it runs off the end — cutting the deck and dealing from the
    /// cut. Every eligible card has the same chance of being in the block.
    func selectCandidates(
        limit: Int,
        threshold: Int64,
        ignoringOutstandingHands: Bool,
        offset: Int? = nil
    ) throws -> [DeckCard] {
        guard limit > 0 else { return [] }
        let eligible = try countEligible(
            threshold: threshold, ignoringOutstandingHands: ignoringOutstandingHands
        )
        guard eligible > 0 else { return [] }

        let sql = ignoringOutstandingHands ? Self.candidatesIgnoringHandsSQL : Self.candidatesSQL
        let start = offset ?? randomOffset(eligible)
        func bindings(limit: Int, offset: Int) -> SQLBindings {
            ["threshold": .int(threshold), "limit": .int(Int64(limit)), "offset": .int(Int64(offset))]
        }

        var cards = try database.all(sql, bindings(limit: limit, offset: start)) {
            try DeckCard(row: $0, dealSeq: nil)
        }
        // Wrap, so a starting point near the end of the order does not produce
        // an artificially short hand.
        if cards.count < limit, start > 0 {
            cards += try database.all(sql, bindings(limit: limit - cards.count, offset: 0)) {
                try DeckCard(row: $0, dealSeq: nil)
            }
        }
        return cards
    }

    /// The head of the eligible set in shuffle order — what `pgr deck peek`
    /// shows.
    ///
    /// Deliberately *not* a prediction of what will be dealt next: selection
    /// takes a random offset into this set, so there is no "next card" until a
    /// deal picks one. This is the set it will pick from.
    public func peek(count: Int, settings: DeckSettings = .default) throws -> [DeckCard] {
        let pool = try poolSize()
        guard pool > 0 else { return [] }
        let state = try state()
        return try selectCandidates(
            limit: count,
            threshold: Self.threshold(
                seq: state.dealSeq,
                passStartSeq: state.passStartSeq,
                window: settings.repeatWindow(poolSize: pool)
            ),
            ignoringOutstandingHands: false,
            offset: 0
        )
    }

    // MARK: - Events

    /// Relaxations are recorded rather than swallowed, so `pgr deck stats` and
    /// eventually the settings UI can say that the library cannot support what
    /// was asked of it.
    func record(_ relaxation: DeckRelaxation, at now: Date = Date()) throws {
        Log.deck.notice(
            "deck relaxed: \(relaxation.eventKind, privacy: .public) — \(relaxation.eventDetail, privacy: .public)"
        )
        try recordEvent(kind: relaxation.eventKind, detail: relaxation.eventDetail, at: now)
    }

    func recordEvent(kind: String, detail: String?, at now: Date = Date()) throws {
        try database.run(
            "INSERT INTO deck_event (at, kind, detail) VALUES (:at, :kind, :detail);",
            ["at": SQLValue(now), "kind": .text(kind), "detail": SQLValue(detail)]
        )
        // Bounded tail; nothing depends on old rows.
        try database.run(
            """
            DELETE FROM deck_event
             WHERE id <= (SELECT MAX(id) FROM deck_event) - :keep;
            """,
            ["keep": .int(Int64(Self.eventsKept))]
        )
    }

    static let eventsKept = 500

    public func recentEvents(limit: Int = 50) throws -> [DeckEvent] {
        try database.all(
            "SELECT at, kind, detail FROM deck_event ORDER BY id DESC LIMIT :limit;",
            ["limit": .int(Int64(limit))]
        ) { row in
            DeckEvent(
                at: try row.date("at"),
                kind: try row.string("kind"),
                detail: try row.optionalString("detail")
            )
        }
    }

    // MARK: - Statistics

    public func stats(settings: DeckSettings = .default) throws -> DeckStats {
        let pool = try poolSize()
        let state = try state()
        let counts = try database.first(
            """
            SELECT COUNT(*)                                                  AS total,
                   SUM(CASE WHEN last_dealt_seq IS NULL THEN 1 ELSE 0 END)   AS never_dealt,
                   SUM(CASE WHEN cache_path IS NOT NULL THEN 1 ELSE 0 END)   AS resident,
                   IFNULL(MIN(times_shown), 0)                               AS shown_min,
                   IFNULL(MAX(times_shown), 0)                               AS shown_max,
                   IFNULL(SUM(times_shown), 0)                               AS shown_total
              FROM photo;
            """
        ) { row in
            (
                total: try row.int("total"),
                neverDealt: try row.optionalInt("never_dealt") ?? 0,
                resident: try row.optionalInt("resident") ?? 0,
                min: try row.int("shown_min"),
                max: try row.int("shown_max"),
                shownTotal: try row.int("shown_total")
            )
        }

        return DeckStats(
            totalPhotos: counts?.total ?? 0,
            dealablePhotos: pool,
            neverDealt: counts?.neverDealt ?? 0,
            residentPhotos: counts?.resident ?? 0,
            currentDealSeq: state.dealSeq,
            passStartSeq: state.passStartSeq,
            unusedInCurrentPass: try unusedInCurrentPass(),
            repeatWindow: settings.repeatWindow(poolSize: pool),
            timesShownMin: counts?.min ?? 0,
            timesShownMax: counts?.max ?? 0,
            timesShownTotal: counts?.shownTotal ?? 0,
            recentEvents: try recentEvents()
        )
    }
}

public struct DeckEvent: Sendable, Equatable {
    public let at: Date
    public let kind: String
    public let detail: String?
}

public struct DeckStats: Sendable, Equatable {
    public let totalPhotos: Int
    /// Photos the deck could deal right now, ignoring the pass and the window.
    public let dealablePhotos: Int
    public let neverDealt: Int
    /// Photos whose bytes are resident — referenced in place or materialised.
    public let residentPhotos: Int
    public let currentDealSeq: Int64
    public let passStartSeq: Int64
    /// Cards left before the deck reshuffles.
    public let unusedInCurrentPass: Int
    public let repeatWindow: Int
    public let timesShownMin: Int
    public let timesShownMax: Int
    public let timesShownTotal: Int
    public let recentEvents: [DeckEvent]
}

// MARK: - SQL

extension Deck {

    /// v1 selects still images only. The exclusion is a named predicate rather
    /// than an absence of video code, which is the difference between 2.0 being
    /// a feature and being an excavation.
    ///
    /// `:threshold` carries both the pass and the window, since eligibility is
    /// `last_dealt_seq <= max(pass_start_seq, seq - w - 1)`. A photo never dealt
    /// is eligible by definition, which is what lets a newly added photo join
    /// the pass already in progress rather than waiting for the next one.
    fileprivate static let eligibilityPredicate = """
        p.source_enabled = 1
          AND p.available = 1
          AND p.media_type = 'image'
          AND (p.last_dealt_seq IS NULL OR p.last_dealt_seq <= :threshold)
        """

    /// A card already reserved into somebody's outstanding hand is spoken for.
    fileprivate static let notAlreadyReserved = """
        AND NOT EXISTS (
              SELECT 1 FROM hand h
               WHERE h.photo_id = p.id AND h.played_at IS NULL)
        """

    static let poolSizeSQL = """
        SELECT COUNT(*) FROM photo p
         WHERE p.source_enabled = 1 AND p.available = 1 AND p.media_type = 'image';
        """

    static let countSQL = countStatement(excludingReserved: true)
    static let countIgnoringHandsSQL = countStatement(excludingReserved: false)
    static let dealSQL = dealStatement(excludingReserved: true)
    static let dealIgnoringHandsSQL = dealStatement(excludingReserved: false)
    static let candidatesSQL = candidatesStatement(excludingReserved: true)
    static let candidatesIgnoringHandsSQL = candidatesStatement(excludingReserved: false)

    private static func countStatement(excludingReserved: Bool) -> String {
        """
        SELECT COUNT(*) FROM photo p
         WHERE \(eligibilityPredicate)
           \(excludingReserved ? notAlreadyReserved : "");
        """
    }

    private static func dealStatement(excludingReserved: Bool) -> String {
        """
        UPDATE photo
           SET times_shown    = times_shown + 1,
               last_dealt_seq = :seq,
               shuffle_key    = :key,
               last_shown_at  = :now
         WHERE id = (SELECT p.id FROM photo p
                      WHERE \(eligibilityPredicate)
                        \(excludingReserved ? notAlreadyReserved : "")
                      ORDER BY p.shuffle_key
                      LIMIT 1 OFFSET :offset)
        RETURNING id, source_id, external_id, storage, cache_path;
        """
    }

    private static func candidatesStatement(excludingReserved: Bool) -> String {
        """
        SELECT p.id, p.source_id, p.external_id, p.storage, p.cache_path
          FROM photo p
         WHERE \(eligibilityPredicate)
           \(excludingReserved ? notAlreadyReserved : "")
         ORDER BY p.shuffle_key
         LIMIT :limit OFFSET :offset;
        """
    }
}
