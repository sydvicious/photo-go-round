import Foundation
import Testing

@testable import PhotoGoRoundKit

@Suite("Queue")
struct QueueTests {

    private func library(photos: Int) throws -> (TestLibrary, [Int64], Int64) {
        let library = try TestLibrary()
        let source = try library.addSource()
        let ids = try library.addPhotos(photos, to: source)
        return (library, ids, source)
    }

    // MARK: - Serving

    @Test("Running for a long time does not collapse the keys into a FIFO")
    func keysDoNotCollapse() throws {
        // **The bug this pins, and it is not a slow one.** A card is placed at a
        // key drawn between the lowest and the highest currently queued. The
        // highest therefore never rises, and the lowest rises every time a card
        // is served — so the interval only ever shrinks. Modelled, a queue of
        // twenty reaches a span of *exactly zero* in about a thousand cycles,
        // which at ten seconds a picture is under three hours. Once keys tie,
        // ordering falls back to `position` and the queue is silently a FIFO
        // again, with random placement gone and nothing saying so.
        let library = try TestLibrary()
        let source = try library.addSource()
        let ids = try library.addPhotos(25, to: source)
        let queue = PhotoQueue(database: library.database, nominalSize: 20)
        for id in ids.prefix(20) { try queue.append(photoID: id, sourceID: source) }

        // Serve the head and put it straight back, which is what a fetched card
        // does — a thousand times.
        for _ in 0..<1000 {
            let card = try #require(try queue.serve())
            try queue.append(photoID: card.id, sourceID: source)
        }

        let span = try #require(
            try library.database.first("SELECT MAX(sort_key) - MIN(sort_key) AS span FROM queue;") {
                try $0.double("span")
            })
        let distinct =
            try library.database.scalarInt("SELECT COUNT(DISTINCT sort_key) FROM queue;") ?? 0

