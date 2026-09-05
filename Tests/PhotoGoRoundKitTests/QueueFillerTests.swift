import Foundation
import Testing

@testable import PhotoGoRoundKit

@Suite("Queue filling")
struct QueueFillerTests {

    /// A stand-in for the deck: hands out cards one at a time and then says it
    /// has nothing, which is the only two things a real dealer ever tells the
    /// filler.
    ///
    /// Counting the calls is the point: what matters here is not the answer but
    /// the *number of questions*, which is where filling goes wrong in both
    /// directions — too few and the queue starves, too many and it spins.
    ///
    /// **No source in the signature.** Dealing takes from one shuffle over the
    /// whole library, so which source a card turns out to belong to is an
    /// outcome rather than an input.
    final class MockDealer: @unchecked Sendable {
        private let queue: PhotoQueue
        private let sourceID: Int64
        private let lock = NSLock()
        private var remaining: [Int64]
        private var calls = 0

        init(queue: PhotoQueue, sourceID: Int64, photos: [Int64]) {
            self.queue = queue
            self.sourceID = sourceID
            self.remaining = photos
        }

        /// Non-async, and everything touching the database happens under the
        /// lock — a `Database` belongs to one isolation domain.
        func produce() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            guard !remaining.isEmpty else { return false }
            let photoID = remaining.removeFirst()
            return (try? queue.append(photoID: photoID, sourceID: sourceID)) ?? false
        }

        /// Overrides the queue's own nominal, so a test can raise the target the
        /// way changing the preference does.
        private var target: Int?

        func aimFor(_ size: Int) {
            lock.lock()
            target = size
            lock.unlock()
        }

        func isShort() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if let target { return ((try? queue.size()) ?? 0) < target }
            return (try? queue.needsTopUp()) == true
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    private func library(photos: Int, nominal: Int) throws
        -> (library: TestLibrary, queue: PhotoQueue, source: Int64, ids: [Int64])
    {
        let library = try TestLibrary()
        let source = try library.addSource()
        let ids = try library.addPhotos(photos, to: source)
        return (library, PhotoQueue(database: library.database, nominalSize: nominal), source, ids)
    }

    private func filler(_ dealer: MockDealer) -> QueueFiller {
        QueueFiller(isShort: { dealer.isShort() }, produce: { dealer.produce() })
    }

    /// A filler whose dealing actually suspends.
    ///
    /// Needed only to test overlap: a round of straight-line synchronous work
    /// never yields, so two rounds started together would run one after the
    /// other and never overlap at all — the test would pass or fail on
    /// scheduling rather than on the guard it is about.
    private func suspendingFiller(_ dealer: MockDealer) async  -> QueueFiller {
        QueueFiller(
            isShort: { dealer.isShort() },
            produce: {
                // Before the lock, never across it.
                await Task.yield()
                return dealer.produce()
            })
    }

    // MARK: - Stopping

    @Test("Filling stops when the queue reaches nominal")
    func fillsToNominalAndStops() async throws {
        let (_, queue, source, ids) = try library(photos: 100, nominal: 10)
        let dealer = MockDealer(queue: queue, sourceID: source, photos: ids)

        let round = await filler(dealer).fill()

        // **Exactly nominal.** This used to overshoot by up to the concurrency,
        // because lanes already in flight when the target was reached each added
        // one more. One lane cannot overshoot.
        #expect(try queue.size() == 10)
        #expect(round.produced == 10)
        #expect(round.exhausted == false)
        #expect(round.skipped == false)
    }

    @Test("A deck with nothing to deal is asked once, not forever")
    func exhaustedDeckIsAskedOnce() async throws {
        let (_, queue, source, _) = try library(photos: 10, nominal: 1000)
        // Offers nothing from the first question.
        let dealer = MockDealer(queue: queue, sourceID: source, photos: [])

        let round = await filler(dealer).fill()

        #expect(round.produced == 0)
        #expect(round.exhausted)
        // The bug this guards against is a round that asks, is told nothing, and
        // asks again forever.
        #expect(dealer.callCount == 1)
    }

