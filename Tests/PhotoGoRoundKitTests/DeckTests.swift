import Foundation
import Testing

@testable import PhotoGoRoundKit

@Suite("Deck")
struct DeckTests {

    // MARK: - The window arithmetic

    @Test("Fraction 1.0 gives a window of pool - 1, which is the classic shuffle")
    func fractionOneClampsToPoolMinusOne() {
        let settings = DeckSettings(repeatWindowFraction: 1.0)
        #expect(settings.repeatWindow(poolSize: 100) == 99)
        #expect(settings.repeatWindow(poolSize: 2) == 1)
        // A window of `pool` would leave a deal at which nothing is eligible,
        // firing the relaxation ladder at every pass boundary. The clamp is
        // what makes 1.0 exactly the classic shuffle instead.
    }

    @Test("Small pools have no window at all")
    func degeneratePoolsHaveNoWindow() {
        let settings = DeckSettings(repeatWindowFraction: 1.0)
        #expect(settings.repeatWindow(poolSize: 0) == 0)
        #expect(settings.repeatWindow(poolSize: 1) == 0)
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

    @Test("The relaxation ladder halves down to zero")
    func relaxationLadderHalves() {
        #expect(Deck.relaxationLadder(from: 8) == [8, 4, 2, 1, 0])
        #expect(Deck.relaxationLadder(from: 1) == [1, 0])
        #expect(Deck.relaxationLadder(from: 0) == [0])
        #expect(Deck.relaxationLadder(from: 99) == [99, 49, 24, 12, 6, 3, 1, 0])
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

    @Test("A window the library cannot support is narrowed, and says so")
    func windowNarrowsUnderScarcity() throws {
        // The window is clamped to pool - 1, so a library dealing only to
        // itself can never starve it — the oldest card is always exactly at the
        // threshold. Outstanding hands are what make it reachable: a
        // screensaver holding most of a small library leaves the rest too
        // recently dealt to qualify.
        let (library, ids) = try TestLibrary.withPhotos(10)
        let screensaver = try library.addConsumer(kind: "screensaver")
        for (offset, id) in ids[4...].enumerated() {
            try library.reserve(id, consumerID: screensaver, position: offset)
            try library.setLastDealt(id, seq: Int64(91 + offset))
        }
        for (offset, id) in ids[0..<4].enumerated() {
            try library.setLastDealt(id, seq: Int64(97 + offset))
        }
        try library.setDealSeq(100)

        // Pool 10 at fraction 0.5 wants a window of 5; at seq 101 the threshold
        // is 95, and the four free cards were all dealt after that.
        let deal = try #require(try library.deck.deal(settings: DeckSettings(repeatWindowFraction: 0.5)))
        let narrowings = deal.relaxations.compactMap { relaxation -> (Int, Int)? in
            if case .repeatWindowNarrowed(let from, let to) = relaxation { return (from, to) }
            return nil
        }
        #expect(narrowings.count == 1)
        #expect(narrowings.first?.0 == 5)
        #expect(narrowings.first?.1 == 2)
        // Narrowed to 2, the threshold is 98, so the two oldest free cards
        // qualify — and nothing reserved was touched.
        #expect(ids[0..<2].contains(deal.card.id))
        #expect(!deal.relaxations.contains(.reservedCardsReused))

        let events = try library.deck.recentEvents()
        #expect(events.contains { $0.kind == "window_relaxed" })
    }

    @Test("Relaxation events are kept to a bounded tail")
    func eventsAreTrimmed() throws {
        let library = try TestLibrary()
        for index in 0..<(Deck.eventsKept + 25) {
            try library.deck.record(.repeatWindowNarrowed(from: index, to: 0))
        }
        let count = try library.database.scalarInt("SELECT COUNT(*) FROM deck_event;")
        #expect(count == Deck.eventsKept)
    }

    // MARK: - The statistical assertions

    /// The plan's own test: at fraction 1.0, a thousand deals across a hundred
    /// photos produce exactly ten showings each with no repeat inside any
    /// hundred-deal stretch.
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

        // No repeat inside any hundred-deal stretch, which is the same claim
        // stated as a window rather than as a count.
        let gaps = gapsBetweenRepeats(in: sequence)
        #expect(gaps.min() == 100)

        // And nothing had to be given up to achieve it.
        #expect(try library.deck.recentEvents().isEmpty)
    }

    /// Documents a real property of the sliding window at its extreme, so that
    /// it is recorded in code rather than discovered later: at fraction 1.0
    /// exactly one photo is eligible at each deal after the first pass, so the
    /// shuffle key never gets a say and every subsequent pass replays the first
    /// pass's order. Exact fairness is bought with a fixed rotation.
    @Test("Fraction 1.0 repeats the first pass's order forever")
    func fractionOneDegeneratesToAFixedRotation() throws {
        let (library, _) = try TestLibrary.withPhotos(20)
        let settings = DeckSettings(repeatWindowFraction: 1.0)
        let sequence = try library.deck.dealSequence(count: 60, settings: settings)
        let passOne = Array(sequence[0..<20])
        let passTwo = Array(sequence[20..<40])
        let passThree = Array(sequence[40..<60])
        #expect(passTwo == passOne)
        #expect(passThree == passOne)
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

        // And no relaxation was needed to get there.
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
