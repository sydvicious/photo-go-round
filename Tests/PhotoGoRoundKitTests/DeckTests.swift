import Foundation
import Testing

@testable import PhotoGoRoundKit

@Suite("Deck")
struct DeckTests {

    // MARK: - The window arithmetic

    @Test("Fraction 1.0 gives a window of the whole pool, so the pass is the only rule")
    func fractionOneWindowIsTheWholePool() {
        let settings = DeckSettings(repeatWindowFraction: 1.0)
        #expect(settings.repeatWindow(poolSize: 100) == 100)
        #expect(settings.repeatWindow(poolSize: 2) == 2)
        // The window is meant to be unsatisfiable at 1.0: it is the pass
        // boundary that releases a photo, not the window.
    }

    @Test("An empty pool has no window")
    func emptyPoolHasNoWindow() {
        #expect(DeckSettings(repeatWindowFraction: 1.0).repeatWindow(poolSize: 0) == 0)
    }

    @Test("Eligibility collapses the pass and the window into one comparison")
    func thresholdIsTheLooserOfTheTwoRules() {
        // Mid-pass at fraction 1.0, the window term is always the smaller of the
        // two and drops out on its own — no branch, no special case.
        #expect(Deck.threshold(seq: 150, passStartSeq: 100, window: 100) == 100)
        // Below 1.0 the window is what bites, once the pass has run long enough.
        #expect(Deck.threshold(seq: 150, passStartSeq: 100, window: 20) == 129)
    }

    @Test("The default fraction is half the pool")
    func defaultFractionIsAHalf() {
        #expect(DeckSettings.default.repeatWindowFraction == 0.5)
        #expect(DeckSettings.default.repeatWindow(poolSize: 100) == 50)
        #expect(DeckSettings.default.repeatWindow(poolSize: 4) == 2)
    }

    @Test("An out-of-range fraction is clamped rather than accepted")
    func fractionIsClamped() {
        // `defaults write` accepts anything, so every read is a parse with a
        // default and a clamp.
        #expect(DeckSettings(repeatWindowFraction: -3).repeatWindowFraction == 0)
        #expect(DeckSettings(repeatWindowFraction: 42).repeatWindowFraction == 1)
        #expect(DeckSettings(repeatWindowFraction: .nan).repeatWindowFraction == 0.5)
        #expect(DeckSettings(repeatWindowFraction: .infinity).repeatWindowFraction == 0.5)
    }

    // MARK: - Dealing at all

    @Test("An empty library deals nothing rather than failing")
    func emptyLibraryDealsNil() throws {
        let library = try TestLibrary()
        #expect(try library.deck.deal() == nil)
        #expect(try library.deck.currentDealSeq() == 0)
    }

    @Test("A deal advances the ordinal, the count, and the shuffle key")
    func dealAdvancesEverything() throws {
        let (library, ids) = try TestLibrary.withPhotos(1)
        let before = try library.database.first(
            "SELECT shuffle_key FROM photo WHERE id = :id;", ["id": .int(ids[0])]
        ) { try $0.double("shuffle_key") }

        let deal = try #require(try library.deck.deal())
        #expect(deal.card.id == ids[0])
        #expect(deal.card.dealSeq == 1)
        #expect(try library.deck.currentDealSeq() == 1)

        let after = try library.database.first(
            "SELECT times_shown, last_dealt_seq, shuffle_key, last_shown_at FROM photo WHERE id = :id;",
            ["id": .int(ids[0])]
        ) { row in
            (
                shown: try row.int("times_shown"),
                seq: try row.optionalInt64("last_dealt_seq"),
                key: try row.double("shuffle_key"),
                at: try row.optionalDate("last_shown_at")
            )
        }
        let state = try #require(after)
        #expect(state.shown == 1)
        #expect(state.seq == 1)
        #expect(state.at != nil)
        #expect(state.key != before)
    }

    @Test("A one-photo library keeps dealing that photo")
    func onePhotoLibraryNeverStarves() throws {
        let (library, ids) = try TestLibrary.withPhotos(1)
        let dealt = try library.deck.dealSequence(count: 5, settings: .default)
        #expect(dealt == Array(repeating: ids[0], count: 5))
    }

