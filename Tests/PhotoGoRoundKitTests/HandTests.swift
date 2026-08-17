import Foundation
import Testing

@testable import PhotoGoRoundKit

@Suite("Consumers and hands")
struct HandTests {

    // MARK: - Consumer identity

    @Test("Registering twice returns the same consumer")
    func registrationIsIdempotent() throws {
        let library = try TestLibrary()
        let first = try library.deck.register(kind: .screensaver, displayID: "DISPLAY-A", handSize: 100)
        let second = try library.deck.register(kind: .screensaver, displayID: "DISPLAY-A", handSize: 100)
        #expect(first.id == second.id)
        #expect(try library.deck.consumers().count == 1)
    }

    @Test("A different display is a different consumer")
    func displaysAreDistinctConsumers() throws {
        let library = try TestLibrary()
        let a = try library.deck.register(kind: .screensaver, displayID: "DISPLAY-A", handSize: 100)
        let b = try library.deck.register(kind: .screensaver, displayID: "DISPLAY-B", handSize: 100)
        let none = try library.deck.register(kind: .widget, handSize: 8)
        #expect(Set([a.id, b.id, none.id]).count == 3)
    }

    @Test("Re-registering updates the hand size without disturbing the hand")
    func handSizeIsAPreference() throws {
        let (library, _) = try TestLibrary.withPhotos(50)
        let consumer = try library.deck.register(kind: .screensaver, handSize: 5)
        try library.deck.reserveHand(for: consumer.id)
        #expect(try library.deck.outstandingHand(for: consumer.id).count == 5)

        // Outstanding hands are left alone rather than resized; the new size
        // takes effect at the next reservation.
        let resized = try library.deck.register(kind: .screensaver, handSize: 12)
        #expect(resized.id == consumer.id)
        #expect(resized.handSize == 12)
        #expect(try library.deck.outstandingHand(for: consumer.id).count == 5)

        try library.deck.reserveHand(for: consumer.id)
        #expect(try library.deck.outstandingHand(for: consumer.id).count == 12)
    }

