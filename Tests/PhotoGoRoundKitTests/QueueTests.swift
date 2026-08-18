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

    @Test("An empty queue answers 'no photos', which is not an error")
    func emptyQueueServesNothing() throws {
        let library = try TestLibrary()
        let queue = PhotoQueue(database: library.database, nominalSize: 10)
        #expect(try queue.serve() == nil)
        #expect(try queue.size() == 0)
        // A fresh install starts here and stays here until providers deliver.
        #expect(try queue.needsTopUp())
    }

    @Test("Serving returns the head and shortens the queue")
    func servingDrainsInOrder() throws {
        let (library, ids, source) = try library(photos: 3)
        let queue = PhotoQueue(database: library.database, nominalSize: 10)
        for id in ids { try queue.append(photoID: id, sourceID: source) }

        #expect(try queue.size() == 3)
        #expect(try queue.serve()?.id == ids[0])
        #expect(try queue.serve()?.id == ids[1])
        #expect(try queue.size() == 1)
        #expect(try queue.serve()?.id == ids[2])
        #expect(try queue.serve() == nil)
    }

    @Test("Peeking shows what is next without consuming it")
    func peekingDoesNotConsume() throws {
        let (library, ids, source) = try library(photos: 3)
        let queue = PhotoQueue(database: library.database, nominalSize: 10)
        for id in ids { try queue.append(photoID: id, sourceID: source) }

        #expect(try queue.peek(2).map(\.id) == Array(ids.prefix(2)))
        #expect(try queue.size() == 3)
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

    @Test("A source runs several fetches at once, then ignores the rest")
    func busySourcesIgnoreRequestsBeyondTheirLimit() async throws {
        let worker = SourceWorker(sourceID: 1, concurrency: 4)
        let started = Mutex(0)
        let release = DispatchSemaphore(value: 0)

        // Four requests start and block. Fetching is nearly all latency, so
        // running one at a time would leave the provider idle for most of it.
        for _ in 0..<4 {
            worker.request {
                started.withLock { $0 += 1 }
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        release.wait()
                        continuation.resume()
                    }
                }
            }
        }
        while started.withLock({ $0 }) < 4 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(worker.inFlightCount == 4)

        // Anything beyond the limit is dropped on the floor, which is what
        // removes the need for anyone to track what is in flight.
        for _ in 0..<10 { worker.request { started.withLock { $0 += 1 } } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(started.withLock { $0 } == 4)

        for _ in 0..<4 { release.signal() }
        while worker.isBusy { try await Task.sleep(for: .milliseconds(5)) }

        // With slots free it accepts again.
        worker.request { started.withLock { $0 += 1 } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(started.withLock { $0 } == 5)
    }

    @Test("Concurrency is per source, so a slow one cannot crowd out a fast one")
    func concurrencyIsPerSource() async throws {
        let workers = SourceWorkers(concurrency: 2)
        let slow = workers.worker(for: 1)
        let fast = workers.worker(for: 2)
        let release = DispatchSemaphore(value: 0)
        let done = Mutex(0)

        for _ in 0..<2 {
            slow.request {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        release.wait()
                        continuation.resume()
                    }
                }
            }
        }
        while slow.inFlightCount < 2 { try await Task.sleep(for: .milliseconds(5)) }

        // The slow source is saturated; the fast one is unaffected.
        fast.request { done.withLock { $0 += 1 } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(done.withLock { $0 } == 1)

        for _ in 0..<2 { release.signal() }
        while slow.isBusy { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("Workers are kept per source and dropped when a source goes")
    func workersFollowTheirSources() {
        let workers = SourceWorkers()
        let first = workers.worker(for: 1)
        #expect(workers.worker(for: 1) === first)
        #expect(workers.worker(for: 2) !== first)

        workers.retain([1])
        #expect(workers.worker(for: 2) !== first)
        #expect(workers.busyCount == 0)
        #expect(workers.worker(for: 1).concurrency == SourceWorker.defaultConcurrency)
    }
}
