import Foundation

/// The shared deck: one sequence, dealt from by every surface.
///
/// A photo is eligible when it has not been dealt within the last `w` deals.
/// Among the eligible, one is chosen uniformly at random. There are no epochs,
/// no passes, and no boundary — and therefore no boundary artifact to patch.
///
/// **On the selection step, which differs from PLAN.md.** The plan specifies
/// `ORDER BY shuffle_key LIMIT 1` over the eligible set, with the key re-rolled
/// on each deal. That starves. `LIMIT 1` on an ordering takes the *minimum*, and
/// only the winner's key is re-rolled — so a photo whose key lands high loses,
/// keeps its high key because it never won, and loses again, permanently. In
/// simulation at fraction 0.5 over twenty thousand deals of a hundred photos,
/// showings ranged from 3 to 391 and a photo with an initial key of 0.999 was
/// never shown at all.
///
/// The repair is one line of SQL: keep the indexed `shuffle_key` ordering, and
/// take a random offset into the eligible set rather than its first row. The
/// same simulation then gives showings between 186 and 217. `shuffle_key` keeps
/// both of its jobs — it supplies the index that makes selection cheap, and its
/// re-roll on deal keeps a hand's contiguous block from being the same
/// neighbourhood twice running.
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

    /// Photos the deck could deal, ignoring the repeat window: enabled source,
    /// available, and a still image.
    ///
    /// Cache residency is deliberately *not* part of this. Cards are reserved
    /// ahead of being needed and the prefetcher materialises what has been
    /// reserved, so requiring resident bytes here would mean the cache could
    /// never lead the deck.
    public func poolSize() throws -> Int {
        try database.scalarInt(Self.poolSizeSQL) ?? 0
    }

    /// The single monotonic ordinal, advanced by every card played anywhere in
    /// the system.
    public func currentDealSeq() throws -> Int64 {
        Int64(try database.scalarInt("SELECT deal_seq FROM deck_state WHERE id = 1;") ?? 0)
    }

    /// The repeat window in cards, given the current pool.
    public func repeatWindow(settings: DeckSettings = .default) throws -> Int {
        settings.repeatWindow(poolSize: try poolSize())
    }

    /// How many photos satisfy the window right now.
    func countEligible(seq: Int64, window: Int, ignoringOutstandingHands: Bool) throws -> Int {
        try database.scalarInt(
            ignoringOutstandingHands ? Self.countIgnoringHandsSQL : Self.countSQL,
            ["threshold": .int(seq - Int64(window) - 1)]
        ) ?? 0
    }

    // MARK: - Dealing

    /// The result of a deal: a card, plus whatever the deck had to give up to
    /// produce it.
    public struct Deal: Sendable, Equatable {
        public let card: DeckCard
        public let relaxations: [DeckRelaxation]
    }

    /// Deals one card and advances the deal ordinal.
    ///
    /// `BEGIN IMMEDIATE` takes the write lock up front rather than discovering
    /// the conflict at COMMIT, and `UPDATE … RETURNING` makes the deal and the
    /// read one round trip. Two processes racing are serialised by SQLite, and
    /// the loser gets the *next* card rather than the same one.
    ///
    /// Returns nil only when there is genuinely nothing to deal — an empty
    /// library. Every other scarcity is a relaxation rather than a failure.
    public func deal(settings: DeckSettings = .default, now: Date = Date()) throws -> Deal? {
        try database.transaction(.immediate) {
            let pool = try poolSize()
            guard pool > 0 else { return nil }

            let seq = try currentDealSeq() + 1
            let window = settings.repeatWindow(poolSize: pool)
            var relaxations: [DeckRelaxation] = []

            for candidateWindow in Self.relaxationLadder(from: window) {
                let eligible = try countEligible(
                    seq: seq, window: candidateWindow, ignoringOutstandingHands: false
                )
                guard eligible > 0 else { continue }
                if candidateWindow != window {
                    relaxations.append(.repeatWindowNarrowed(from: window, to: candidateWindow))
                }
                if let card = try dealOne(
                    sql: Self.dealSQL,
                    seq: seq,
                    window: candidateWindow,
                    offset: randomOffset(eligible),
                    now: now
                ) {
                    try commitDeal(seq: seq, relaxations: relaxations)
                    return Deal(card: card, relaxations: relaxations)
                }
            }

            // Every free card is spoken for by somebody's outstanding hand.
            // Overlap rather than starve: three displays and one photo means
            // all three show that photo.
            let anyCard = try countEligible(seq: seq, window: 0, ignoringOutstandingHands: true)
            if anyCard > 0 {
                relaxations.append(.reservedCardsReused)
                if let card = try dealOne(
                    sql: Self.dealIgnoringHandsSQL,
                    seq: seq,
                    window: 0,
                    offset: randomOffset(anyCard),
                    now: now
                ) {
                    try commitDeal(seq: seq, relaxations: relaxations)
                    return Deal(card: card, relaxations: relaxations)
                }
            }

            // pool > 0 and a window of zero with hands ignored matches every
            // dealable photo, so reaching here means the pool count and the
            // deal predicate have drifted apart.
            Log.deck.fault("pool reported \(pool, privacy: .public) photos but nothing was dealable")
            return nil
        }
    }

    private func dealOne(sql: String, seq: Int64, window: Int, offset: Int, now: Date) throws -> DeckCard? {
        try database.first(
            sql,
            [
                "seq": .int(seq),
                "threshold": .int(seq - Int64(window) - 1),
                "offset": .int(Int64(offset)),
                "key": .double(randomKey()),
                "now": SQLValue(now),
            ]
        ) { try DeckCard(row: $0, dealSeq: seq) }
    }

    private func commitDeal(seq: Int64, relaxations: [DeckRelaxation]) throws {
        try database.run("UPDATE deck_state SET deal_seq = :seq WHERE id = 1;", ["seq": .int(seq)])
        for relaxation in relaxations {
            try record(relaxation)
        }
    }

    /// `w`, then `w/2`, then `w/4` … down to 0, with duplicates removed.
    ///
    /// The window is halved rather than abandoned so a library that is merely
    /// *tight* keeps most of its spacing, and only a library that is genuinely
    /// too small for the setting ends up at zero.
    static func relaxationLadder(from window: Int) -> [Int] {
        var ladder: [Int] = []
        var current = window
        while current > 0 {
            ladder.append(current)
            current /= 2
        }
        ladder.append(0)
        return ladder
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
        seq: Int64,
        window: Int,
        ignoringOutstandingHands: Bool,
        offset: Int? = nil
    ) throws -> [DeckCard] {
        guard limit > 0 else { return [] }
        let eligible = try countEligible(
            seq: seq, window: window, ignoringOutstandingHands: ignoringOutstandingHands
        )
        guard eligible > 0 else { return [] }

        let sql = ignoringOutstandingHands ? Self.candidatesIgnoringHandsSQL : Self.candidatesSQL
        let start = offset ?? randomOffset(eligible)
        let bindings: (Int, Int) -> SQLBindings = { limit, offset in
            [
                "threshold": .int(seq - Int64(window) - 1),
                "limit": .int(Int64(limit)),
                "offset": .int(Int64(offset)),
            ]
        }

        var cards = try database.all(sql, bindings(limit, start)) { try DeckCard(row: $0, dealSeq: nil) }
        // Wrap, so a starting point near the end of the order does not produce
        // an artificially short hand.
        if cards.count < limit, start > 0 {
            cards += try database.all(sql, bindings(limit - cards.count, 0)) {
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
        return try selectCandidates(
            limit: count,
            seq: try currentDealSeq(),
            window: settings.repeatWindow(poolSize: pool),
            ignoringOutstandingHands: false,
            offset: 0
        )
    }

    // MARK: - Events

    /// Relaxations are recorded rather than swallowed, so `pgr deck stats` and
    /// eventually the settings UI can say that the repeat window is larger than
    /// the library can support.
    func record(_ relaxation: DeckRelaxation, at now: Date = Date()) throws {
        Log.deck.notice(
            "deck relaxed: \(relaxation.eventKind, privacy: .public) — \(relaxation.eventDetail, privacy: .public)"
        )
        try database.run(
            "INSERT INTO deck_event (at, kind, detail) VALUES (:at, :kind, :detail);",
            ["at": SQLValue(now), "kind": .text(relaxation.eventKind), "detail": .text(relaxation.eventDetail)]
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
            currentDealSeq: try currentDealSeq(),
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
    /// Photos the deck could deal right now, ignoring the repeat window.
    public let dealablePhotos: Int
    public let neverDealt: Int
    /// Photos whose bytes are resident — referenced in place or materialised.
    public let residentPhotos: Int
    public let currentDealSeq: Int64
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