    @Test("An unknown consumer is an error, not a silent no-op")
    func reservingForAnUnknownConsumerThrows() throws {
        let library = try TestLibrary()
        #expect(throws: DeckError.self) {
            try library.deck.reserveHand(for: 999)
        }
    }

    // MARK: - Hand sizing

    @Test("Hand size comes from the consumer's interval")
    func handSizeDerivesFromInterval() {
        // A screensaver at one photo per ten seconds: twenty minutes of cover.
        #expect(Consumer.handSize(forInterval: .seconds(10)) == 120)
        // A wallpaper at one per half hour hits the floor, which gives it two
        // hours rather than a single card.
        #expect(Consumer.handSize(forInterval: .seconds(30 * 60)) == 4)
        #expect(Consumer.handSize(forInterval: .seconds(60)) == 20)
        // And a nonsensical interval does not produce a nonsensical hand.
        #expect(Consumer.handSize(forInterval: .zero) == Consumer.maximumHandSize)
        #expect(Consumer.handSize(forInterval: .milliseconds(1)) == Consumer.maximumHandSize)
    }

    // MARK: - Reservation does not deal

    @Test("Reserving marks cards spoken for without dealing them")
    func reservationDoesNotDeal() throws {
        let (library, _) = try TestLibrary.withPhotos(20)
        let consumer = try library.deck.register(kind: .screensaver, handSize: 6)
        let reservation = try library.deck.reserveHand(for: consumer.id)

        #expect(reservation.cards.count == 6)
        #expect(reservation.newlyReserved == 6)
        #expect(reservation.relaxations.isEmpty)

        // The deal ordinal has not moved, nothing has been shown, and no repeat
        // window has started counting.
        #expect(try library.deck.currentDealSeq() == 0)
        #expect(try library.database.scalarInt("SELECT SUM(times_shown) FROM photo;") == 0)
        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM photo WHERE last_dealt_seq IS NOT NULL;") == 0)
    }

    @Test("Playing is the deal")
    func playingAdvancesTheDeck() throws {
        let (library, _) = try TestLibrary.withPhotos(20)
        let consumer = try library.deck.register(kind: .screensaver, handSize: 3)
        let reservation = try library.deck.reserveHand(for: consumer.id)
        let first = reservation.cards[0]

        let keyBefore = try library.database.first(
            "SELECT shuffle_key FROM photo WHERE id = :id;", ["id": .int(first.card.id)]
        ) { try $0.double("shuffle_key") }

        let played = try #require(try library.deck.playNext(for: consumer.id))
        #expect(played.id == first.card.id)
        #expect(played.dealSeq == 1)
        #expect(try library.deck.currentDealSeq() == 1)

        let after = try library.database.first(
            "SELECT times_shown, last_dealt_seq, shuffle_key FROM photo WHERE id = :id;",
            ["id": .int(first.card.id)]
        ) { (try $0.int("times_shown"), try $0.optionalInt64("last_dealt_seq"), try $0.double("shuffle_key")) }
        let state = try #require(after)
        #expect(state.0 == 1)
        #expect(state.1 == 1)
        #expect(state.2 != keyBefore)

        // And it is out of the outstanding hand.
        #expect(try library.deck.outstandingHand(for: consumer.id).count == 2)
    }

    @Test("Cards are played in the order they were reserved")
    func handIsPlayedInOrder() throws {
        let (library, _) = try TestLibrary.withPhotos(20)
        let consumer = try library.deck.register(kind: .screensaver, handSize: 5)
        let reserved = try library.deck.reserveHand(for: consumer.id).cards.map(\.card.id)

        var played: [Int64] = []
        while let card = try library.deck.playNext(for: consumer.id) {
            played.append(card.id)
        }
        #expect(played == reserved)
    }

    @Test("Reserving tops the hand up rather than replacing it")
    func reservationTopsUp() throws {
        let (library, _) = try TestLibrary.withPhotos(50)
        let consumer = try library.deck.register(kind: .screensaver, handSize: 10)
        let firstHand = try library.deck.reserveHand(for: consumer.id).cards.map(\.card.id)
        _ = try library.deck.playNext(for: consumer.id)
        _ = try library.deck.playNext(for: consumer.id)

        let second = try library.deck.reserveHand(for: consumer.id)
        #expect(second.newlyReserved == 2)
        #expect(second.cards.count == 10)
        // The eight unplayed cards survived, in order, and kept their places.
        #expect(second.cards.prefix(8).map(\.card.id) == Array(firstHand.dropFirst(2)))
        // Played rows are discarded rather than accumulating.
        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM hand;") == 10)
    }

    // MARK: - Disjointness

    @Test("Two consumers get disjoint hands")
    func handsAreDisjoint() throws {
        let (library, _) = try TestLibrary.withPhotos(50)
        let one = try library.deck.register(kind: .wallpaper, displayID: "A", handSize: 10)
        let two = try library.deck.register(kind: .wallpaper, displayID: "B", handSize: 10)

        let first = Set(try library.deck.reserveHand(for: one.id).cards.map(\.card.id))
        let second = Set(try library.deck.reserveHand(for: two.id).cards.map(\.card.id))
        #expect(first.count == 10)
        #expect(second.count == 10)
        #expect(first.isDisjoint(with: second))
    }

    @Test("A hand never contains the same photo twice")
    func handsHaveNoDuplicates() throws {
        // Deliberately more cards wanted than exist, so every fallback path runs.
        let (library, ids) = try TestLibrary.withPhotos(5)
        let consumer = try library.deck.register(kind: .screensaver, handSize: 40)
        let hand = try library.deck.reserveHand(for: consumer.id).cards.map(\.card.id)
        #expect(Set(hand).count == hand.count)
        #expect(Set(hand) == Set(ids))
    }

    @Test("Wrapping past the cut does not re-deal the cards before it")
    func wrappingDoesNotDuplicate() throws {
        // Force the offset to the far end of the eligible set, so the wrap is
        // exercised on every reservation rather than by luck.
        let (library, ids) = try TestLibrary.withPhotos(20)
        let deck = Deck(
            database: library.database,
            randomKey: { Double.random(in: 0..<1) },
            randomOffset: { max($0 - 1, 0) }
        )
        let consumer = try deck.register(kind: .screensaver, handSize: 12)
        let hand = try deck.reserveHand(for: consumer.id).cards.map(\.card.id)
        #expect(hand.count == 12)
        #expect(Set(hand).count == 12)
        #expect(Set(hand).isSubset(of: Set(ids)))
    }

    // MARK: - Scarcity

    @Test("A short hand is a normal result, not an error")
    func shortHandsAreNormal() throws {
        let (library, ids) = try TestLibrary.withPhotos(3)
        let consumer = try library.deck.register(kind: .screensaver, handSize: 10)
        let reservation = try library.deck.reserveHand(for: consumer.id)

        #expect(reservation.cards.count == 3)
        #expect(Set(reservation.cards.map(\.card.id)) == Set(ids))
        #expect(reservation.relaxations.contains(.handWasShort(asked: 10, got: 3)))

        let events = try library.deck.recentEvents()
        #expect(events.contains { $0.kind == "short_hand" })
    }

    @Test("When the deck is exhausted, consumers overlap rather than starve")
    func consumersOverlapUnderScarcity() throws {
        // One photo, three displays: all three show that photo.
        let (library, ids) = try TestLibrary.withPhotos(1)
        var hands: [[Int64]] = []
        for display in ["A", "B", "C"] {
            let consumer = try library.deck.register(kind: .wallpaper, displayID: display, handSize: 1)
            let reservation = try library.deck.reserveHand(for: consumer.id)
            hands.append(reservation.cards.map(\.card.id))
            if display != "A" {
                #expect(reservation.relaxations.contains(.reservedCardsReused))
            }
        }
        #expect(hands == [[ids[0]], [ids[0]], [ids[0]]])
    }

    @Test("Overlap still never repeats a photo inside one hand")
    func overlapDoesNotDuplicateWithinAHand() throws {
        let (library, ids) = try TestLibrary.withPhotos(4)
        let hog = try library.deck.register(kind: .screensaver, handSize: 4)
        try library.deck.reserveHand(for: hog.id)

        // Everything is spoken for, so this consumer has to overlap — but it
        // must still get four distinct photos, not one photo four times.
        let second = try library.deck.register(kind: .app, handSize: 4)
        let reservation = try library.deck.reserveHand(for: second.id)
        let hand = reservation.cards.map(\.card.id)
        #expect(hand.count == 4)
        #expect(Set(hand) == Set(ids))
        #expect(reservation.relaxations.contains(.reservedCardsReused))
    }

    @Test("A reservation that outruns the pass reshuffles and carries on")
    func reservationCrossesAPassBoundary() throws {
        let (library, ids) = try TestLibrary.withPhotos(6)
        let consumer = try library.deck.register(kind: .screensaver, handSize: 4)
        let settings = DeckSettings(repeatWindowFraction: 1.0)

        try library.deck.reserveHand(for: consumer.id, settings: settings)
        while try library.deck.playNext(for: consumer.id) != nil {}
        #expect(try library.deck.currentDealSeq() == 4)

        // Only two cards are left unused in this pass, so the reservation takes
        // those and then reshuffles for the rest.
        let second = try library.deck.reserveHand(for: consumer.id, settings: settings)
        #expect(second.cards.count == 4)
        #expect(second.startedNewPass)
        #expect(second.relaxations.isEmpty)
        #expect(Set(second.cards.map(\.card.id)).count == 4)
        #expect(Set(second.cards.map(\.card.id)).isSubset(of: Set(ids)))
        #expect(try library.deck.state().passStartSeq == 4)
    }

    // MARK: - Giving cards back

    @Test("Returning a hand puts its unplayed cards back in the deck")
    func returningAHandReleasesItsCards() throws {
        let (library, _) = try TestLibrary.withPhotos(20)
        let consumer = try library.deck.register(kind: .screensaver, handSize: 10)
        let reserved = Set(try library.deck.reserveHand(for: consumer.id).cards.map(\.card.id))
        _ = try library.deck.playNext(for: consumer.id)

        let returned = try library.deck.returnHand(for: consumer.id)
        #expect(returned == 9)
        #expect(try library.deck.outstandingHand(for: consumer.id).isEmpty)

        // The nine unplayed cards are available to somebody else again, and were
        // never counted as shown.
        let other = try library.deck.register(kind: .app, handSize: 20)
        let now = Set(try library.deck.reserveHand(for: other.id).cards.map(\.card.id))
        #expect(reserved.subtracting([reserved.first!]).intersection(now).count >= 9 - 1)
        #expect(try library.database.scalarInt("SELECT SUM(times_shown) FROM photo;") == 1)
    }

    @Test("The reaper returns abandoned hands and leaves live ones alone")
    func reaperReclaimsAbandonedHands() throws {
        let (library, _) = try TestLibrary.withPhotos(40)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let gone = try library.deck.register(kind: .screensaver, handSize: 10, now: now)
        try library.deck.reserveHand(for: gone.id, now: now)
        let alive = try library.deck.register(kind: .wallpaper, displayID: "A", handSize: 10, now: now)
        try library.deck.reserveHand(for: alive.id, now: now)

        // An hour later, only the wallpaper has checked in.
        let later = now.addingTimeInterval(3600)
        try library.deck.touch(consumerID: alive.id, at: later)

        let result = try library.deck.reapAbandonedHands(idleFor: .seconds(600), now: later)
        #expect(result.consumersReaped == 1)
        #expect(result.cardsReturned == 10)
        #expect(try library.deck.outstandingHand(for: gone.id).isEmpty)
        #expect(try library.deck.outstandingHand(for: alive.id).count == 10)

        // The consumer row survives — a display does not stop existing because
        // it went quiet for an hour.
        #expect(try library.deck.consumers().count == 2)
    }

    @Test("Reaping is a no-op when everyone is checking in")
    func reaperIsQuietWhenAllIsWell() throws {
        let (library, _) = try TestLibrary.withPhotos(20)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let consumer = try library.deck.register(kind: .screensaver, handSize: 5, now: now)
        try library.deck.reserveHand(for: consumer.id, now: now)

        let result = try library.deck.reapAbandonedHands(idleFor: .seconds(600), now: now)
        #expect(result == ReapResult(consumersReaped: 0, cardsReturned: 0))
        #expect(try library.deck.outstandingHand(for: consumer.id).count == 5)
    }

    @Test("Deleting a consumer returns its cards")
    func forgettingAConsumerReleasesItsHand() throws {
        let (library, _) = try TestLibrary.withPhotos(20)
        let consumer = try library.deck.register(kind: .screensaver, handSize: 8)
        try library.deck.reserveHand(for: consumer.id)
        try library.deck.forget(consumerID: consumer.id)
        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM hand;") == 0)
        #expect(try library.deck.outstandingPhotoIDs().isEmpty)
    }

    // MARK: - What the cache needs from hands

    @Test("Outstanding cards are the prefetcher's work list, in reservation order")
    func outstandingCardsAreTheWorkList() throws {
        let (library, _) = try TestLibrary.withPhotos(50)
        let one = try library.deck.register(kind: .wallpaper, displayID: "A", handSize: 4)
        let two = try library.deck.register(kind: .screensaver, handSize: 6)
        let firstHand = try library.deck.reserveHand(for: one.id).cards.map(\.card.id)
        let secondHand = try library.deck.reserveHand(for: two.id).cards.map(\.card.id)

        #expect(try library.deck.outstandingCards().map(\.id) == firstHand + secondHand)
        #expect(try library.deck.outstandingPhotoIDs() == Set(firstHand + secondHand))

        // Playing a card takes it off the list — its bytes are no longer needed.
        _ = try library.deck.playNext(for: one.id)
        #expect(try library.deck.outstandingCards().count == 9)
    }

    @Test("A photo that turns out to be missing leaves the deck and every hand")
    func markingUnavailableReleasesOutstandingCards() throws {
        let (library, _) = try TestLibrary.withPhotos(10)
        let consumer = try library.deck.register(kind: .screensaver, handSize: 10)
        let hand = try library.deck.reserveHand(for: consumer.id).cards
        let doomed = hand[3].card.id

        try library.deck.markUnavailable(photoID: doomed, reason: "file missing at play time")

        #expect(try library.deck.poolSize() == 9)
        #expect(!(try library.deck.outstandingHand(for: consumer.id).map(\.card.id).contains(doomed)))
        #expect(try library.deck.outstandingHand(for: consumer.id).count == 9)
        // The row survives, so its history is intact if the volume comes back.
        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 10)
    }

    // MARK: - Several processes at once

    @Test("Concurrent reservations from separate connections stay disjoint")
    func concurrentReservationsAreDisjoint() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-hands-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try TestLibrary.onDisk(at: directory)
        let source = try library.addSource()
        _ = try library.addPhotos(400, to: source)
        let path = TestLibrary.path(in: directory)

        let workers = 4
        let handSize = 50
        let collected = Mutex<[Int64]>([])

        // Each worker is its own process in the real system: an agent, an app,
        // a saver. Here, its own connection.
        DispatchQueue.concurrentPerform(iterations: workers) { index in
            guard let database = try? Database(path: path) else { return }
            let deck = Deck(database: database)
            guard
                let consumer = try? deck.register(
                    kind: .wallpaper, displayID: "DISPLAY-\(index)", handSize: handSize
                ),
                let reservation = try? deck.reserveHand(
                    for: consumer.id, settings: DeckSettings(repeatWindowFraction: 1.0)
                )
            else { return }
            collected.withLock { $0.append(contentsOf: reservation.cards.map(\.card.id)) }
        }

        let reserved = collected.withLock { $0 }
        #expect(reserved.count == workers * handSize)
        // 200 cards from a 400-photo pool: there is room for every hand to be
        // disjoint, so any duplicate is a lost race.
        #expect(Set(reserved).count == reserved.count, "a card was reserved twice")
        #expect(try library.deck.outstandingPhotoIDs().count == reserved.count)
        // And nothing was dealt, because nothing was played.
        #expect(try library.deck.currentDealSeq() == 0)
    }
}
