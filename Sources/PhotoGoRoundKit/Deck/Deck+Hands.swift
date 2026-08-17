import Foundation

/// One card of an outstanding hand.
public struct HandCard: Sendable, Equatable {
    public let card: DeckCard
    /// Order within the hand. Monotonic per consumer; gaps are normal, since
    /// played cards are discarded at the next reservation.
    public let position: Int
    public let reservedAt: Date

    init(row: Row) throws {
        card = try DeckCard(row: row, dealSeq: nil)
        position = try row.int("position")
        reservedAt = try row.date("reserved_at")
    }
}

/// What a reservation produced.
public struct HandReservation: Sendable, Equatable {
    public let consumerID: Int64
    /// The whole outstanding hand after topping up, in play order — not just
    /// the newly added cards. A consumer coming back from a restart gets its
    /// unfinished hand back rather than starting over.
    public let cards: [HandCard]
    public let newlyReserved: Int
    public let relaxations: [DeckRelaxation]
    public let startedNewPass: Bool
}

public struct ReapResult: Sendable, Equatable {
    public let consumersReaped: Int
    public let cardsReturned: Int
}

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
    /// Identity is `(kind, displayID)`, so the same monitor resumes its own
    /// rotation after a sleep or a cable swap rather than starting a new one.
    @discardableResult
    public func register(
        kind: ConsumerKind,
        displayID: String? = nil,
        handSize: Int,
        now: Date = Date()
    ) throws -> Consumer {
        try database.transaction(.immediate) {
            let clamped = min(max(handSize, 1), Consumer.maximumHandSize)
            let existing = try database.first(
                """
                SELECT id, kind, display_id, hand_size, seen_at, created_at
                  FROM consumer
                 WHERE kind = :kind AND IFNULL(display_id, '') = IFNULL(:display, '');
                """,
                ["kind": .text(kind.rawValue), "display": SQLValue(displayID)]
            ) { try Consumer(row: $0) }

            if let existing {
                // Hand size is a preference and may have changed since last
                // launch. Outstanding hands are left alone rather than resized;
                // the new size takes effect at the next reservation.
                try database.run(
                    "UPDATE consumer SET hand_size = :size, seen_at = :now WHERE id = :id;",
                    ["size": .int(Int64(clamped)), "now": SQLValue(now), "id": .int(existing.id)]
                )
                return try consumer(id: existing.id)!
            }

            try database.run(
                """
                INSERT INTO consumer (kind, display_id, hand_size, seen_at, created_at)
                VALUES (:kind, :display, :size, :now, :now);
                """,
                [
                    "kind": .text(kind.rawValue),
                    "display": SQLValue(displayID),
                    "size": .int(Int64(clamped)),
                    "now": SQLValue(now),
                ]
            )
            let id = database.lastInsertRowID
            Log.deck.notice(
                "registered consumer \(id, privacy: .public) of kind \(kind.rawValue, privacy: .public) with hand size \(clamped, privacy: .public)"
            )
            return try consumer(id: id)!
        }
    }

    public func consumer(id: Int64) throws -> Consumer? {
        try database.first(
            """
            SELECT id, kind, display_id, hand_size, seen_at, created_at
              FROM consumer WHERE id = :id;
            """,
            ["id": .int(id)]
        ) { try Consumer(row: $0) }
    }

    public func consumers() throws -> [Consumer] {
        try database.all(
            """
            SELECT id, kind, display_id, hand_size, seen_at, created_at
              FROM consumer ORDER BY kind, IFNULL(display_id, '');
            """
        ) { try Consumer(row: $0) }
    }

    /// The heartbeat the reaper keys off. Cheap enough to call on every tick.
    public func touch(consumerID: Int64, at now: Date = Date()) throws {
        try database.run(
            "UPDATE consumer SET seen_at = :now WHERE id = :id;",
            ["now": SQLValue(now), "id": .int(consumerID)]
        )
    }

    public func forget(consumerID: Int64) throws {
        // The hand rows cascade, which returns the unplayed ones to the deck.
        try database.run("DELETE FROM consumer WHERE id = :id;", ["id": .int(consumerID)])
    }
}