    @Test("A card never dealt is eligible the moment it arrives")
    func newPhotosCompeteImmediately() throws {
        let (library, _) = try TestLibrary.withPhotos(4)
        let settings = DeckSettings(repeatWindowFraction: 1.0)
        _ = try library.deck.dealSequence(count: 4, settings: settings)

        // A photo inserted mid-run has a null deal ordinal, so it is eligible
        // by definition and needs no special placement.
        let source = try library.database.scalarInt("SELECT id FROM source LIMIT 1;")
        let newcomers = try library.addPhotos(1, to: Int64(source!), namePrefix: "newcomer")
        // At fraction 1.0 nothing already dealt has served out its window yet,
        // so the newcomer is the only eligible card.
        let next = try #require(try library.deck.deal(settings: settings))
        #expect(next.card.id == newcomers[0])
    }

    // MARK: - What is excluded from the deck

    @Test("A disabled source's photos leave the deck but keep their history")
    func disablingASourceDropsItFromTheDeck() throws {
        let library = try TestLibrary()
        let keep = try library.addSource(locator: "/keep")
        let drop = try library.addSource(locator: "/drop")
        let kept = try library.addPhotos(3, to: keep, namePrefix: "keep")
        let dropped = try library.addPhotos(3, to: drop, namePrefix: "drop")

        _ = try library.deck.dealSequence(count: 6, settings: DeckSettings(repeatWindowFraction: 1.0))
        try library.setSourceEnabled(drop, false)

        #expect(try library.deck.poolSize() == 3)
        let after = Set(try library.deck.dealSequence(count: 12, settings: .default))
        #expect(after.isSubset(of: Set(kept)))
        #expect(after.isDisjoint(with: Set(dropped)))

        // Disabling is not deleting: the history survives for when it comes back.
        let shown = try library.database.scalarInt(
            "SELECT SUM(times_shown) FROM photo WHERE source_id = :id;", ["id": .int(drop)]
        )
        #expect(shown == 3)
    }

    @Test("An unavailable photo is unreachable the moment the flag flips")
    func unavailablePhotosAreNotDealt() throws {
        let (library, ids) = try TestLibrary.withPhotos(3)
        try library.setAvailable(ids[0], false)
        #expect(try library.deck.poolSize() == 2)
        let dealt = Set(try library.deck.dealSequence(count: 20, settings: .default))
        #expect(!dealt.contains(ids[0]))
    }

