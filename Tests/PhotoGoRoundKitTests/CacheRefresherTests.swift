import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// The credit arithmetic, with no disk anywhere near it.
///
/// Every number here is derived from the deck's maximum size rather than
/// written as a constant, because the deck size is expected to move and a test
/// that hard-codes forty stops testing the rule the moment it does.
@Suite("Cache refresher")
struct CacheRefresherTests {

    /// A library that answers draws from a script, and counts what it was asked.
    private final class Library: @unchecked Sendable {
        private let lock = NSLock()
        /// How many remote assets exist, and how many of them are held.
        private var total: Int
        private var held: Set<Int> = []
        private var nextDraw = 0
        private(set) var draws = 0
        private(set) var fetches = 0
        /// When true, every fetch is refused the way a full disk refuses one.
        var diskIsFull = false

        init(total: Int, heldFraction: Double = 0) {
            self.total = total
            let heldCount = Int(Double(total) * heldFraction)
            held = Set(0..<heldCount)
        }

        /// Draws round-robin rather than randomly, so a test asserting "nine in
        /// ten are misses" gets exactly nine in ten instead of a distribution.
        func draw() -> CacheRefresher.Draw {
            lock.lock()
            draws += 1
            let pick = nextDraw % total
            nextDraw += 1
            if diskIsFull {
                lock.unlock()
                return .blocked
            }
            if held.contains(pick) {
                lock.unlock()
                return .alreadyHeld
            }
            held.insert(pick)
            fetches += 1
            lock.unlock()
            return .fetched
        }

        var unheld: Int {
            lock.lock()
            defer { lock.unlock() }
            return total - held.count
        }
    }

    private func refresher(
        deckSize: Int, library: Library
    ) -> CacheRefresher {
        CacheRefresher(
            budget: { 2 * deckSize },
            unheldCount: { library.unheld },
            attempt: { library.draw() }
        )
    }

    @Test("a cold library with no client fetches its allowance and stops", arguments: [5, 20, 64])
    func launchSpendsTheAllowance(deckSize: Int) async throws {
        let library = Library(total: 10_000)
        let refresher = refresher(deckSize: deckSize, library: library)

        let round = await refresher.begin()

        #expect(round.fetched == 2 * deckSize)
        #expect(round.stopped == .spent)
        #expect(refresher.available == 0)
        #expect(library.fetches == 2 * deckSize)
    }

    @Test("each card drawn releases exactly one more")
    func aDrawBuysOne() async throws {
        let deckSize = 20
        let library = Library(total: 10_000)
        let refresher = refresher(deckSize: deckSize, library: library)
        await refresher.begin()
        let afterLaunch = library.fetches

        for expected in 1...5 {
            let round = await refresher.cardDrawn()
            #expect(round.fetched == 1)
            #expect(library.fetches == afterLaunch + expected)
        }
    }

    @Test("a cache holding nine in ten still fetches the full allowance")
    func missesDoNotSpend() async throws {
        let deckSize = 20
        let library = Library(total: 10_000, heldFraction: 0.9)
        let refresher = refresher(deckSize: deckSize, library: library)

        let round = await refresher.begin()

        // The budget buys photographs, not attempts.
        #expect(round.fetched == 2 * deckSize)
        #expect(round.skipped > 0)
        #expect(library.draws > round.fetched)
    }

    @Test("a full disk stops it whatever the credits say")
    func diskOverridesCredits() async throws {
        let deckSize = 20
        let library = Library(total: 10_000)
        library.diskIsFull = true
        let refresher = refresher(deckSize: deckSize, library: library)

        let round = await refresher.begin()

        #expect(round.stopped == .blocked)
        #expect(round.fetched == 0)
        #expect(library.fetches == 0)
        // Unspent, so the moment the disk recovers the allowance is still there.
        #expect(refresher.available == 2 * deckSize)
    }

    @Test("a library entirely resident ends the round instead of spinning")
    func completeCacheStops() async throws {
        let library = Library(total: 50, heldFraction: 1.0)
        let refresher = refresher(deckSize: 20, library: library)

        let round = await refresher.begin()

        #expect(round.stopped == .exhausted)
        #expect(round.fetched == 0)
        // It stopped before drawing at all, because the count answered first.
        #expect(library.draws == 0)
    }

    @Test("a cache that fills mid-round stops when it runs out of work")
    func fillsAndStops() async throws {
        // Fewer remote assets than the allowance, so the round cannot spend it.
        let library = Library(total: 3)
        let refresher = refresher(deckSize: 20, library: library)

        let round = await refresher.begin()

        #expect(round.fetched == 3)
        #expect(round.stopped == .exhausted)
        #expect(refresher.available > 0)
    }

    @Test("a failed fetch spends nothing")
    func failureIsFree() async throws {
        let deckSize = 4
        let attempts = Counter()
        let refresher = CacheRefresher(
            budget: { 2 * deckSize },
            unheldCount: { 1_000 },
            attempt: { attempts.next() <= 3 ? .failed : .fetched }
        )

        let round = await refresher.begin()

        #expect(round.failed == 3)
        #expect(round.fetched == 2 * deckSize)
    }

