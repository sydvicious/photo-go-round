import Foundation
import Testing

@testable import PhotoGoRoundKit

@Suite("Queue filling")
struct QueueFillerTests {

    /// A stand-in for a source provider: hands out its photos one at a time and
    /// then says it has nothing, which is the only two things a real producer
    /// ever tells the filler.
    ///
    /// Counting the calls is the point: what matters here is not the answer but
    /// the *number of questions*, which is where filling goes wrong in both
    /// directions — too few and the queue starves, too many and it spins.
    final class MockProducer: @unchecked Sendable {
        private let queue: PhotoQueue
        private let lock = NSLock()
        private var remaining: [Int64: [Int64]] = [:]
        private var calls: [Int64: Int] = [:]

        init(queue: PhotoQueue, photos: [Int64: [Int64]]) {
            self.queue = queue
            self.remaining = photos
        }

        /// Non-async, and everything touching the database happens under the
        /// lock — a `Database` belongs to one isolation domain, and the filler
        /// runs several lanes at once. The host does this by giving each lane its
        /// own connection; a test with one in-memory database serialises instead.
        func produce(_ sourceID: Int64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            calls[sourceID, default: 0] += 1
            guard var mine = remaining[sourceID], !mine.isEmpty else { return false }
            let photoID = mine.removeFirst()
            remaining[sourceID] = mine
            return (try? queue.append(photoID: photoID, sourceID: sourceID)) ?? false
        }

        func isShort() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return (try? queue.needsTopUp()) == true
        }

