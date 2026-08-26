import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import PhotoGoRoundAgentAPI

/// The serving algorithm, square by square.
///
/// > 1. See if the pic in the queue is in the cache, and if it is, serve it.
/// > 2. Otherwise, fire off a separate process to cache the picture if possible,
/// >    but the queue moves on and tries until it finds one.
/// > 3. If it cycles the entire queue, return no picture.
/// > 4. When the caching for a pic is finished, add it back to the queue.
///
/// It is a simpler algorithm than the one it replaces and has more cases,
/// because everything that used to be decided in advance — is this source
/// mounted, are these bytes held — is now decided by trying, one card at a time,
/// with the queue moving underneath.
@Suite("Serving")
struct ServeWalkTests {

    /// Collects what the two queues said, in order, so a test can assert on the
    /// decisions rather than on the outcome alone.
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [QueueEvent] = []

        var log: @Sendable (QueueEvent) -> Void {
            { [self] event in
                lock.lock()
                events.append(event)
                lock.unlock()
            }
        }

        var all: [QueueEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        /// The console lines, which is what a person actually reads.
        var lines: [String] { all.map(\.line) }

        func count(where matches: (QueueEvent) -> Bool) -> Int { all.filter(matches).count }
    }

    /// Records what was asked to be cached, without fetching any of it — so a
    /// test can watch serving hand work off and never wait for it.
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [Int64] = []

        var want: @Sendable (Int64) -> Void {
            { [self] id in
                lock.lock()
                ids.append(id)
                lock.unlock()
            }
        }

        /// A credit handed back, which is what a vanished card now produces
        /// where it used to produce a fetch request.
        func credit() {
            lock.lock()
            ids.append(0)
            lock.unlock()
        }

