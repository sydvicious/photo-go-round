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

    @Test("A new card lands among the cards present, never at the head, and shifts the rest")
    func placementIsAmongThePresent() throws {
        // **Random placement is back**, by rank rather than by key: migration 10.
        // The slot is injected here so the arithmetic can be asserted exactly;
        // `placementIsUniform` below covers the draw.
        let (library, ids, source) = try library(photos: 6)
        // The first card is not placed — an empty queue has one place to be —
        // so the first slot here is for the second card.
        let slots = [1, 1, 3, 2]
        var next = 0
        let queue = PhotoQueue(database: library.database, nominalSize: 10) { present in
            defer { next += 1 }
            return slots[next]
        }

        try queue.append(photoID: ids[0], sourceID: source)          // [0]
        try queue.append(photoID: ids[1], sourceID: source)          // slot 1 of 1 → [0, 1]
        try queue.append(photoID: ids[2], sourceID: source)          // slot 1 of 2 → [0, 2, 1]
        try queue.append(photoID: ids[3], sourceID: source)          // slot 3 of 3 → [0, 2, 1, 3]
        try queue.append(photoID: ids[4], sourceID: source)          // slot 2 of 4 → [0, 2, 4, 1, 3]

        #expect(try queue.peek(10).map(\.id) == [ids[0], ids[2], ids[4], ids[1], ids[3]])
        // The head never moved, whatever landed behind it.
        #expect(try queue.peek().first?.id == ids[0])
    }

    @Test("Placement is uniform from second to last")
    func placementIsUniform() throws {
        // Nineteen cards present and two hundred insertions, each removed again
        // so the population stays put: every slot from second to last should be
        // landed on, and the head never should. A slot that is never hit in two
        // hundred draws over nineteen has a probability under 0.002% of being
        // honest chance.
        let (library, ids, source) = try library(photos: 20)
        let queue = PhotoQueue(database: library.database, nominalSize: 20)
        for id in ids.prefix(19) { try queue.append(photoID: id, sourceID: source) }
        // Placed at random themselves, so their order is whatever it is — what
        // matters is that the newcomer's comings and goings leave it alone.
        let resident = try queue.peek(20).map(\.id)
        let newcomer = ids[19]

        var landed: Set<Int> = []
        for _ in 0..<200 {
            try queue.append(photoID: newcomer, sourceID: source)
            let index = try #require(try queue.peek(20).map(\.id).firstIndex(of: newcomer))
            landed.insert(index)
            try queue.remove(photoID: newcomer)
        }

        #expect(!landed.contains(0), "a new card displaced the head")
        #expect(landed == Set(1...19), "slots never landed on: \(Set(1...19).subtracting(landed).sorted())")
        // And the residents are still in the order they were queued.
        #expect(try queue.peek(20).map(\.id) == resident)
    }

    @Test("With placement at the tail, cards come out in the order they went in")
    func tailPlacementIsAFIFO() throws {
        let library = try TestLibrary()
        let source = try library.addSource()
        let ids = try library.addPhotos(60, to: source)
        let queue = PhotoQueue(
            database: library.database, nominalSize: 1000, placement: PhotoQueue.tail)

        for id in ids { try queue.append(photoID: id, sourceID: source) }

        let order = try queue.peek(Int.max).map(\.id)
        #expect(order == ids)

        var served: [Int64] = []
        while let card = try queue.takeHead() { served.append(card.id) }
        #expect(served == ids)
    }

    @Test("The card at the top is not starved by the ones queued after it")
    func theTopCardIsNotStarved() throws {
        // **Observed live on 2026-08-25**, under the `REAL` key of migration
        // 6: photo 8239 held the highest key for six and a half hours while
        // cards queued minutes earlier were served and replaced around it. A
        // key drawn between the lowest and highest present could never land
        // past the top card, so the top card was a fixed point. Integer ranks
        // shifted on insert have no such point — slot *n* is the tail and is
        // reachable — but the property is worth holding down whatever the
        // mechanism, because it died silently the first time.
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
            guard let card = try queue.takeHead() else { break }
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
        #expect(try queue.takeHead() == nil)
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
        while let card = try queue.takeHead() { served.append(card.id) }

        #expect(served.count == 3)
        #expect(Set(served) == Set(ids))
        #expect(try queue.size() == 0)
        #expect(try queue.takeHead() == nil)
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
        #expect(try queue.takeHead()?.id == peeked[0], "peek and take disagree about the head")
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
        _ = try queue.takeHead()
        #expect(try queue.size() == 9)
        #expect(try queue.needsTopUp())

        // All four answer, at their own pace. Nothing is refused, nothing is
        // evicted to make room.
        for id in ids[10..<14] { #expect(try queue.append(photoID: id, sourceID: source)) }
        #expect(try queue.size() == 13)
        #expect(!(try queue.needsTopUp()))

        // And it drains back down through the nominal size without any of the
        // overshoot being wasted.
        for _ in 0..<3 { _ = try queue.takeHead() }
        #expect(try queue.size() == 10)
        #expect(!(try queue.needsTopUp()))
        _ = try queue.takeHead()
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
        let queue = PhotoQueue(
            database: library.database, nominalSize: 10, placement: PhotoQueue.tail)
        for id in ids { try queue.append(photoID: id, sourceID: source) }

        try PhotoPool(database: library.database).remove(ids[1])
        #expect(try queue.size() == 2)
        #expect(try queue.peek(10).map(\.id) == [ids[0], ids[2]])
    }

    // MARK: - Providers that are busy
}
