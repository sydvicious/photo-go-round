import Foundation
import PhotoGoRoundAgentAPI

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
    /// source, still image. **Neither whether the bytes are here nor whether
    /// the source is reachable is asked.**
    ///
    /// Residency was part of this from 2026-08-26 to 2026-09-05, and the
    /// reversal is the plan's *Deal over everything, and the queue fetches its
    /// own cards*. Dealing only what was held paced a new source's arrival on
    /// screen to the cache's download rate, which was one photograph per
    /// picture served: forty-one Photos albums, 57% of the library, held 14% of
    /// the pool ten minutes after they were added and would have taken three
    /// hours to reach their share. A card with no bytes is dealt, and the queue
    /// fetches it before its turn.
    ///
    /// **The repeat window is a fraction of this number**, so it measures
    /// against the whole available library again.
    public func poolSize() throws -> Int {
        try database.scalarInt(Self.poolSizeSQL) ?? 0
    }

    /// One card by its photograph's id, for a caller holding an identifier and
    /// nothing else — the queue of pictures to cache, which carries ids because
    /// what it is asked to fetch may be gone by the time it gets there.
    public func card(photoID: Int64) throws -> DeckCard? {
        try database.first(
            """
            SELECT p.id, p.uuid, p.source_id, s.uuid AS source_uuid, p.external_id, p.storage
              FROM photo p JOIN source s ON s.id = p.source_id
             WHERE p.id = :id;
            """,
            ["id": .int(photoID)]
        ) { try DeckCard(row: $0, dealSeq: nil) }
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

    /// How many photos have been shown *n* times, for each *n*.
    ///
    /// `times_shown` is a statistic and nothing orders by it, which is precisely
    /// what makes it the honest measure of whether the deck is behaving. A
    /// spread of one to three across a library is a healthy fraction below 1.0;
    /// a spread of three to four hundred is the starvation this deck was
    /// rewritten to remove, and it is invisible in every other number.
    public func showingHistogram(limit: Int = 20) throws -> [(shown: Int, photos: Int)] {
        try database.all(
            """
            SELECT times_shown AS shown, COUNT(*) AS photos
              FROM photo WHERE source_enabled = 1 AND media_type = 'image'
             GROUP BY times_shown ORDER BY times_shown LIMIT :limit;
            """,
            ["limit": .int(Int64(limit))]
        ) { (shown: try $0.int("shown"), photos: try $0.int("photos")) }
    }

    public func stats(settings: DeckSettings = .default) throws -> DeckStats {
        let pool = try poolSize()
        let state = try state()
        let counts = try database.first(
            """
            SELECT COUNT(*)                                                  AS total,
                   SUM(CASE WHEN last_dealt_seq IS NULL THEN 1 ELSE 0 END)   AS never_dealt,
                   IFNULL(MIN(times_shown), 0)                               AS shown_min,
                   IFNULL(MAX(times_shown), 0)                               AS shown_max,
                   IFNULL(SUM(times_shown), 0)                               AS shown_total
              FROM photo;
            """
        ) { row in
            (
                total: try row.int("total"),
                neverDealt: try row.optionalInt("never_dealt") ?? 0,
                min: try row.int("shown_min"),
                max: try row.int("shown_max"),
                shownTotal: try row.int("shown_total")
            )
        }

        return DeckStats(
            totalPhotos: counts?.total ?? 0,
            dealablePhotos: pool,
            neverDealt: counts?.neverDealt ?? 0,
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

    /// **Every available photograph**, which is the whole of the population:
    /// its source enabled, and a still image.
    ///
    /// Two things are deliberately not in it. **Residency**: `cached_at` stays
    /// a column for eviction order and reporting, but from 2026-08-26 to
    /// 2026-09-05 it was also the gate here, and that paced a new source's
    /// arrival on screen to the download rate — see `poolSize()`. And
    /// **reachability**: `source.available` is what the panel shows and what
    /// the scan writes, and the deal does not read it. A photograph we hold is
    /// served out of the cache whether or not its source is there, so the
    /// whole thing works with no network at all once it has run for a while;
    /// a photograph we do not hold from a source that is away fails its fetch
    /// and is dropped, which is the ordinary failure path and needs no gate in
    /// front of it. Decided 2026-09-05, after trying reachability as a gate and
    /// then as a gate with a door for held photographs, and wanting neither.
    ///
    /// v1 selects still images only. The exclusion is a named predicate rather
    /// than an absence of video code, which is the difference between 2.0 being
    /// a feature and being an excavation.
    static let availablePredicate = """
        p.source_enabled = 1 AND p.media_type = 'image'
        """

    static let poolSizeSQL = """
        SELECT COUNT(*) FROM photo p
         WHERE \(availablePredicate);
        """

    static let unusedCountSQL = """
        SELECT COUNT(*) FROM photo p
         WHERE \(availablePredicate)
           AND (p.last_dealt_seq IS NULL OR p.last_dealt_seq <= :threshold);
        """
}