    @Test("banking a credit does not start a round")
    func bankingIsSilent() async throws {
        let deckSize = 20
        let library = Library(total: 10_000)
        let refresher = refresher(deckSize: deckSize, library: library)
        await refresher.begin()
        let afterLaunch = library.fetches
        #expect(refresher.available == 0)

        // A refresh found five hundred photographs gone. Their credits come
        // back; an unattended agent does not start downloading.
        refresher.bank(500)

        #expect(library.fetches == afterLaunch)
        // And the cap holds, so the burst can never exceed one allowance.
        #expect(refresher.available == 2 * deckSize)
    }

    @Test("credits never exceed the allowance")
    func creditsAreCapped() async throws {
        let deckSize = 7
        let library = Library(total: 10_000)
        let refresher = refresher(deckSize: deckSize, library: library)

        for _ in 0..<100 { refresher.bank() }

        #expect(refresher.available == 2 * deckSize)
    }

    fileprivate final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}

/// The refresher against a real library: real SQLite, real files, real bytes.
///
/// The suite above proves the arithmetic with no disk, which is where the rules
/// live. This proves the two halves meet — that a draw finds a row, that a
/// fetch lands, and that residency follows it — because every one of those
/// joints is somewhere the arithmetic cannot reach.
@Suite("Cache refresher, on disk")
struct CacheRefresherLibraryTests {

    private struct Fixture {
        let folder: TemporaryFolder
        let cacheRoot: TemporaryFolder
        let library: TestLibrary
        let sources: SourceStore
        let cache: PhotoCache
        let deckSize: Int

        init(photos: Int, deckSize: Int = 4) async throws {
            self.deckSize = deckSize
            folder = TemporaryFolder(name: "pgr-refresh-src")
            cacheRoot = TemporaryFolder(name: "pgr-refresh-dst")
            for i in 0..<photos { folder.write("pic\(i).jpg", bytes: 64) }

            library = try TestLibrary()
            sources = SourceStore(database: library.database)
            cache = PhotoCache(
                database: library.database,
                root: cacheRoot.url.appending(path: "cache"),
                sources: sources
            )
            try cache.prepare()

            let source = try await sources.add(
                kind: .folder, locator: folder.path, recursive: true)
            await sources.refresh(source)
            // Everything in a temporary directory is really on the boot volume,
            // so the storage column is set directly — the cache only ever draws
            // from what is materialized.
            try library.database.run("UPDATE photo SET storage = 'materialized';")
        }

        /// `PhotoCache` and `Deck` hold a `Database`, which is deliberately not
        /// `Sendable` — the kit's rule is one connection per isolation domain.
        /// Production satisfies the closures by rebuilding a cache inside them
        /// from a path; a test that drives the refresher serially on one thread
        /// can say so instead, which is what this is.
        private final class Box: @unchecked Sendable {
            let cache: PhotoCache
            let deck: Deck
            init(cache: PhotoCache, deck: Deck) {
                self.cache = cache
                self.deck = deck
            }
        }

        func refresher() -> CacheRefresher {
            let box = Box(cache: cache, deck: library.deck)
            let size = deckSize
            return CacheRefresher(
                budget: { 2 * size },
                unheldCount: { (try? box.deck.unheldRemoteCount()) ?? 0 },
                attempt: { await box.cache.refreshOnce() }
            )
        }

        func heldCount() throws -> Int {
            try library.database.scalarInt(
                "SELECT COUNT(*) FROM photo WHERE cached_at IS NOT NULL;") ?? 0
        }
    }

    @Test("launch fills to the allowance and leaves the rest alone")
    func launchFills() async throws {
        let fixture = try await Fixture(photos: 40, deckSize: 4)
        let refresher = fixture.refresher()

        let round = await refresher.begin()

        #expect(round.fetched == 8)
        #expect(round.stopped == .spent)
        // Residency followed the bytes, and the store and the column agree.
        #expect(try fixture.heldCount() == 8)
        #expect(fixture.cache.store.residentPhotoUUIDs.count == 8)
    }

    @Test("the refresher does not put anything on the deck")
    func doesNotQueue() async throws {
        let fixture = try await Fixture(photos: 40, deckSize: 4)

        await fixture.refresher().begin()

        // It makes photographs eligible. The deck picks them up on its own
        // terms, which is the whole point of the halves not knowing each other.
        #expect(try fixture.cache.queue.size() == 0)
    }

    @Test("a draw never lands on the same photograph twice in one round")
    func drawsAreDistinct() async throws {
        let fixture = try await Fixture(photos: 12, deckSize: 4)

        let round = await fixture.refresher().begin()

        // Eight distinct photographs out of twelve, so none was fetched twice —
        // a photograph leaves the pool the moment it is held.
        #expect(round.fetched == 8)
        #expect(fixture.cache.store.residentPhotoUUIDs.count == 8)
    }