        #expect(span >= 1.0, "the key interval collapsed to \(span)")
        #expect(distinct == 20, "keys have tied, so ordering has fallen back to insertion order")
    }

    @Test("A card is inserted at a random position, not at the end")
    func appendingIsRandomlyPlaced() async throws {
        // **Every insertion is random, dealt and returned alike.** At the tail, a
        // card waits a whole traversal before it is looked at — which for a
        // returned card means its bytes were paid for and then sat for eight
        // minutes, and for a newly dealt one means a source added now is
        // invisible until the queue has turned over once. At the head, the order
        // pictures appear in becomes the order they were *fetched* in, and the
        // fastest source owns the front. Random is the placement that has
        // neither fault.
        let library = try TestLibrary()
        let source = try library.addSource()
        let ids = try library.addPhotos(60, to: source)
        let queue = PhotoQueue(database: library.database, nominalSize: 1000)

        for id in ids { try queue.append(photoID: id, sourceID: source) }

        let order = try queue.peek(Int.max).map(\.id)
        #expect(order.count == 60)
        #expect(Set(order) == Set(ids), "every card is still there, exactly once")

        // Sixty cards landing in insertion order by chance is 1/60!, so this
        // says the placement is not the tail without asserting any particular
        // arrangement.
        #expect(order != ids, "cards were appended in order, so nothing was randomised")

        // And not merely reversed or otherwise fixed. A key is drawn strictly
        // inside the existing span — a tie with the head sorts after it by
        // position, and the draw never reaches the tail — so the last card
        // inserted is at best second and never last, deterministically.
        let lastInserted = try #require(ids.last)
        let where_ = try #require(order.firstIndex(of: lastInserted))
        #expect(where_ != 0)
        #expect(where_ != order.count - 1)
    }

    @Test("Placement is spread across the queue rather than clustered at one end")
    func placementIsSpread() async throws {
        // The distributional claim, which the test above deliberately does not
        // make. A card inserted into a queue of fifty lands in the first third,
        // the middle third, and the last third with roughly equal frequency —
        // the property that both of the rejected placements fail.
        let library = try TestLibrary()
        let source = try library.addSource()
        let ids = try library.addPhotos(60 * 21, to: source)
        var thirds = [0, 0, 0]

        for trial in 0..<60 {
            let queue = PhotoQueue(
                database: library.database, nominalSize: 1000)
            // A fresh queue of twenty per trial, then one more card.
            try library.database.run("DELETE FROM queue;")
            let batch = Array(ids[(trial * 21)..<(trial * 21 + 20)])
            for id in batch { try queue.append(photoID: id, sourceID: source) }
            let newcomer = ids[trial * 21 + 20]
            try queue.append(photoID: newcomer, sourceID: source)

            let at = try #require(try queue.peek(Int.max).map(\.id).firstIndex(of: newcomer))
            thirds[min(2, at * 3 / 21)] += 1
        }

        // Twenty expected per third over sixty trials. Loose bounds, because
        // this is a randomness check and a flaky test is worse than a coarse one.
        #expect(thirds.allSatisfy { $0 >= 5 }, "clustered at one end: \(thirds)")
    }

    @Test("The card at the top is not starved by the ones queued after it")
    func theTopCardIsNotStarved() throws {
        // **Observed live on 2026-08-25**: photo 8239 held the highest sort key
        // for six and a half hours while cards queued minutes earlier were
        // served and replaced around it.
        //
        // A new key is drawn between the lowest and the highest currently
        // queued. Inserting uniformly among *n* cards has *n+1* gaps — before
        // the first, between each pair, and after the last — and a draw bounded
        // above by the maximum can only ever reach the first *n* of them. The
        // card holding the top key is therefore a fixed point, and respacing
        // preserves order, so it stays there. One slot of twenty dies, one
        // photograph is never shown, and nothing says so.
        let (library, ids, source) = try library(photos: 400)
        let queue = PhotoQueue(database: library.database, nominalSize: 20)

        let original = Array(ids.prefix(20))
        for id in original { try queue.append(photoID: id, sourceID: source) }

        // Steady state, which is the only state that matters: the filler keeps
        // the queue full, so one card goes on for every one served. A queue
        // allowed to drain would reach its top card eventually and hide this.
        var served: Set<Int64> = []
        var next = original.count
        for _ in 0..<300 {
            guard let card = try queue.serve() else { break }
            served.insert(card.id)
            try queue.append(photoID: ids[next], sourceID: source)
            next += 1
        }

        let starved = Set(original).subtracting(served)
        #expect(
            starved.isEmpty,
            "\(starved.count) of 20 never served in 300 cycles: \(starved.sorted())")
    }

    @Test("An empty queue answers 'no photos', which is not an error")
    func emptyQueueServesNothing() throws {
        let library = try TestLibrary()
        let queue = PhotoQueue(database: library.database, nominalSize: 10)
        #expect(try queue.serve() == nil)
        #expect(try queue.size() == 0)
        // A fresh install starts here and stays here until providers deliver.
        #expect(try queue.needsTopUp())
    }

    @Test("Serving empties the queue, once each, and then answers nothing")
    func servingDrainsEveryCardOnce() throws {
        // **Not in insertion order**, and this test used to say it was. Placement
        // is random now, so what survives is what actually matters: every card
        // comes out, none comes out twice, and the queue shortens by one each
        // time. Which card is next is exactly the thing nothing may depend on.
        let (library, ids, source) = try library(photos: 3)
        let queue = PhotoQueue(database: library.database, nominalSize: 10)
        for id in ids { try queue.append(photoID: id, sourceID: source) }

        #expect(try queue.size() == 3)
        var served: [Int64] = []
        while let card = try queue.serve() { served.append(card.id) }

        #expect(served.count == 3)
        #expect(Set(served) == Set(ids))
        #expect(try queue.size() == 0)
        #expect(try queue.serve() == nil)
    }

    @Test("Peeking shows what is next without consuming it")
    func peekingDoesNotConsume() throws {
        let (library, ids, source) = try library(photos: 3)
        let queue = PhotoQueue(database: library.database, nominalSize: 10)
        for id in ids { try queue.append(photoID: id, sourceID: source) }

        // Peek agrees with serve about what is next — that is the contract, not
        // that either agrees with insertion order.
        let peeked = try queue.peek(2).map(\.id)
        #expect(peeked.count == 2)
        #expect(Set(peeked).isSubset(of: Set(ids)))
        #expect(try queue.size() == 3)
        #expect(try queue.serve()?.id == peeked[0], "peek and serve disagree about the head")
    }

    // MARK: - Size is nominal, not a ceiling

    @Test("The queue overshoots its nominal size by one per provider")
    func nominalSizeIsNotACeiling() throws {
        // Four providers answering at four different times, exactly the sequence
        // that motivates a soft size.
        let (library, ids, source) = try library(photos: 20)
        let queue = PhotoQueue(database: library.database, nominalSize: 10)
        for id in ids.prefix(10) { try queue.append(photoID: id, sourceID: source) }
        #expect(try queue.size() == 10)
        #expect(!(try queue.needsTopUp()))

        // A client takes one, which is what notices the shortfall.
        _ = try queue.serve()
        #expect(try queue.size() == 9)
        #expect(try queue.needsTopUp())

        // All four answer, at their own pace. Nothing is refused, nothing is
        // evicted to make room.
        for id in ids[10..<14] { #expect(try queue.append(photoID: id, sourceID: source)) }
        #expect(try queue.size() == 13)
        #expect(!(try queue.needsTopUp()))

        // And it drains back down through the nominal size without any of the
        // overshoot being wasted.
        for _ in 0..<3 { _ = try queue.serve() }
        #expect(try queue.size() == 10)
        #expect(!(try queue.needsTopUp()))
        _ = try queue.serve()
        #expect(try queue.needsTopUp())
    }

    @Test("Adding never evicts; only serving shortens the queue")
    func addingNeverEvicts() throws {
        let (library, ids, source) = try library(photos: 30)
        let queue = PhotoQueue(database: library.database, nominalSize: 3)
        for id in ids { try queue.append(photoID: id, sourceID: source) }
        // Far over nominal, and every one of them kept: work already done is
        // not thrown away to hold a number.
        #expect(try queue.size() == 30)
    }

    @Test("A photo already queued is not queued twice")
    func duplicatesAreIgnored() throws {
        let (library, ids, source) = try library(photos: 2)
        let queue = PhotoQueue(database: library.database, nominalSize: 10)
        #expect(try queue.append(photoID: ids[0], sourceID: source))
        // A provider re-offering something we already hold is answering
        // honestly; it just has nothing new to contribute.
        #expect(!(try queue.append(photoID: ids[0], sourceID: source)))
        #expect(try queue.size() == 1)
    }

    @Test("Removing a photo from the pool takes it out of the queue")
    func poolRemovalClearsTheQueue() throws {
        let (library, ids, source) = try library(photos: 3)
        let queue = PhotoQueue(database: library.database, nominalSize: 10)
        for id in ids { try queue.append(photoID: id, sourceID: source) }

        try PhotoPool(database: library.database).remove(ids[1])
        #expect(try queue.size() == 2)
        #expect(try queue.peek(10).map(\.id) == [ids[0], ids[2]])
    }

    // MARK: - Providers that are busy
}