        func callCount(_ sourceID: Int64) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return calls[sourceID] ?? 0
        }

        var totalCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls.values.reduce(0, +)
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

    // MARK: - Stopping

    @Test("Filling stops when the queue reaches nominal")
    func fillsToNominalAndStops() async throws {
        let (_, queue, source, ids) = try library(photos: 100, nominal: 10)
        let producer = MockProducer(queue: queue, photos: [source: ids])
        let filler = QueueFiller(isShort: { producer.isShort() }, produce: { producer.produce($0) })

        let round = await filler.fill(sources: [source])

        // Nominal is a target, not a ceiling: lanes already in flight when it is
        // reached each add one more, bounded by the concurrency.
        #expect(try queue.size() >= 10)
        #expect(try queue.size() <= 10 + filler.concurrency)
        #expect(round.produced == (try queue.size()))
        #expect(round.skipped == false)
    }

    @Test("A source with nothing to offer is dropped rather than asked again")
    func exhaustedSourceIsAskedOnce() async throws {
        let (_, queue, source, _) = try library(photos: 10, nominal: 1000)
        // Offers nothing from the first question.
        let producer = MockProducer(queue: queue, photos: [source: []])
        let filler = QueueFiller(isShort: { producer.isShort() }, produce: { producer.produce($0) })

        let round = await filler.fill(sources: [source])

        #expect(round.produced == 0)
        #expect(round.exhausted == 1)
        // At most one question per lane. The bug this guards against is a lane
        // that asks, is told nothing, and asks again forever.
        #expect(producer.callCount(source) <= filler.concurrency)
    }

    @Test("A library smaller than the queue fills what it has and stops")
    func smallLibraryDoesNotSpin() async throws {
        // A pool smaller than nominal can never satisfy it, so the stopping
        // condition has to be the source saying *nothing* rather than the queue
        // saying *full*.
        let (_, queue, source, ids) = try library(photos: 20, nominal: 1000)
        let producer = MockProducer(queue: queue, photos: [source: ids])
        let filler = QueueFiller(isShort: { producer.isShort() }, produce: { producer.produce($0) })

        let round = await filler.fill(sources: [source])

        #expect(try queue.size() == 20)
        #expect(round.produced == 20)
        #expect(round.exhausted == 1)
        // Twenty productive questions plus at most one refusal per lane.
        #expect(producer.callCount(source) <= 20 + filler.concurrency)
    }

    @Test("A queue already at nominal is not asked for anything")
    func fullQueueAsksNothing() async throws {
        let (library, queue, source, ids) = try library(photos: 100, nominal: 5)
        for id in ids.prefix(5) { try library.enqueue(id, sourceID: source) }

        let producer = MockProducer(queue: queue, photos: [source: Array(ids.dropFirst(5))])
        let filler = QueueFiller(isShort: { producer.isShort() }, produce: { producer.produce($0) })
        let round = await filler.fill(sources: [source])

        #expect(producer.totalCalls == 0)
        #expect(round.produced == 0)
        #expect(try queue.size() == 5)
    }

    @Test("One exhausted source does not stop another from filling")
    func oneExhaustedSourceDoesNotStopTheRest() async throws {
        let library = try TestLibrary()
        let empty = try library.addSource(locator: "/empty")
        let full = try library.addSource(locator: "/full")
        let ids = try library.addPhotos(30, to: full, namePrefix: "full")

        let queue = PhotoQueue(database: library.database, nominalSize: 20)
        let producer = MockProducer(queue: queue, photos: [empty: [], full: ids])
        let filler = QueueFiller(isShort: { producer.isShort() }, produce: { producer.produce($0) })

        let round = await filler.fill(sources: [empty, full])

        #expect(try queue.size() >= 20)
        #expect(round.exhausted == 1)
        #expect(producer.callCount(empty) <= filler.concurrency)
    }

    // MARK: - Popping and repopulating

    @Test("Serving shortens the queue, and the next fill restores it")
    func servingDrainsAndFillingRestores() async throws {
        let (_, queue, source, ids) = try library(photos: 100, nominal: 10)
        let producer = MockProducer(queue: queue, photos: [source: ids])
        let filler = QueueFiller(isShort: { producer.isShort() }, produce: { producer.produce($0) })

        await filler.fill(sources: [source])
        let filled = try queue.size()

        var served: [Int64] = []
        for _ in 0..<6 {
            guard let card = try queue.serve() else { break }
            served.append(card.id)
        }
        #expect(served.count == 6)
        #expect(try queue.size() == filled - 6)
        // FIFO, and nothing handed out twice.
        #expect(Set(served).count == 6)

        await filler.fill(sources: [source])
        #expect(try queue.size() >= 10)
    }

    @Test("A drained queue refills at the rate the producer answers, not one per round")
    func refillIsNotRationed() async throws {
        // A single round must restore everything the producer is willing to
        // give, however far below nominal the pool is. Anything that rations it
        // starves a small library the moment something draws from it.
        let (_, queue, source, ids) = try library(photos: 50, nominal: 1000)
        let producer = MockProducer(queue: queue, photos: [source: ids])
        let filler = QueueFiller(isShort: { producer.isShort() }, produce: { producer.produce($0) })

        await filler.fill(sources: [source])
        #expect(try queue.size() == 50)

        // Drain it completely, the way a fast consumer does.
        while try queue.serve() != nil {}
        #expect(try queue.size() == 0)

        // Re-offer the same photos and refill in one round.
        let again = MockProducer(queue: queue, photos: [source: ids])
        let refiller = QueueFiller(isShort: { again.isShort() }, produce: { again.produce($0) })
        let round = await refiller.fill(sources: [source])

        #expect(round.produced == 50, "one round should restore the whole library, not one card")
        #expect(try queue.size() == 50)
    }

    @Test("Overlapping rounds are dropped rather than stacked")
    func concurrentFillsDoNotMultiply() async throws {
        let (_, queue, source, ids) = try library(photos: 200, nominal: 100)
        let producer = MockProducer(queue: queue, photos: [source: ids])
        let filler = QueueFiller(isShort: { producer.isShort() }, produce: { producer.produce($0) })

        // Serving calls this once per picture handed over, so a fast consumer
        // starts rounds faster than they finish. Without the guard they would
        // multiply against each other.
        async let first = filler.fill(sources: [source])
        async let second = filler.fill(sources: [source])
        let rounds = await [first, second]

        #expect(rounds.contains { $0.skipped }, "one of two overlapping rounds should be dropped")
        #expect(try queue.size() <= 100 + filler.concurrency)
    }
}
