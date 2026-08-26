import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import PhotoGoRoundAgentAPI

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

    @Test("An empty library offers nothing rather than failing")
    func emptyLibraryOffersNothing() throws {
        let library = try TestLibrary()
        #expect(try library.drawSequence(count: 3, settings: .default).isEmpty)
        #expect(try library.deck.currentDealSeq() == 0)
    }

    @Test("A deal advances the ordinal, the count, and the shuffle key")
    func dealAdvancesEverything() throws {
        let (library, ids) = try TestLibrary.withPhotos(1)
        let before = try library.database.first(
            "SELECT shuffle_key FROM photo WHERE id = :id;", ["id": .int(ids[0])]
        ) { try $0.double("shuffle_key") }

        let drawn = try library.drawSequence(count: 1, settings: .default)
        #expect(drawn == [ids[0]])
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
        let dealt = try library.drawSequence(count: 5, settings: .default)
        #expect(dealt == Array(repeating: ids[0], count: 5))
    }

    @Test("A card never dealt is eligible the moment it arrives")
    func newPhotosCompeteImmediately() throws {
        let (library, _) = try TestLibrary.withPhotos(4)
        let settings = DeckSettings(repeatWindowFraction: 1.0)
        _ = try library.drawSequence(count: 4, settings: settings)

        // A photo inserted mid-run has a null deal ordinal, so it is eligible
        // by definition and needs no special placement.
        let source = try library.database.scalarInt("SELECT id FROM source LIMIT 1;")
        let newcomers = try library.addPhotos(1, to: Int64(source!), namePrefix: "newcomer")
        // At fraction 1.0 nothing already shown has served out its window yet,
        // so the newcomer is the only eligible picture.
        #expect(try library.drawSequence(count: 1, settings: settings) == [newcomers[0]])
    }

    // MARK: - What is excluded from the deck

    @Test("A disabled source's photos leave the deck but keep their history")
    func disablingASourceDropsItFromTheDeck() throws {
        let library = try TestLibrary()
        let keep = try library.addSource(locator: "/keep")
        let drop = try library.addSource(locator: "/drop")
        let kept = try library.addPhotos(3, to: keep, namePrefix: "keep")
        let dropped = try library.addPhotos(3, to: drop, namePrefix: "drop")

        _ = try library.drawSequence(count: 6, settings: DeckSettings(repeatWindowFraction: 1.0))
        try library.setSourceEnabled(drop, false)

        #expect(try library.deck.poolSize() == 3)
        let after = Set(try library.drawSequence(count: 12, settings: .default))
        #expect(after.isSubset(of: Set(kept)))
        #expect(after.isDisjoint(with: Set(dropped)))

        // Disabling is not deleting: the history survives for when it comes back.
        let shown = try library.database.scalarInt(
            "SELECT SUM(times_shown) FROM photo WHERE source_id = :id;", ["id": .int(drop)]
        )
        #expect(shown == 3)
    }

    @Test("Videos are in the database and never in the deck")
    func videosAreNeverDealt() throws {
        let library = try TestLibrary()
        let source = try library.addSource()
        let images = try library.addPhotos(2, to: source, namePrefix: "still")
        let videos = try library.addPhotos(5, to: source, mediaType: .video, namePrefix: "clip")

        #expect(try library.deck.poolSize() == 2)
        let dealt = Set(try library.drawSequence(count: 20, settings: .default))
        #expect(dealt == Set(images))
        #expect(dealt.isDisjoint(with: Set(videos)))

        // The rows exist, which is what makes 2.0 a predicate change rather
        // than a rescan.
        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 7)
    }

    @Test("A picture already in the queue is not offered again")
    func queuedPicturesAreNotDealt() throws {
        let (library, ids) = try TestLibrary.withPhotos(3)
        let sourceID = try library.database.scalarInt("SELECT id FROM source LIMIT 1;")!
        try library.enqueue(ids[0], sourceID: Int64(sourceID))

        let dealt = Set(try library.drawSequence(count: 10, settings: .default))
        #expect(!dealt.contains(ids[0]))
    }

    @Test("Serving a picture puts it back in contention")
    func servedPicturesReturnToTheDeck() throws {
        let (library, ids) = try TestLibrary.withPhotos(2)
        let sourceID = try library.database.scalarInt("SELECT id FROM source LIMIT 1;")!
        try library.enqueue(ids[0], sourceID: Int64(sourceID))

        // Serving removes the queue entry, which is the only thing that was
        // holding the photo out of the deck.
        _ = try PhotoQueue(database: library.database).serve()
        let dealt = Set(try library.drawSequence(count: 10, settings: .default))
        #expect(dealt.contains(ids[0]))
    }

    // MARK: - Scarcity degrades, it never starves

    @Test("Deck events are kept to a bounded tail")
    func eventsAreTrimmed() throws {
        let library = try TestLibrary()
        for index in 0..<(Deck.eventsKept + 25) {
            try library.deck.recordEvent(kind: "pass", detail: "reshuffled at ordinal \(index)")
        }
        let count = try library.database.scalarInt("SELECT COUNT(*) FROM deck_event;")
        #expect(count == Deck.eventsKept)
    }

    // MARK: - The pass fires only when the window has no answer

    /// The floor beneath the window exists for two cases and no others: fraction
    /// 1.0, and a library too small for the window to leave anyone eligible.
    /// Queued cards are staged, not used up — so a library whose unqueued
    /// photos are merely inside the window is a deck that should wait, not a
    /// pass that has ended. Declaring a pass there nullifies the repeat window
    /// and writes a bogus reshuffle event per picture served.
    @Test("Window-blocked photos beside a full queue do not end the pass")
    func windowBlockedPhotosDoNotEndThePass() throws {
        let (library, ids) = try TestLibrary.withPhotos(6)
        let settings = DeckSettings(repeatWindowFraction: 0.5)  // window = 3
        let source = try #require(try library.database.scalarInt("SELECT id FROM source LIMIT 1;"))

        // Four cards staged in the queue, and the other two dealt so recently
        // the window still holds them: nothing is eligible, and nothing has
        // run out.
        for id in ids.prefix(4) { try library.enqueue(id, sourceID: Int64(source)) }
        try library.setDealSeq(10)
        try library.setLastDealt(ids[4], seq: 9)
        try library.setLastDealt(ids[5], seq: 10)

        #expect(try library.deck.nextCandidate(settings: settings) == nil)
        let state = try library.deck.state()
        #expect(state.passStartSeq == 0, "a wait was declared a pass")
        #expect(try library.deck.recentEvents().isEmpty, "no reshuffle happened, so no event should say one did")

        // Waiting is what resolves it: once the ordinal moves past the window,
        // the older photo is offered without any pass machinery.
        try library.setDealSeq(13)
        let card = try #require(try library.deck.nextCandidate(settings: settings))
        #expect(card.id == ids[4])
    }

    @Test("A fully queued library deals nothing and declares no pass")
    func fullyQueuedLibraryDeclaresNoPass() throws {
        let (library, ids) = try TestLibrary.withPhotos(3)
        let source = try #require(try library.database.scalarInt("SELECT id FROM source LIMIT 1;"))
        for id in ids { try library.enqueue(id, sourceID: Int64(source)) }
        try library.setDealSeq(5)

        #expect(try library.deck.nextCandidate(settings: .default) == nil)
        #expect(try library.deck.state().passStartSeq == 0)
        #expect(try library.deck.recentEvents().isEmpty)
    }

    /// The corner that keeps the comparison honest: retired photos shrink the
    /// population that can actually cycle, and the window must be measured
    /// against what is left — or a mostly-blacklisted library waits for a
    /// release that can never come.
    @Test("Retired photos do not count toward the population the window is measured against")
    func blacklistedPhotosShrinkTheEffectivePool() throws {
        let (library, ids) = try TestLibrary.withPhotos(3)
        let settings = DeckSettings(repeatWindowFraction: 0.8)  // window = 2 of pool 3
        for id in ids.dropLast() {
            try library.database.run(
                "UPDATE photo SET render_failures = :n WHERE id = :id;",
                ["n": .int(Int64(Deck.renderFailureLimit)), "id": .int(id)]
            )
        }
        // One photo can cycle and the window exceeds that population, so the
        // pass is the only rule — exactly the one-photo-library case.
        let dealt = try library.drawSequence(count: 4, settings: settings)
        #expect(dealt == Array(repeating: ids[2], count: 4))
    }

    // MARK: - The statistical assertions

    /// The plan's own test: at fraction 1.0, a thousand deals across a hundred
    /// photos produce exactly ten showings each — and every hundred-deal pass
    /// contains every photo exactly once.
    @Test("Fraction 1.0 is exactly fair: zero variance across a thousand deals")
    func fractionOneIsExactlyFair() throws {
        let (library, ids) = try TestLibrary.withPhotos(100)
        let settings = DeckSettings(repeatWindowFraction: 1.0)
        let sequence = try library.drawSequence(count: 1000, settings: settings)

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
        let sequence = try library.drawSequence(count: 20 * 40, settings: settings)

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
        let sequence = try library.drawSequence(
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
        let sequence = try library.drawSequence(count: 2000, settings: settings)

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

        let sequence = try library.drawSequence(count: 1000, settings: .default)
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
        let sequence = try library.drawSequence(
            count: 500, settings: DeckSettings(repeatWindowFraction: 1.0)
        )
        #expect(Set(sequence) == Set(ids))
        #expect(sequence.count == 500)
    }

    // MARK: - Peeking and stats

    @Test("The showing histogram counts photos per showing count")
    func showingHistogramGroupsByCount() throws {
        let (library, ids) = try TestLibrary.withPhotos(6)
        let deck = library.deck

        // Nothing dealt: every photo sits at zero.
        var histogram = try deck.showingHistogram()
        #expect(histogram.map(\.shown) == [0])
        #expect(histogram.map(\.photos) == [6])

        for id in ids.prefix(2) { _ = try deck.markShown(photoID: id) }
        _ = try deck.markShown(photoID: ids[0])

        // One photo shown twice, one once, four never.
        histogram = try deck.showingHistogram()
        #expect(histogram.map(\.shown) == [0, 1, 2])
        #expect(histogram.map(\.photos) == [4, 1, 1])
    }

    @Test("The histogram ignores photos the deck cannot deal")
    func showingHistogramExcludesUndealables() throws {
        let library = try TestLibrary()
        let source = try library.addSource()
        try library.addPhotos(3, to: source, namePrefix: "still")
        try library.addPhotos(2, to: source, mediaType: .video, namePrefix: "clip")

        // Videos are in the database and never in the deck, so they are not in
        // a report about what the deck has been doing.
        let histogram = try library.deck.showingHistogram()
        #expect(histogram.map(\.shown) == [0])
        #expect(histogram.map(\.photos) == [3])

        try library.setSourceEnabled(source, false)
        #expect(try library.deck.showingHistogram().isEmpty)
    }


    @Test("Stats describe the library rather than guessing at it")
    func statsAreAccurate() throws {
        let library = try TestLibrary()
        let source = try library.addSource()
        _ = try library.addPhotos(10, to: source)
        _ = try library.addPhotos(3, to: source, mediaType: .video, namePrefix: "clip")
        _ = try library.drawSequence(count: 4, settings: .default)

        let stats = try library.deck.stats()
        #expect(stats.totalPhotos == 13)
        #expect(stats.dealablePhotos == 10)
        #expect(stats.neverDealt == 9)  // 13 rows, 4 of them dealt
        #expect(stats.currentDealSeq == 4)
        #expect(stats.repeatWindow == 5)
        #expect(stats.timesShownTotal == 4)
        #expect(stats.timesShownMin == 0)
        #expect(stats.timesShownMax == 1)
        // Still in the first pass, with six of the ten dealable cards to go.
        #expect(stats.passStartSeq == 0)
        #expect(stats.unusedInCurrentPass == 6)
    }

    // MARK: - Claiming at selection

    @Test("Selecting claims the photo, so the next selection cannot pick it again")
    func selectionClaimsItsCandidate() throws {
        let (library, ids) = try TestLibrary.withPhotos(2)
        let source = Int64(try #require(try library.database.scalarInt("SELECT id FROM source LIMIT 1;")))
        let deck = library.deck

        // **The claim is the cache's, so this asks the cache's draw.** Dealing
        // takes no claim: its bytes are already here, so there is no gap
        // between choosing and storing for anything to race in.
        try library.database.run("UPDATE photo SET cached_at = NULL;")

        let first = try #require(try deck.nextRemoteCandidate())
        let second = try #require(try deck.nextRemoteCandidate())
        #expect(first.id != second.id)
        #expect(Set([first.id, second.id]) == Set(ids))

        // Both are claimed and neither has landed, so there is nothing left to
        // offer. Without the claim this would hand out a third draw for a
        // photograph another lane is already downloading.
        #expect(try deck.nextRemoteCandidate() == nil)
    }

    @Test("Releasing a claim puts the photo straight back in contention")
    func releasingAClaimRestoresThePhoto() throws {
        let (library, _) = try TestLibrary.withPhotos(1)
        let source = Int64(try #require(try library.database.scalarInt("SELECT id FROM source LIMIT 1;")))
        let deck = library.deck

        try library.database.run("UPDATE photo SET cached_at = NULL;")

        let card = try #require(try deck.nextRemoteCandidate())
        #expect(try deck.nextRemoteCandidate() == nil)

        try deck.releaseClaim(photoID: card.id)
        #expect(try deck.nextRemoteCandidate()?.id == card.id)
    }

    @Test("A claim expires, so a producer that died mid-fetch sidelines nothing")
    func claimsExpire() throws {
        let (library, _) = try TestLibrary.withPhotos(1)
        let source = Int64(try #require(try library.database.scalarInt("SELECT id FROM source LIMIT 1;")))
        let deck = library.deck

        try library.database.run("UPDATE photo SET cached_at = NULL;")

        let start = Date(timeIntervalSince1970: 1_000_000)
        let card = try #require(try deck.nextRemoteCandidate(now: start))
        // Still inside the window: the claim holds.
        #expect(
            try deck.nextRemoteCandidate(now: start.addingTimeInterval(Deck.claimTimeout - 1))
                == nil)
        // Past it: nobody is coming back for this one, so it competes again.
        let again = try deck.nextRemoteCandidate(
            now: start.addingTimeInterval(Deck.claimTimeout + 1))
        #expect(again?.id == card.id)
    }

    @Test("Showing a photo ends any claim on it")
    func markingShownClearsTheClaim() throws {
        let (library, _) = try TestLibrary.withPhotos(1)
        let source = Int64(try #require(try library.database.scalarInt("SELECT id FROM source LIMIT 1;")))
        let deck = library.deck

        let card = try #require(try deck.nextCandidate())
        _ = try deck.markShown(photoID: card.id)
        let claimed = try library.database.first(
            "SELECT claimed_at FROM photo WHERE id = :id;", ["id": .int(card.id)]
        ) { try $0.optionalInt64("claimed_at") }
        #expect(claimed == .some(nil))
    }

    @Test("Concurrent producers against one source never pick the same picture")
    func concurrentSelectionsNeverCollide() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-claim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try TestLibrary.onDisk(at: directory)
        let source = try library.addSource()
        try library.addPhotos(400, to: source)
        let path = TestLibrary.path(in: directory)

        // **The claim moved to the cache, so this now asks the cache's draw.**
        // Selection and the fetch that follows it are separated in time, which
        // is what the claim is for — and that is true of downloading and false
        // of dealing, whose bytes are already here. Nothing is released, which
        // is the point: 400 draws against 400 photographs must be 400 distinct
        // photographs, or two lanes have spent two downloads on one picture.
        try library.database.run("UPDATE photo SET cached_at = NULL;")
        let collected = Mutex<[Int64]>([])
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            guard let database = try? Database(path: path) else { return }
            let deck = Deck(database: database)
            var mine: [Int64] = []
            for _ in 0..<100 {
                guard let card = (try? deck.nextRemoteCandidate()) ?? nil else { break }
                mine.append(card.id)
            }
            collected.withLock { $0.append(contentsOf: mine) }
        }

        let picked = collected.withLock { $0 }
        #expect(picked.count == 400)
        #expect(Set(picked).count == picked.count, "two producers picked the same picture")
    }

    // MARK: - Photographs that will not render

    @Test("A photo is retired after three failed renders, not the first")
    func blacklistTakesThreeAttempts() throws {
        let (library, ids) = try TestLibrary.withPhotos(2)
        let source = Int64(try #require(try library.database.scalarInt("SELECT id FROM source LIMIT 1;")))
        let deck = library.deck
        let doomed = ids[0]

        // A decode can fail from memory pressure or a file caught mid-copy, so
        // one failure says nothing permanent.
        #expect(try deck.recordRenderFailure(photoID: doomed) == 1)
        #expect(try deck.recordRenderFailure(photoID: doomed) == 2)
        #expect(try deck.blacklisted().isEmpty)

        #expect(try deck.recordRenderFailure(photoID: doomed) == 3)
        #expect(try deck.blacklisted().map(\.id) == [doomed])
    }

    @Test("A retired photo is never offered again")
    func blacklistedIsNotDealt() throws {
        let (library, ids) = try TestLibrary.withPhotos(2)
        let source = Int64(try #require(try library.database.scalarInt("SELECT id FROM source LIMIT 1;")))
        let deck = library.deck

        for _ in 0..<Deck.renderFailureLimit {
            try deck.recordRenderFailure(photoID: ids[0])
        }

        // The other photo is still dealt; the retired one is not, however many
        // times it is asked for.
        var offered: Set<Int64> = []
        for _ in 0..<6 {
            guard let card = try deck.nextCandidate() else { break }
            offered.insert(card.id)
            _ = try deck.markShown(photoID: card.id)
        }
        #expect(offered == [ids[1]])
    }

    @Test("Retiring keeps the row, because the file is still there")
    func blacklistIsNotADeletion() throws {
        let (library, ids) = try TestLibrary.withPhotos(1)
        let deck = library.deck
        for _ in 0..<Deck.renderFailureLimit { try deck.recordRenderFailure(photoID: ids[0]) }

        // Removing it from the pool would not work: the next refresh finds the
        // file on disk and adds it straight back.
        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 1)
        #expect(try deck.blacklisted().count == 1)
        #expect(try deck.recentEvents().contains { $0.kind == "blacklist" })
    }

    @Test("Clearing the failures puts them back in contention")
    func clearingRestoresThem() throws {
        let (library, ids) = try TestLibrary.withPhotos(1)
        let source = Int64(try #require(try library.database.scalarInt("SELECT id FROM source LIMIT 1;")))
        let deck = library.deck
        for _ in 0..<Deck.renderFailureLimit { try deck.recordRenderFailure(photoID: ids[0]) }
        #expect(try deck.nextCandidate() == nil)

        #expect(try deck.clearRenderFailures() == 1)
        #expect(try deck.blacklisted().isEmpty)
        #expect(try deck.nextCandidate()?.id == ids[0])
    }

    // MARK: - Two processes, one deck

    @Test("Concurrent serves from separate connections never hand out the same picture")
    func concurrentServesAreSerialised() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-deck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try TestLibrary.onDisk(at: directory)
        let source = try library.addSource()
        let ids = try library.addPhotos(400, to: source)
        for id in ids { try library.enqueue(id, sourceID: source) }
        let path = TestLibrary.path(in: directory)

        // Atomicity lives in two places: the claim taken at selection, which
        // keeps two producers off one picture, and this — the queue pop, where
        // removing the entry under BEGIN IMMEDIATE means exactly one consumer
        // can ever win it.
        let collected = Mutex<[Int64]>([])
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            guard let database = try? Database(path: path) else { return }
            let queue = PhotoQueue(database: database)
            var mine: [Int64] = []
            for _ in 0..<100 {
                guard let card = (try? queue.serve()) ?? nil else { break }
                mine.append(card.id)
            }
            collected.withLock { $0.append(contentsOf: mine) }
        }

        let served = collected.withLock { $0 }
        #expect(served.count == 400)
        #expect(Set(served).count == served.count, "a picture was served twice")
        #expect(try PhotoQueue(database: library.database).size() == 0)
    }
}