        var all: [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }
    }

    private struct Fixture {
        let folder: TemporaryFolder
        let cacheRoot: TemporaryFolder
        let library: TestLibrary
        let bytes: PhotoStore
        let store: SourceStore
        var cache: PhotoCache
        let source: Source
        let heard = Heard()
        let asked = Asked()

        /// Counts what the walk asked of the source, when a test cares.
        let counting: CountingProvider

        /// `materialized` decides whether these photographs need fetching at
        /// all: a referenced one *is* the file on its source and is never
        /// copied, so it is never asked for.
        init(photos: [String], materialized: Bool = true) async throws {
            folder = TemporaryFolder(name: "pgr-walk-src")
            cacheRoot = TemporaryFolder(name: "pgr-walk-dst")
            for name in photos { folder.write(name, bytes: 2048) }

            library = try TestLibrary()
            bytes = PhotoStore(root: cacheRoot.url.appending(path: "cache"))
            let access = UnsandboxedFileAccess()
            counting = CountingProvider(wrapping: FolderSourceProvider(fileAccess: access))
            store = SourceStore(
                database: library.database, fileAccess: access,
                providers: [counting, FileSourceProvider(fileAccess: access)], bytes: bytes)
            cache = PhotoCache(
                database: library.database, root: cacheRoot.url.appending(path: "cache"),
                sources: store, store: bytes)
            try cache.prepare()

            source = try await store.add(kind: .folder, locator: folder.path)
            _ = await store.refresh(source)
            if materialized {
                try library.database.run("UPDATE photo SET storage = 'materialized';")
            }
            cache.log = heard.log
            cache.creditReturned = asked.credit
        }

        /// **Bytes first, then cards.** The deck's pool is what the cache
        /// holds, so dealing before fetching deals nothing at all. This is the
        /// refresher's job, done synchronously.
        func cacheAll() async throws {
            var attempts = 0
            while try cache.unheldRemoteCount() > 0, attempts < 200 {
                attempts += 1
                if await cache.refreshOnce() == .blocked { break }
            }
        }

        @discardableResult
        func dealAll() throws -> Int {
            var dealt = 0
            while try cache.deal() { dealt += 1 }
            return dealt
        }

        func goOffline() throws {
            try library.database.run(
                "UPDATE source SET locator = :l WHERE id = :id;",
                ["l": "/Volumes/NotMounted/photos", "id": .int(source.id)])
        }

        /// The one photograph a single-photo fixture has, straight from the
        /// row. What the cache's random draw would have landed on.
        func firstPhoto() throws -> DeckCard? {
            let first = try library.database.first(
                "SELECT id FROM photo ORDER BY id LIMIT 1;"
            ) { try $0.int64("id") }
            guard let id = first else { return nil }
            return try library.deck.card(photoID: id)
        }

        var queued: Int { (try? cache.queue.size()) ?? 0 }
        /// **How many photographs the library still has**, not how many the
        /// deck can deal. These tests are about whether a row survived a
        /// failure, and `Deck.poolSize` stopped answering that in v2 — it
        /// counts what is servable, so a photograph that is kept but uncached
        /// is absent from it and present here.
        var pooled: Int {
            (try? library.database.scalarInt("SELECT COUNT(*) FROM photo;")) ?? 0
        }
        var resident: Int { (try? cache.status())?.residentCount ?? 0 }
    }

    // MARK: - The head of the deck is the picture

    @Test("A card whose bytes are here is the picture")
    func cachedCardIsServed() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try await fixture.cacheAll()
        try fixture.dealAll()

        let served = try #require(try await fixture.cache.serve())
        #expect(served.card.externalID == "a.png")
        #expect(fixture.asked.all.isEmpty, "nothing needed fetching, so nothing was asked for")
        // No box was asked for, so what goes out is the original rather than a
        // kept resize — and the line says which, because that is the only place
        // a console can see whether the renderings are earning their disk.
        #expect(
            fixture.heard.lines.contains {
                $0.hasPrefix("SERVE: a.png (source ")
                    && $0.contains(" is here as its original, showing it — ")
            })
    }

    @Test("Serving takes it off the queue, so the next request is a different picture")
    func servingConsumesTheCard() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try await fixture.cacheAll()
        try fixture.dealAll()
        #expect(fixture.queued == 2)

        let first = try #require(try await fixture.cache.serve())
        let second = try #require(try await fixture.cache.serve())
        #expect(first.card.id != second.card.id)
        #expect(fixture.queued == 0)
    }



    // MARK: - Nothing to show

    @Test("An empty pool deals nothing, and serving says so")
    func anEmptyPoolSaysSo() async throws {
        // **This used to be about running out of *time*.** The walk had a
        // two-second budget because a cold queue on a network volume could take
        // a minute to go through, and telling the two apart mattered. Neither
        // exists now: a card is only dealt once its bytes are here, so there is
        // nothing slow to walk past and nothing to time.
        //
        // What is left is the honest cold start — every photograph remote, the
        // cache holding none of them, so the deck has nothing to deal and
        // serving has nothing to take.
        let fixture = try await Fixture(photos: ["a.png", "b.png"])

        #expect(try fixture.dealAll() == 0)
        #expect(try await fixture.cache.serve() == nil)
        #expect(fixture.heard.lines.contains("SERVE: nothing to show — out of cards, walked 0"))
    }

    @Test("The card actually served is still checked against its source")
    func theServedCardIsStillVerified() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try await fixture.cacheAll()
        try fixture.dealAll()
        fixture.counting.reset()

        _ = try #require(try await fixture.cache.serve())

        // The guarantee is unchanged: a photograph the user deleted is never
        // shown, not even one we hold our own copy of.
        #expect(fixture.counting.checks == 1)
    }

    @Test("An empty queue answers no picture without walking anything")
    func anEmptyQueueAnswersNothing() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        #expect(try await fixture.cache.serve() == nil)
        #expect(fixture.heard.lines.contains("SERVE: nothing to show — out of cards, walked 0"))
    }

    // MARK: - Fetching, and what a failure means about the photograph

    /// **Reversed 2026-08-24.** This suite used to assert the opposite — that a
    /// finished fetch left the queue alone and the photograph waited to be dealt
    /// again — on the reasoning that the queue's composition is the deck's
    /// business and reinstating fetched cards lets the fastest source drift into
    /// owning it. A night of running showed the reasoning was answering the
    /// wrong question: a photograph waiting to be dealt again is waiting on a
    /// uniform draw from the whole library, which for fourteen thousand
    /// photographs never comes. The drift is handled by pacing the deal to
    /// pictures actually served instead. The old assertion is gone rather than
    /// disabled; `fetchingReturnsTheCardToTheQueue` above is its replacement.

    @Test("Asking for a photograph already cached costs a skip, not a second fetch")
    func cachingSomethingAlreadyHeldDoesNothing() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        // **Not via the queue.** These are about fetching a photograph the
        // cache does not hold, and a photograph the cache does not hold is not
        // in the deck's pool — so there is no card to peek at. The row is what
        // the refresher would have drawn.
        let card = try #require(try fixture.firstPhoto())
        #expect(try await fixture.cache.cache(photoID: card.id))

        // The second request comes off the queue, finds the bytes already here,
        // and stops. **This is the whole of the dedup** — the check is at the
        // fetch, not at the asking.
        #expect(try await fixture.cache.cache(photoID: card.id) == false)
        #expect(fixture.resident == 1)
    }

    @Test("A fetch that fails from an online source removes the photograph")
    func aFailedFetchFromAnOnlineSourceRemovesIt() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        // **Not via the queue.** These are about fetching a photograph the
        // cache does not hold, and a photograph the cache does not hold is not
        // in the deck's pool — so there is no card to peek at. The row is what
        // the refresher would have drawn.
        let card = try #require(try fixture.firstPhoto())

        // The source is right there and the file is not, so it is gone.
        fixture.folder.remove("a.png")
        #expect(try await fixture.cache.cache(photoID: card.id) == false)
        #expect(fixture.pooled == 0)
    }

    @Test("A fetch that fails from an offline source keeps everything")
    func aFailedFetchFromAnOfflineSourceKeepsIt() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        // **Not via the queue.** These are about fetching a photograph the
        // cache does not hold, and a photograph the cache does not hold is not
        // in the deck's pool — so there is no card to peek at. The row is what
        // the refresher would have drawn.
        let card = try #require(try fixture.firstPhoto())
        try fixture.goOffline()

        #expect(try await fixture.cache.cache(photoID: card.id) == false)
        // Unreachable says nothing about the photograph: it keeps its row and
        // its deal history, and comes round again when the drive is back.
        #expect(fixture.pooled == 1)
    }

    @Test("A fetch that cannot land in the cache keeps the photograph")
    func aFailedAdoptKeepsThePhotograph() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        // **Not via the queue.** These are about fetching a photograph the
        // cache does not hold, and a photograph the cache does not hold is not
        // in the deck's pool — so there is no card to peek at. The row is what
        // the refresher would have drawn.
        let card = try #require(try fixture.firstPhoto())

        // The cache root refuses writes — a condition entirely on our side that
        // says nothing about the photograph. The staging directory pre-exists
        // and stays writable, so the download itself succeeds and it is the
        // adoption into the store that fails. Only a provider-confirmed
        // absence may delete; a local failure logs, keeps the row, and the
        // fetch retries when the card comes round again.
        let root = fixture.cache.root
        try FileManager.default.createDirectory(
            at: root.appending(path: ".staging"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: root.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: root.path(percentEncoded: false))
        }

        #expect(try await fixture.cache.cache(photoID: card.id) == false)
        #expect(fixture.pooled == 1, "a failure on our side deleted the photograph")
    }

    @Test("A fetch that fails while the file is confirmed present keeps the photograph")
    func aFailedFetchOfAPresentFileKeepsIt() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        // **Not via the queue.** These are about fetching a photograph the
        // cache does not hold, and a photograph the cache does not hold is not
        // in the deck's pool — so there is no card to peek at. The row is what
        // the refresher would have drawn.
        let card = try #require(try fixture.firstPhoto())

        // Unreadable is not absent: the provider can see the file and cannot
        // read it. Removal is earned only by a confirmed absence, so the row
        // stays and the fetch retries when the card comes round — the retry
        // churn is accepted over the deletion (settled 2026-08-24).
        let file = fixture.folder.url.appending(path: "a.png")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: file.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: file.path(percentEncoded: false))
        }

        #expect(try await fixture.cache.cache(photoID: card.id) == false)
        #expect(fixture.pooled == 1, "an unreadable-but-present file was deleted")
    }

    // MARK: - Fetching, and what a failure means about the photograph

    @Test("A fetch that fails does not put the card back")
    func aFailedFetchDoesNotReturnTheCard() async throws {
        // **Nothing serving does asks for a fetch any more**, so the fetch is
        // started the way the refresher starts one: from the row.
        let fixture = try await Fixture(photos: ["a.png"])
        let wanted = try #require(try fixture.firstPhoto()).id

        // The source is gone by the time the fetch runs.
        try fixture.goOffline()
        _ = try await fixture.cache.cache(photoID: wanted)

        // Nothing was gained, so nothing goes on the deck — a photograph that
        // cannot be fetched must not circulate as a card that cannot be shown.
        #expect(fixture.queued == 0)
    }

    // MARK: - The states a source can be in, seen through the walk

    @Test("An offline source serves what we hold and skips what we do not")
    func offlineServesWhatIsHeld() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        // Exactly one of the two fetched, so the deck's pool is that one and
        // the other is still a remote asset as far as dealing is concerned.
        #expect(await fixture.cache.refreshOnce() == .fetched)
        try fixture.dealAll()
        let held = try #require(try fixture.cache.queue.peek().first)

        // The drive goes away *after* one of them was fetched. This is the case
        // that used to fail: the copy we hold could not be reached, because
        // producing had already written the source off.
        try fixture.goOffline()

        let served = try #require(try await fixture.cache.serve())
        #expect(served.card.id == held.id)
        #expect(fixture.pooled == 2, "an undock deletes nothing")
    }

    @Test("A photograph deleted from a source that is right there is dropped, not skipped")
    func deletedPhotographsAreDropped() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try await fixture.cacheAll()
        try fixture.dealAll()
        #expect(fixture.resident == 2)

        fixture.folder.remove("a.png")

        // Whatever order they come up in, the deleted one never goes out and
        // does not survive the walk.
        var served: [String] = []
        while let next = try await fixture.cache.serve() { served.append(next.card.externalID) }
        #expect(served == ["b.png"])
        #expect(fixture.pooled == 1)
        #expect(fixture.resident == 1, "its cached copy went with it")
        #expect(fixture.heard.lines.contains { $0.hasPrefix("SERVE: a.png (source ") && $0.contains(" dropped") })
    }

    @Test("A source that is gone takes its photographs with it as they come up")
    func goneSourcesAreDropped() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        try await fixture.cacheAll()
        try fixture.dealAll()

        // The folder is deleted while its volume stays — which is *gone*, not
        // offline, and the opposite answer.
        try FileManager.default.removeItem(at: fixture.folder.url)

        #expect(try await fixture.cache.serve() == nil)
        #expect(fixture.pooled == 0)
        #expect(fixture.resident == 0)
    }

    // MARK: - What it says while doing it

    @Test("Keeping a resize says what was resized and to what size, and nothing else")
    func keepingAResizeIsSaid() async throws {
        // **This used to be two tests**, one for a referenced photograph and one
        // for a materialized one, because the line named where the pixels were
        // decoded from — "from its file on disk" against "from the cached
        // original". That fact is real but it is a different fact from a
        // rendering being kept, and carrying both in one sentence made neither
        // easy to find on a console. One line, one event.
        let fixture = try await Fixture(photos: ["a.png"])
        try await fixture.cacheAll()
        try fixture.dealAll()
        let served = try #require(try await fixture.cache.serve())

        _ = try fixture.cache.keep(
            Data(count: 1234), of: served.card,
            at: PhotoStore.Size(width: 800, height: 600), pathExtension: "jpeg")

        #expect(
            fixture.heard.lines.contains {
                $0.hasPrefix("CACHE: resized a.png (source \(fixture.source.id)) to 800x600,")
            })
    }

    @Test("Serving says whether the bytes are the original or a kept resize")
    func servingNamesWhichBytesWentOut() async throws {
        let fixture = try await Fixture(photos: ["a.png"], materialized: false)
        try fixture.dealAll()
        let served = try #require(try await fixture.cache.serve())
        let box = PhotoStore.Size(width: 800, height: 600)
        _ = try fixture.cache.keep(
            Data(count: 1234), of: served.card, at: box, pathExtension: "jpeg")

        // Dealt again and asked for at exactly the size just kept, which is the
        // only way the held resize is what goes out.
        try fixture.dealAll()
        _ = try #require(try await fixture.cache.serve(fitting: box))

        let lines = fixture.heard.lines
        #expect(lines.contains { $0.contains("is here as its original, showing it") })
        #expect(lines.contains { $0.contains("is here as a kept resize, showing it") })
    }
}