    @Test("A library smaller than the queue fills what it has and stops")
    func smallLibraryDoesNotSpin() async throws {
        // A pool smaller than nominal can never satisfy it, so the stopping
        // condition has to be the deck saying *nothing* rather than the queue
        // saying *full*.
        let (_, queue, source, ids) = try library(photos: 20, nominal: 1000)
        let dealer = MockDealer(queue: queue, sourceID: source, photos: ids)

        let round = await filler(dealer).fill()

        #expect(try queue.size() == 20)
        #expect(round.produced == 20)
        #expect(round.exhausted)
        // Twenty productive questions and exactly one refusal.
        #expect(dealer.callCount == 21)
    }

    @Test("A queue already at nominal is not asked for anything")
    func fullQueueAsksNothing() async throws {
        let (library, queue, source, ids) = try library(photos: 100, nominal: 5)
        for id in ids.prefix(5) { try library.enqueue(id, sourceID: source) }

        let dealer = MockDealer(queue: queue, sourceID: source, photos: Array(ids.dropFirst(5)))
        let round = await filler(dealer).fill()

        #expect(dealer.callCount == 0)
        #expect(round.produced == 0)
        #expect(try queue.size() == 5)
    }

    // MARK: - Popping and repopulating

    @Test("Serving shortens the queue, and the next fill restores it")
    func servingDrainsAndFillingRestores() async throws {
        let (_, queue, source, ids) = try library(photos: 100, nominal: 10)
        let dealer = MockDealer(queue: queue, sourceID: source, photos: ids)
        let filling = filler(dealer)

        await filling.fill()
        let filled = try queue.size()

        var served: [Int64] = []
        for _ in 0..<6 {
            guard let card = try queue.takeHead() else { break }
            served.append(card.id)
        }
        #expect(served.count == 6)
        #expect(try queue.size() == filled - 6)
        // FIFO, and nothing handed out twice.
        #expect(Set(served).count == 6)

        // Six taken, six dealt back. The size of a burst is simply what the last
        // round of serving consumed — which is one card shown plus every card it
        // skipped past, and is why a burst on a real console is rarely one.
        let round = await filling.fill()
        #expect(round.produced == 6)
        #expect(try queue.size() == 10)
    }

    @Test("A drained queue refills at the rate the deck answers, not one per round")
    func refillIsNotRationed() async throws {
        // A single round must restore everything the deck is willing to give,
        // however far below nominal the pool is. Anything that rations it
        // starves a small library the moment something draws from it.
        let (_, queue, source, ids) = try library(photos: 50, nominal: 1000)
        let dealer = MockDealer(queue: queue, sourceID: source, photos: ids)

        await filler(dealer).fill()
        #expect(try queue.size() == 50)

        // Drain it completely, the way a fast consumer does.
        while try queue.takeHead() != nil {}
        #expect(try queue.size() == 0)

        // Re-offer the same photos and refill in one round.
        let again = MockDealer(queue: queue, sourceID: source, photos: ids)
        let round = await filler(again).fill()

        #expect(round.produced == 50, "one round should restore the whole library, not one card")
        #expect(try queue.size() == 50)
    }

    @Test("Overlapping rounds are dropped rather than stacked")
    func concurrentFillsDoNotMultiply() async throws {
        let (_, queue, source, ids) = try library(photos: 200, nominal: 100)
        let dealer = MockDealer(queue: queue, sourceID: source, photos: ids)
        let filling = await suspendingFiller(dealer)

        // Serving calls this once per picture handed over, so a fast consumer
        // starts rounds faster than they finish. Without the guard they would
        // multiply against each other.
        async let first = filling.fill()
        async let second = filling.fill()
        let rounds = await [first, second]

        #expect(rounds.contains { $0.skipped }, "one of two overlapping rounds should be dropped")
        #expect(try queue.size() == 100)
    }
}