// MARK: - Hands

extension Deck {

    /// The cards this consumer holds and has not yet played, in play order.
    public func outstandingHand(for consumerID: Int64) throws -> [HandCard] {
        try database.all(
            """
            SELECT p.id, p.source_id, p.external_id, p.storage, p.cache_path,
                   h.position, h.reserved_at
              FROM hand h JOIN photo p ON p.id = h.photo_id
             WHERE h.consumer_id = :id AND h.played_at IS NULL
             ORDER BY h.position;
            """,
            ["id": .int(consumerID)]
        ) { try HandCard(row: $0) }
    }

    /// Reserves a contiguous block of cards from the shared deck, in one atomic
    /// operation.
    ///
    /// Tops the consumer's hand up to its size rather than replacing it, so a
    /// consumer that reserves early keeps what it has not played.
    ///
    /// **Reservation does not deal.** It marks cards as spoken for; the deal
    /// ordinal is assigned and the repeat window starts when a card is
    /// *played*. That is what lets an abandoned hand's cards return to the deck
    /// instead of silently thinning the library over weeks.
    ///
    /// A short hand is a normal result rather than an error — the consumer
    /// simply reserves again sooner.
    @discardableResult
    public func reserveHand(
        for consumerID: Int64,
        count: Int? = nil,
        settings: DeckSettings = .default,
        now: Date = Date()
    ) throws -> HandReservation {
        try database.transaction(.immediate) {
            guard let consumer = try consumer(id: consumerID) else {
                throw DeckError.unknownConsumer(id: consumerID)
            }
            try touch(consumerID: consumerID, at: now)

            // Played cards have served their purpose; dropping them here keeps
            // the table proportional to what is outstanding rather than to
            // everything ever shown.
            try database.run(
                "DELETE FROM hand WHERE consumer_id = :id AND played_at IS NOT NULL;",
                ["id": .int(consumerID)]
            )

            let target = min(max(count ?? consumer.handSize, 1), Consumer.maximumHandSize)
            var remaining = target - (try outstandingHand(for: consumerID).count)
            guard remaining > 0 else {
                return HandReservation(
                    consumerID: consumerID,
                    cards: try outstandingHand(for: consumerID),
                    newlyReserved: 0,
                    relaxations: [],
                    startedNewPass: false
                )
            }

            let pool = try poolSize()
            guard pool > 0 else {
                return HandReservation(
                    consumerID: consumerID, cards: [], newlyReserved: 0,
                    relaxations: [], startedNewPass: false
                )
            }

            let state = try state()
            let window = settings.repeatWindow(poolSize: pool)
            var threshold = Self.threshold(
                seq: state.dealSeq, passStartSeq: state.passStartSeq, window: window
            )
            var relaxations: [DeckRelaxation] = []
            var startedNewPass = false
            var reserved = 0
            var nextPosition = try nextHandPosition(for: consumerID)

            // Each batch is inserted before the next is selected, so the
            // exclusion predicate sees what this reservation has already taken
            // and a hand can never contain the same photo twice.
            func take(_ wanted: Int, excluding exclusion: Exclusion) throws {
                guard wanted > 0 else { return }
                let cards = try selectCandidates(
                    limit: wanted, threshold: threshold, excluding: exclusion
                )
                guard !cards.isEmpty else { return }
                try insert(cards, for: consumerID, startingAt: nextPosition, at: now)
                nextPosition += cards.count
                reserved += cards.count
                remaining -= cards.count
            }

            try take(remaining, excluding: .anyOutstandingHand)

            if remaining > 0 {
                // The pass is spent. Reshuffle and carry on — ordinary business,
                // not a concession.
                threshold = state.dealSeq
                startedNewPass = threshold != state.passStartSeq
                try take(remaining, excluding: .anyOutstandingHand)
            }

            if remaining > 0 {
                // Every remaining card is spoken for by somebody else's hand.
                // Overlap rather than starve — but never hand this consumer the
                // same photo twice.
                let before = remaining
                try take(remaining, excluding: .ownOutstandingHand(consumerID: consumerID))
                if remaining < before { relaxations.append(.reservedCardsReused) }
            }

            if remaining > 0 {
                relaxations.append(.handWasShort(asked: target, got: target - remaining))
            }

            if startedNewPass {
                try database.run(
                    "UPDATE deck_state SET pass_start_seq = :pass WHERE id = 1;",
                    ["pass": .int(threshold)]
                )
                Log.deck.notice(
                    "deck reshuffled during reservation; new pass begins at ordinal \(threshold, privacy: .public)"
                )
                try recordEvent(kind: "pass", detail: "reshuffled at ordinal \(threshold)", at: now)
            }
            for relaxation in relaxations {
                try record(relaxation, at: now)
            }

            Log.deck.debug(
                "consumer \(consumerID, privacy: .public) reserved \(reserved, privacy: .public) of \(target, privacy: .public) cards"
            )

            return HandReservation(
                consumerID: consumerID,
                cards: try outstandingHand(for: consumerID),
                newlyReserved: reserved,
                relaxations: relaxations,
                startedNewPass: startedNewPass
            )
        }
    }

