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
/// selection cheap, and its re-roll on showing churns the order so consecutive
/// requests to one source do not walk the same neighbourhood.
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

    /// Photos the deck could offer, ignoring the pass and the window: enabled
    /// source, still image.
    ///
    /// Cache residency is deliberately *not* part of this. A picture is selected
    /// before its bytes are fetched, so requiring resident bytes here would mean
    /// nothing could ever be selected in the first place.
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

    /// Pictures not yet used in the current pass. Counts down to zero, at which
    /// point the deck reshuffles.
    public func unusedInCurrentPass() throws -> Int {
        let state = try state()
        return try database.scalarInt(
            Self.unusedCountSQL, ["threshold": .int(state.passStartSeq)]
        ) ?? 0
    }

    // MARK: - Events

    /// Notable moments, recorded rather than swallowed, so `pgr deck stats` and
    /// eventually the settings UI can say what the deck has been doing. A pass
    /// boundary is the only one so far.
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
    static let poolSizeSQL = """
        SELECT COUNT(*) FROM photo p
         WHERE p.source_enabled = 1 AND p.media_type = 'image';
        """

    static let unusedCountSQL = """
        SELECT COUNT(*) FROM photo p
         WHERE p.source_enabled = 1 AND p.media_type = 'image'
           AND (p.last_dealt_seq IS NULL OR p.last_dealt_seq <= :threshold);
        """
}