    @Test("Videos are in the database and never in the deck")
    func videosAreNeverDealt() throws {
        let library = try TestLibrary()
        let source = try library.addSource()
        let images = try library.addPhotos(2, to: source, namePrefix: "still")
        let videos = try library.addPhotos(5, to: source, mediaType: .video, namePrefix: "clip")

        #expect(try library.deck.poolSize() == 2)
        let dealt = Set(try library.deck.dealSequence(count: 20, settings: .default))
        #expect(dealt == Set(images))
        #expect(dealt.isDisjoint(with: Set(videos)))

        // The rows exist, which is what makes 2.0 a predicate change rather
        // than a rescan.
        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 7)
    }

    @Test("A card in an outstanding hand is spoken for")
    func reservedCardsAreNotDealt() throws {
        let (library, ids) = try TestLibrary.withPhotos(3)
        let consumer = try library.addConsumer(kind: "screensaver")
        try library.reserve(ids[0], consumerID: consumer, position: 0)

        let dealt = Set(try library.deck.dealSequence(count: 10, settings: .default))
        #expect(!dealt.contains(ids[0]))
    }

    @Test("A played card is no longer spoken for")
    func playedCardsReturnToTheDeck() throws {
        let (library, ids) = try TestLibrary.withPhotos(2)
        let consumer = try library.addConsumer(kind: "screensaver")
        try library.reserve(ids[0], consumerID: consumer, position: 0)
        try library.database.run("UPDATE hand SET played_at = 1 WHERE photo_id = :p;", ["p": .int(ids[0])])

        let dealt = Set(try library.deck.dealSequence(count: 10, settings: .default))
        #expect(dealt.contains(ids[0]))
    }

    // MARK: - Scarcity degrades, it never starves

    @Test("When every card is reserved, consumers overlap rather than starve")
    func overlapRatherThanStarve() throws {
        // One photo and three displays: all three show that photo.
        let (library, ids) = try TestLibrary.withPhotos(1)
        let one = try library.addConsumer(kind: "wallpaper", displayID: "A")
        try library.reserve(ids[0], consumerID: one, position: 0)

        let deal = try #require(try library.deck.deal())
        #expect(deal.card.id == ids[0])
        #expect(deal.relaxations.contains(.reservedCardsReused))

        // And the concession is on the record rather than swallowed.
        let events = try library.deck.recentEvents()
        #expect(events.contains { $0.kind == "reserved_reused" })
    }

    @Test("Running out mid-pass is a reshuffle, not a degradation")
    func exhaustingAPassReshuffles() throws {
        let (library, ids) = try TestLibrary.withPhotos(6)
        let settings = DeckSettings(repeatWindowFraction: 1.0)

        // The first pass deals each photo once and never reshuffles: every card
        // is still unused, so nothing runs out.
        var startedPasses = 0
        for _ in 0..<6 {
            let deal = try #require(try library.deck.deal(settings: settings))
            #expect(deal.relaxations.isEmpty)
            if deal.startedNewPass { startedPasses += 1 }
        }
        #expect(startedPasses == 0)
        #expect(try library.deck.unusedInCurrentPass() == 0)

        // The seventh card has nothing unused left, so the deck reshuffles —
        // reported as a new pass rather than as a concession.
        let seventh = try #require(try library.deck.deal(settings: settings))
        #expect(seventh.startedNewPass)
        #expect(seventh.relaxations.isEmpty)
        #expect(ids.contains(seventh.card.id))
        #expect(try library.deck.state().passStartSeq == 6)
        #expect(try library.deck.unusedInCurrentPass() == 5)

        let events = try library.deck.recentEvents()
        #expect(events.contains { $0.kind == "pass" })
    }

    @Test("Below fraction 1.0 the window binds and the pass never has to reshuffle")
    func lowerFractionsNeverReachThePassBoundary() throws {
        let (library, _) = try TestLibrary.withPhotos(50)
        var reshuffles = 0
        for _ in 0..<600 {
            let deal = try #require(try library.deck.deal(settings: .default))
            if deal.startedNewPass { reshuffles += 1 }
        }
        // With half the pool eligible at any moment the window always has an
        // answer, so `pass_start_seq` never moves and the pass rule contributes
        // nothing. That is what keeps the minimum-gap guarantee intact below 1.0.
        #expect(reshuffles == 0)
        #expect(try library.deck.state().passStartSeq == 0)
    }

    @Test("Deck events are kept to a bounded tail")
    func eventsAreTrimmed() throws {
        let library = try TestLibrary()
        for index in 0..<(Deck.eventsKept + 25) {
            try library.deck.recordEvent(kind: "pass", detail: "reshuffled at ordinal \(index)")
        }
        let count = try library.database.scalarInt("SELECT COUNT(*) FROM deck_event;")
        #expect(count == Deck.eventsKept)
    }

    // MARK: - The statistical assertions

    /// The plan's own test: at fraction 1.0, a thousand deals across a hundred
    /// photos produce exactly ten showings each — and every hundred-deal pass
    /// contains every photo exactly once.
    @Test("Fraction 1.0 is exactly fair: zero variance across a thousand deals")
    func fractionOneIsExactlyFair() throws {
        let (library, ids) = try TestLibrary.withPhotos(100)
        let settings = DeckSettings(repeatWindowFraction: 1.0)
        let sequence = try library.deck.dealSequence(count: 1000, settings: settings)

        #expect(sequence.count == 1000)

        var counts: [Int64: Int] = [:]
        for id in sequence { counts[id, default: 0] += 1 }
        #expect(Set(counts.keys) == Set(ids))
        #expect(Set(counts.values) == [10], "expected exactly ten showings each, got \(Set(counts.values).sorted())")

        // Exactly once per pass, which is the same claim stated per block
        // rather than per total.
        for pass in stride(from: 0, to: 1000, by: 100) {
            let block = Array(sequence[pass..<(pass + 100)])
            #expect(Set(block).count == 100, "pass starting at \(pass) repeated a photo")
        }

        // Nothing was given up to achieve it — the reshuffles are passes, not
        // relaxations.
        let events = try library.deck.recentEvents(limit: 200)
        #expect(events.allSatisfy { $0.kind == "pass" })
    }

    /// The reshuffle. Every pass is an independent random permutation, so the
    /// order differs each time through — which is the whole reason the deck
    /// keeps a pass boundary rather than a hard sliding window at 1.0.
    @Test("Every pass is a fresh random order")
    func everyPassIsShuffledAnew() throws {
        let (library, _) = try TestLibrary.withPhotos(20)
        let settings = DeckSettings(repeatWindowFraction: 1.0)
        let sequence = try library.deck.dealSequence(count: 20 * 40, settings: settings)

        let passes = stride(from: 0, to: sequence.count, by: 20).map { Array(sequence[$0..<($0 + 20)]) }
        // Each is a permutation of the library...
        #expect(passes.allSatisfy { Set($0).count == 20 })
        // ...and they are not the same permutation. Forty passes of twenty
        // photos colliding by chance is 40 draws from 20! possibilities.
        #expect(Set(passes.map { $0.map(String.init).joined(separator: ",") }).count == passes.count)
    }

    @Test("A photo may repeat across a pass boundary, and that is accepted")
    func passBoundariesAllowAdjacentRepeats() throws {
        // With a two-photo library every pass is two cards, so the boundary is
        // hit constantly and a back-to-back repeat is a coin flip each time.
        // The deck does not add machinery to prevent it.
        let (library, _) = try TestLibrary.withPhotos(2)
        let sequence = try library.deck.dealSequence(
            count: 200, settings: DeckSettings(repeatWindowFraction: 1.0)
        )
        let adjacentRepeats = zip(sequence, sequence.dropFirst()).count { $0 == $1 }
        #expect(adjacentRepeats > 0, "expected the boundary to produce some adjacent repeats")
        // But fairness is still exact.
        var counts: [Int64: Int] = [:]
        for id in sequence { counts[id, default: 0] += 1 }
        #expect(Set(counts.values) == [100])
    }

    @Test("A lower fraction respects its window and buys variance with it")
    func lowerFractionIsLivelyButBounded() throws {
        let (library, ids) = try TestLibrary.withPhotos(100)
        let settings = DeckSettings(repeatWindowFraction: 0.5)
        let sequence = try library.deck.dealSequence(count: 2000, settings: settings)

        // The hard guarantee: no repeat inside the window.
        let gaps = gapsBetweenRepeats(in: sequence)
        let window = settings.repeatWindow(poolSize: 100)
        #expect(gaps.min()! > window, "closest repeat was \(gaps.min()!) deals apart, window is \(window)")

        // The soft one: unlike fraction 1.0, showings equalise only in
        // expectation. That variance is the feature being bought.
        var counts: [Int64: Int] = [:]
        for id in sequence { counts[id, default: 0] += 1 }
        #expect(Set(counts.keys) == Set(ids))
        #expect(Set(counts.values).count > 1, "expected variance in showing counts, got \(Set(counts.values))")

        // Every photo still gets a fair share of the run.
        #expect(counts.values.min()! >= 5)
        #expect(counts.values.max()! <= 40)

        // And nothing was given up, nor reshuffled, to get there.
        #expect(try library.deck.recentEvents().isEmpty)
    }

    /// Regression test for the selection flaw. Taking the *minimum* shuffle key
    /// and re-rolling only the winner means a photo whose key lands high loses,
    /// keeps its high key because it never won, and loses again — permanently.
    /// Selecting at a random offset into the eligible set is what fixes it.
    ///
    /// This is deliberately set up to be maximally hostile: one photo is given
    /// a key of 0.999 and every other photo a low one.
    @Test("A photo with an unlucky shuffle key is not starved out of the deck")
    func unluckyKeysAreNotStarved() throws {
        let (library, ids) = try TestLibrary.withPhotos(50)
        let unlucky = ids[0]
        try library.database.run(
            "UPDATE photo SET shuffle_key = CASE WHEN id = :unlucky THEN 0.999 ELSE 0.001 END;",
            ["unlucky": .int(unlucky)]
        )

        let sequence = try library.deck.dealSequence(count: 1000, settings: .default)
        var counts: [Int64: Int] = [:]
        for id in sequence { counts[id, default: 0] += 1 }

        #expect(counts[unlucky] != nil, "the unlucky photo was never shown at all")
        // 1000 deals over 50 photos is 20 each in expectation. Under minimum-key
        // selection the unlucky photo scored zero; the bar here is that it lands
        // in the same order of magnitude as everyone else.
        #expect(counts[unlucky]! >= 10, "shown \(counts[unlucky]!) times against an expectation of 20")
        #expect(counts.count == 50)
    }

    @Test("Every photo appears, however large the library")
    func everyPhotoIsReachable() throws {
        let (library, ids) = try TestLibrary.withPhotos(500)
        // At fraction 1.0 coverage is exact rather than probabilistic: a pass
        // is the library, so 500 deals is every photo once.
        let sequence = try library.deck.dealSequence(
            count: 500, settings: DeckSettings(repeatWindowFraction: 1.0)
        )
        #expect(Set(sequence) == Set(ids))
        #expect(sequence.count == 500)
    }

    // MARK: - Peeking and stats

    @Test("Peeking shows the eligible set without consuming any of it")
    func peekDoesNotAdvance() throws {
        let (library, ids) = try TestLibrary.withPhotos(10)
        let peeked = try library.deck.peek(count: 3)
        #expect(peeked.count == 3)
        #expect(try library.deck.currentDealSeq() == 0)
        #expect(try library.database.scalarInt("SELECT SUM(times_shown) FROM photo;") == 0)

        // Peek is the set a deal will pick from, not a prediction of which one
        // it will pick — selection takes a random offset into that set.
        let everything = try library.deck.peek(count: 100)
        #expect(Set(everything.map(\.id)) == Set(ids))

        let dealt = try #require(try library.deck.deal())
        #expect(ids.contains(dealt.card.id))
    }

    @Test("Stats describe the library rather than guessing at it")
    func statsAreAccurate() throws {
        let library = try TestLibrary()
        let source = try library.addSource()
        _ = try library.addPhotos(10, to: source)
        _ = try library.addPhotos(3, to: source, mediaType: .video, namePrefix: "clip")
        _ = try library.deck.dealSequence(count: 4, settings: .default)

        let stats = try library.deck.stats()
        #expect(stats.totalPhotos == 13)
        #expect(stats.dealablePhotos == 10)
        #expect(stats.neverDealt == 9)  // 13 rows, 4 of them dealt
        #expect(stats.currentDealSeq == 4)
        #expect(stats.repeatWindow == 5)
        #expect(stats.timesShownTotal == 4)
        #expect(stats.timesShownMin == 0)
        #expect(stats.timesShownMax == 1)
        #expect(stats.residentPhotos == 13)
        // Still in the first pass, with six of the ten dealable cards to go.
        #expect(stats.passStartSeq == 0)
        #expect(stats.unusedInCurrentPass == 6)
    }

    // MARK: - Two processes, one deck

    @Test("Concurrent deals from separate connections never hand out the same card")
    func concurrentDealsAreSerialised() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-deck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try TestLibrary.onDisk(at: directory)
        let source = try library.addSource()
        let ids = try library.addPhotos(400, to: source)
        let path = TestLibrary.path(in: directory)

        let dealsPerWorker = 50
        let workers = 4
        let collected = Mutex<[Int64]>([])

        // Each worker opens its own connection, which is the arrangement the
        // real system has: an agent, an app, and a saver in separate processes.
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            guard let database = try? Database(path: path) else { return }
            let deck = Deck(database: database)
            var mine: [Int64] = []
            for _ in 0..<dealsPerWorker {
                if let deal = try? deck.deal(settings: DeckSettings(repeatWindowFraction: 1.0)) {
                    mine.append(deal.card.id)
                }
            }
            collected.withLock { $0.append(contentsOf: mine) }
        }

        let dealt = collected.withLock { $0 }
        #expect(dealt.count == workers * dealsPerWorker)

        // 200 deals against a 400-photo pool at fraction 1.0: no photo can
        // legitimately come out twice, so any duplicate is a lost race.
        #expect(Set(dealt).count == dealt.count, "a card was dealt twice")

        // The ordinal counted every card exactly once, from whichever process
        // dealt it.
        #expect(try library.deck.currentDealSeq() == Int64(dealt.count))
    }
}

/// A minimal lock, since the test needs to collect results from several
/// threads and the kit takes no dependencies.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