    private func nextHandPosition(for consumerID: Int64) throws -> Int {
        let highest = try database.scalarInt(
            "SELECT MAX(position) FROM hand WHERE consumer_id = :id;", ["id": .int(consumerID)]
        )
        return (highest ?? -1) + 1
    }

    private func insert(_ cards: [DeckCard], for consumerID: Int64, startingAt start: Int, at now: Date) throws {
        for (offset, card) in cards.enumerated() {
            try database.run(
                """
                INSERT INTO hand (consumer_id, photo_id, position, reserved_at)
                VALUES (:consumer, :photo, :position, :now);
                """,
                [
                    "consumer": .int(consumerID),
                    "photo": .int(card.id),
                    "position": .int(Int64(start + offset)),
                    "now": SQLValue(now),
                ]
            )
        }
    }

    /// Plays the next unplayed card in the consumer's hand.
    ///
    /// **This is the deal.** The ordinal advances here, `times_shown` goes up,
    /// the shuffle key is re-rolled, and the repeat window starts counting.
    public func playNext(for consumerID: Int64, now: Date = Date()) throws -> DeckCard? {
        try database.transaction(.immediate) {
            let next = try database.first(
                """
                SELECT p.id, p.source_id, p.external_id, p.storage, p.cache_path,
                       h.position, h.reserved_at
                  FROM hand h JOIN photo p ON p.id = h.photo_id
                 WHERE h.consumer_id = :id AND h.played_at IS NULL
                 ORDER BY h.position
                 LIMIT 1;
                """,
                ["id": .int(consumerID)]
            ) { try HandCard(row: $0) }

            guard let next else { return nil }
            return try play(next, for: consumerID, now: now)
        }
    }

