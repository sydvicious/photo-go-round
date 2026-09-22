import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// The rules of the fetcher, asserted against two mocks and no disk.
///
/// What it has to get right: walk the queue head first, fetch what is cold,
/// step past what is benched, stop on the disk, absorb a kick that lands
/// mid-round by looking again, and never fetch one card twice. The last is the
/// host's claim, which the mock stands in for by handing each card out once.
@Suite("Queue fetcher")
struct QueueFetcherTests {

    /// A queue of cards, handed out head first and each exactly once, the way
    /// the cache's claim makes the real one behave.
    private final class MockQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var cards: [(position: Int64, card: DeckCard, benched: Bool)] = []
        private var handedOut: Set<Int64> = []
        var blocked = false
        private(set) var asked: [Int64?] = []
        private(set) var fetched: [Int64] = []
        private(set) var inFlight = 0
        private(set) var peakInFlight = 0

        func append(_ count: Int, benched: Bool = false) {
            lock.lock()
            defer { lock.unlock() }
            for _ in 0..<count {
                let position = Int64(cards.count + 1)
                let card = DeckCard(
                    id: position, uuid: "u\(position)", sourceID: benched ? 2 : 1,
                    sourceUUID: "s", externalID: "p\(position).heic",
                    storage: .materialized, dealSeq: nil)
                cards.append((position, card, benched))
            }
        }

        func next(after: Int64?) -> QueueFetcher.Next {
            lock.lock()
            defer { lock.unlock() }
            asked.append(after)
            if blocked { return .blocked }
            for entry in cards where entry.position > (after ?? -1) {
                if entry.benched { return .benched(rank: entry.position) }
                guard !handedOut.contains(entry.position) else { continue }
                handedOut.insert(entry.position)
                return .card(entry.card, rank: entry.position, within: .seconds(60))
            }
            return .drained
        }

        func begin(_ card: DeckCard) {
            lock.lock()
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            fetched.append(card.id)
            lock.unlock()
        }

        func end() {
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }
    }

    private func fetcher(
        _ queue: MockQueue, concurrency: Int = 1,
        outcome: @escaping @Sendable (DeckCard) async -> QueueFetcher.Outcome = { _ in .fetched }
    ) -> QueueFetcher {
        QueueFetcher(
            concurrency: concurrency,
            next: { queue.next(after: $0) },
            fetch: { card, _ in
                queue.begin(card)
                defer { queue.end() }
                return await outcome(card)
            })
    }

    @Test("every cold card is fetched, head first")
    func fetchesHeadFirst() async {
        let queue = MockQueue()
        queue.append(5)

        let round = await fetcher(queue).kick()

        #expect(round == .init(fetched: 5, failed: 0, skipped: 0, stopped: .drained))
        #expect(queue.fetched == [1, 2, 3, 4, 5])
    }

    @Test("a benched card is stepped past and the ones behind it are fetched")
    func benchedIsSkipped() async {
        let queue = MockQueue()
        queue.append(1)
        queue.append(1, benched: true)
        queue.append(2)

        let round = await fetcher(queue).kick()

        #expect(round.fetched == 3)
        #expect(round.skipped == 1)
        #expect(queue.fetched == [1, 3, 4])
    }

    @Test("a failed fetch is counted and the round goes on")
    func failuresDoNotStopTheRound() async {
        let queue = MockQueue()
        queue.append(4)

        let round = await fetcher(queue) { card in card.id % 2 == 0 ? .failed : .fetched }.kick()

        #expect(round.fetched == 2)
        #expect(round.failed == 2)
        #expect(round.stopped == .drained)
    }

    @Test("the disk saying stop ends the round")
    func blockedStopsTheRound() async {
        let queue = MockQueue()
        queue.append(3)
        queue.blocked = true

        let round = await fetcher(queue).kick()

        #expect(round.stopped == .blocked)
        #expect(queue.fetched.isEmpty)
    }

    @Test("lanes run fetches at once, and never fetch one card twice")
    func lanesRunConcurrently() async {
        let queue = MockQueue()
        queue.append(12)

        let round = await fetcher(queue, concurrency: 4) { _ in
            try? await Task.sleep(for: .milliseconds(20))
            return .fetched
        }.kick()

        #expect(round.fetched == 12)
        #expect(queue.peakInFlight > 1, "the lanes ran one at a time")
        #expect(queue.peakInFlight <= 4)
        #expect(Set(queue.fetched).count == 12, "a card was fetched twice")
    }

    @Test("a kick during a round is absorbed, and the round looks again before it ends")
    func kickMidRoundIsAbsorbed() async {
        let queue = MockQueue()
        queue.append(2)
        let gate = Gate()

        let fetcher = fetcher(queue) { card in
            // The first fetch waits until the test has kicked again and dealt
            // more; the rest are instant.
            if card.id == 1 { await gate.wait() }
            return .fetched
        }

        let first = Task { await fetcher.kick() }
        // Let the round start and block on card 1.
        try? await Task.sleep(for: .milliseconds(50))
        queue.append(3)
        let second = await fetcher.kick()
        #expect(second.stopped == .alreadyRunning)
        gate.open()

        let round = await first.value
        // Five cards, one round: the late three were picked up by the walk
        // that was already running, or by the extra look the kick bought.
        #expect(round.fetched == 5)
        #expect(Set(queue.fetched).count == 5)
    }

    @Test("an empty queue is a round that does nothing")
    func emptyQueueDrains() async {
        let round = await fetcher(MockQueue()).kick()
        #expect(round == .init(fetched: 0, failed: 0, skipped: 0, stopped: .drained))
    }

    /// A one-shot latch a fetch can wait on.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            opened = true
            let pending = waiters
            waiters = []
            lock.unlock()
            for waiter in pending { waiter.resume() }
        }
    }
}