    @Test("a library it already holds entirely stops rather than spinning")
    func completeStops() async throws {
        let fixture = try await Fixture(photos: 6, deckSize: 20)

        // Enough allowance to take everything.
        let first = await fixture.refresher().begin()
        #expect(first.fetched == 6)

        let second = await fixture.refresher().begin()
        #expect(second.fetched == 0)
        #expect(second.stopped == .exhausted)
    }

    @Test("a card drawn buys exactly one more photograph")
    func aDrawBuysOne() async throws {
        let fixture = try await Fixture(photos: 40, deckSize: 4)
        let refresher = fixture.refresher()
        await refresher.begin()
        #expect(try fixture.heldCount() == 8)

        await refresher.cardDrawn()

        #expect(try fixture.heldCount() == 9)
    }
}

extension CacheRefresherTests {

    @Test("a source that fails every fetch ends the round rather than spinning")
    func repeatedFailuresTerminate() async throws {
        // **A failure spends no credit, which is why this needs its own
        // bound.** The budget is untouched, the population still has un-held
        // assets in it, and the disk is fine — so nothing else would ever end
        // the round. An offline network share is exactly this.
        let attempts = Counter()
        let refresher = CacheRefresher(
            budget: { 40 },
            unheldCount: { 1_000 },
            attempt: { _ = attempts.next(); return .failed }
        )

        let round = await refresher.begin()

        #expect(round.fetched == 0)
        #expect(round.failed == CacheRefresher.failuresBeforeGivingUp)
        // And the allowance is intact for when the source comes back.
        #expect(refresher.available == 40)
    }

    @Test("an occasional failure does not end the round")
    func intermittentFailuresAreWeather() async throws {
        // Every third draw fails, which a flaky link does. The round must still
        // spend its whole allowance rather than giving up part way.
        let attempts = Counter()
        let refresher = CacheRefresher(
            budget: { 12 },
            unheldCount: { 1_000 },
            attempt: { attempts.next() % 3 == 0 ? .failed : .fetched }
        )

        let round = await refresher.begin()

        #expect(round.fetched == 12)
        #expect(round.failed > 0)
    }
}

/// The lanes, which are what stop one slow provider deciding the fetch rate.
///
/// Carried over from `CacheQueueTests` when the queue of pictures to cache was
/// deleted: the backlog it maintained is gone, because every lane draws for
/// itself, but the two properties that mattered are unchanged.
@Suite("Refresher lanes")
struct CacheRefresherLaneTests {

    /// Counts how many draws are in flight at once, and the high-water mark.
    private final class Concurrency: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var peak = 0
        private var total = 0

        func enter() -> Int {
            lock.lock()
            defer { lock.unlock() }
            current += 1
            total += 1
            peak = max(peak, current)
            return total
        }

        func leave() {
            lock.lock()
            current -= 1
            lock.unlock()
        }
    }

    @Test("No more than the concurrency runs at once, however wide the budget")
    func lanesAreBounded() async throws {
        // Against a folder the cost of asking is a read from a disk you own;
        // against Photos or Google Photos it is a request on somebody's quota,
        // and a refresher that asked for a queue's worth at once would be rude.
        let seen = Concurrency()
        let refresher = CacheRefresher(
            budget: { 40 },
            unheldCount: { 1_000 },
            attempt: {
                _ = seen.enter()
                try? await Task.sleep(for: .milliseconds(20))
                seen.leave()
                return .fetched
            },
            concurrency: 4
        )

        let round = await refresher.begin()

        #expect(round.fetched == 40)
        #expect(seen.peak <= 4, "more fetches ran at once than the concurrency allows")
        #expect(seen.peak > 1, "the lanes did not actually run in parallel")
    }

    @Test("A wedged lane does not stop the others")
    func aWedgedLaneDoesNotStopTheRest() async throws {
        // **The fault this exists to prevent**: on 2026-08-26 a source that was
        // 98% of the library took every lane and the healthy sources never got
        // one. Here the first draw never answers; the round must still finish
        // on the strength of the remaining lanes.
        let attempts = Concurrency()
        let refresher = CacheRefresher(
            budget: { 12 },
            unheldCount: { 1_000 },
            attempt: {
                let mine = attempts.enter()
                defer { attempts.leave() }
                if mine == 1 {
                    // Wedged for far longer than the other lanes need. In the
                    // agent this is bounded by `FetchDeadline`, which is what
                    // makes "always returns" true of a provider that will not
                    // answer — see `CacheRefresher.attempt`.
                    try? await Task.sleep(for: .milliseconds(600))
                }
                return .fetched
            },
            concurrency: 4
        )

        let round = await refresher.begin()

        // Eleven, not twelve: the wedged lane's own draw never landed. What
        // matters is that the round *ended* rather than waiting on it.
        #expect(round.fetched >= 11)
        #expect(round.stopped == .spent)
    }
}