    /// Marks a specific card of a hand as played.
    @discardableResult
    public func play(_ handCard: HandCard, for consumerID: Int64, now: Date = Date()) throws -> DeckCard {
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
                    "seq": .int(seq),
                    "key": .double(randomKey()),
                    "now": SQLValue(now),
                    "id": .int(handCard.card.id),
                ]
            )
            try database.run(
                """
                UPDATE hand SET played_at = :now
                 WHERE consumer_id = :consumer AND position = :position;
                """,
                ["now": SQLValue(now), "consumer": .int(consumerID), "position": .int(Int64(handCard.position))]
            )
            try database.run(
                "UPDATE deck_state SET deal_seq = :seq WHERE id = 1;", ["seq": .int(seq)]
            )
            try touch(consumerID: consumerID, at: now)

            return DeckCard(
                id: handCard.card.id,
                sourceID: handCard.card.sourceID,
                externalID: handCard.card.externalID,
                storage: handCard.card.storage,
                cachePath: handCard.card.cachePath,
                dealSeq: seq
            )
        }
    }

    /// Returns a consumer's unplayed cards to the deck.
    ///
    /// A display that gets unplugged, or a screensaver that exits two minutes
    /// into a hundred-card hand, is holding cards nobody will see. Those must go
    /// back rather than being silently consumed, or the library visibly thins
    /// out over weeks.
    @discardableResult
    public func returnHand(for consumerID: Int64) throws -> Int {
        try database.transaction(.immediate) {
            try database.run(
                "DELETE FROM hand WHERE consumer_id = :id AND played_at IS NULL;",
                ["id": .int(consumerID)]
            )
            let returned = database.changes
            if returned > 0 {
                Log.deck.notice(
                    "returned \(returned, privacy: .public) unplayed cards from consumer \(consumerID, privacy: .public)"
                )
            }
            return returned
        }
    }

    /// Returns the unplayed cards of every consumer that has stopped checking
    /// in. Driven by the agent, not by the kit — this is policy, not schedule.
    @discardableResult
    public func reapAbandonedHands(idleFor: Duration, now: Date = Date()) throws -> ReapResult {
        try database.transaction(.immediate) {
            let cutoff = now.addingTimeInterval(-idleFor.totalSeconds)
            let abandoned = try database.all(
                """
                SELECT DISTINCT c.id FROM consumer c
                  JOIN hand h ON h.consumer_id = c.id AND h.played_at IS NULL
                 WHERE c.seen_at < :cutoff;
                """,
                ["cutoff": SQLValue(cutoff)]
            ) { try $0.int64("id") }

            guard !abandoned.isEmpty else { return ReapResult(consumersReaped: 0, cardsReturned: 0) }

            var returned = 0
            for consumerID in abandoned {
                try database.run(
                    "DELETE FROM hand WHERE consumer_id = :id AND played_at IS NULL;",
                    ["id": .int(consumerID)]
                )
                returned += database.changes
            }
            Log.deck.notice(
                "reaped \(abandoned.count, privacy: .public) abandoned hands, returning \(returned, privacy: .public) cards"
            )
            return ReapResult(consumersReaped: abandoned.count, cardsReturned: returned)
        }
    }

    /// Every unplayed card across every outstanding hand, in reservation order.
    ///
    /// This is the prefetcher's work list: the cache no longer has to guess what
    /// is needed soon, because reserved hands *are* the answer, explicitly.
    public func outstandingCards() throws -> [DeckCard] {
        try database.all(
            """
            SELECT p.id, p.source_id, p.external_id, p.storage, p.cache_path
              FROM hand h JOIN photo p ON p.id = h.photo_id
             WHERE h.played_at IS NULL
             ORDER BY h.consumer_id, h.position;
            """
        ) { try DeckCard(row: $0, dealSeq: nil) }
    }

    /// The photos the evictor must not touch, whatever their age.
    ///
    /// "Never evict inside the deal horizon" becomes "never evict a card in an
    /// outstanding hand" once hands exist, which is a set the database can
    /// answer exactly rather than a guess about how far ahead to look.
    public func outstandingPhotoIDs() throws -> Set<Int64> {
        Set(
            try database.all("SELECT DISTINCT photo_id FROM hand WHERE played_at IS NULL;") {
                try $0.int64("photo_id")
            }
        )
    }

    /// Drops a photo out of rotation immediately, returning any outstanding
    /// card for it.
    ///
    /// The fast path for a card whose file turns out to be missing at play time:
    /// mark it on the spot and move on, rather than showing a gap while waiting
    /// for the next scheduled scan.
    public func markUnavailable(photoID: Int64, reason: String? = nil) throws {
        try database.transaction(.immediate) {
            try database.run(
                "UPDATE photo SET available = 0 WHERE id = :id;", ["id": .int(photoID)]
            )
            try database.run(
                "DELETE FROM hand WHERE photo_id = :id AND played_at IS NULL;", ["id": .int(photoID)]
            )
        }
        Log.deck.notice(
            "photo \(photoID, privacy: .public) marked unavailable: \(reason ?? "not stated", privacy: .public)"
        )
    }
}