/// Wraps a real provider and counts what the walk asks of the source.
///
/// **The point of the count is cost, not behaviour.** Asking a source whether a
/// photograph is still there means a stat against wherever that source lives,
/// which on a network volume measures in whole seconds — so a walk that asks it
/// about cards it is going to skip anyway pays that price for nothing.
final class CountingProvider: SourceProvider, @unchecked Sendable {
    private let inner: any SourceProvider
    private let lock = NSLock()
    private var existenceChecks = 0

    init(wrapping inner: any SourceProvider) { self.inner = inner }

    var kind: SourceKind { inner.kind }

    var checks: Int {
        lock.lock()
        defer { lock.unlock() }
        return existenceChecks
    }

    /// Zeroes the count, so a test measures one walk rather than everything the
    /// fixture did to get there — a scan asks about every photograph it finds.
    func reset() {
        lock.lock()
        existenceChecks = 0
        lock.unlock()
    }

    func enumerate(
        _ source: Source, into sink: (DiscoveredPhoto) async throws -> Void
    ) async throws -> SourceReachability {
        try await inner.enumerate(source, into: sink)
    }

    func existence(of externalID: String, in source: Source) async -> PhotoExistence {
        // Counted in its own non-async call, so the lock is never held across
        // the suspension below.
        note()
        return await inner.existence(of: externalID, in: source)
    }

    private func note() {
        lock.lock()
        existenceChecks += 1
        lock.unlock()
    }

    func availability(of source: Source) async -> SourceAvailability {
        await inner.availability(of: source)
    }

    func materialize(
        externalID: String, from source: Source, to destination: URL
    ) async throws -> MaterializedFile {
        try await inner.materialize(externalID: externalID, from: source, to: destination)
    }
}
