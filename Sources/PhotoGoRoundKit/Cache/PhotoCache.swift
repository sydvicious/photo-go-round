import Foundation
import PhotoGoRoundAgentAPI

/// The bounded window of actual image files.
///
/// The single most important thing to keep straight is that there are two
/// populations and only one of them is bounded. Every photo in every source has
/// a row; the cache holds bytes for a bounded number of them. If the database
/// only held what was cached, the shuffle would be a shuffle of a thousand
/// photos and the other forty-nine thousand would surface only through whatever
/// refill policy pulled them in.
///
/// So the cache is purely a performance layer — a prediction about which photos
/// are needed soon, wrong at worst, never a constraint on what can appear.
public struct PhotoCache {
    public let database: Database
    /// Where materialized bytes live. Supplied by the host; the kit never
    /// constructs a path from a hardcoded root.
    public let root: URL
    public let settings: CacheSettings

    /// Pictures that are ready to show. The cache fills it and serves from it.
    public let queue: PhotoQueue
    /// The bytes, and the only record of them. Nothing in the database describes
    /// what is cached.
    public let store: PhotoStore

    /// Where the two queues say what they did. Injected for the same reason the
    /// served-request log is: `os_log` lands in a store no test can read back
    /// while the assertion is still interesting, and a person standing the agent
    /// up needs the decisions on the console as they happen.
    public var log: @Sendable (QueueEvent) -> Void = { $0.report() }

    /// Hands the cache back a credit for a photograph it paid for and no
    /// longer has. Wired by the host to `CacheRefresher.bank`; nil rings
    /// nothing, so a cache built in a test need not have a refresher.
    ///
    /// **Banked, never a round.** Only launch and a card being drawn start
    /// fetching — see `CacheRefresher.bank`.
    public var creditReturned: @Sendable () -> Void = {}

    /// Which library's bells this cache rings. Nil rings nothing, so a cache
    /// built in a test cannot tell every agent on the Mac that its deck moved.
    public var doorbells: DarwinNotification.Doorbells?

    private let sources: SourceStore
    private let deck: Deck

    public init(
        database: Database,
        root: URL,
        settings: CacheSettings = .default,
        sources: SourceStore,
        deck: Deck? = nil,
        queueSize: Int = 1000,
        store: PhotoStore? = nil
    ) {
        self.database = database
        self.root = root
        self.settings = settings
        self.sources = sources
        self.deck = deck ?? Deck(database: database)
        self.queue = PhotoQueue(database: database, nominalSize: queueSize)
        self.store = store ?? PhotoStore(root: root, byteCeiling: settings.byteCeiling)
    }

    /// Creates the cache directory and keeps it out of Time Machine.
    ///
    /// Letting a backup copy tens of gigabytes of photos that are already in the
    /// Photos library or already in iCloud wastes the user's backup volume on
    /// data we can reconstruct.
    /// Returns what the launch walk reclaimed, so the host can say so where a
    /// person is actually reading. **The unified log is not that place** — the
    /// sweep took 15 files and 33 directories on 2026-08-26 and said nothing
    /// the agent's own console showed.
    @discardableResult
    public func prepare() throws -> (kept: Int, discarded: Int, bytes: Int64, emptied: Int) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
        // A crash mid-download leaves its temporary in `.staging`, and the
        // index walk never looks inside — the name is neither `.original` nor
        // a size — so launch is the only place it can be reclaimed.
        try? FileManager.default.removeItem(at: root.appending(path: Self.stagingDirectory))
        return try indexCache()
    }

    /// Where a fetch writes before adopting into the store. Beside the source
    /// directories but never indexed: a name that is neither `.original` nor a
    /// size is skipped by the rebuild walk.
    static let stagingDirectory = ".staging"

    /// Rebuilds the byte index from the disk, discarding anything the database
    /// does not claim.
    ///
    /// This is the whole of what used to be `verifyResidency` and
    /// `sweepOrphans`: an index built *from* the filesystem cannot disagree with
    /// it, and a file whose UUID is unknown has no owner left that could name it
    /// correctly.
    @discardableResult
    public func indexCache() throws -> (kept: Int, discarded: Int, bytes: Int64, emptied: Int) {
        var owners: [String: String] = [:]
        try database.query(
            """
            SELECT p.uuid AS photo_uuid, s.uuid AS source_uuid
              FROM photo p JOIN source s ON s.id = p.source_id;
            """
        ) { row in
            owners[try row.string("photo_uuid")] = try row.string("source_uuid")
        }
        // **The queue is not reconciled against the disk, deliberately.** It
        // used to be: a card only reached the queue once its bytes were local,
        // so one without bytes after a restart was a card that could never be
        // served. That is no longer true — a card is dealt *before* anything is
        // fetched, and finding it uncached at the head is the event that asks
        // for its bytes. Dropping those cards at launch removed every
        // materialized one and left the referenced cards that never needed
        // bytes, so a source reached only through the cache queue was emptied
        // out of the deck at every launch and never got a turn.
        let result = store.rebuild(photos: owners)
        // **The disk wins.** The walk above is the truth about what is held;
        // `cached_at` is a projection of it, and this is where a projection
        // that drifted — a file deleted by hand, a database restored from a
        // backup, an upgrade that arrived with the column empty — is put back.
        try reconcileResidency(with: store.residentPhotoUUIDs)
        return result
    }

    // MARK: - Residency

    /// Brings `photo.cached_at` into line with the photographs whose originals
    /// are actually held.
    ///
    /// A temp table rather than a bound list: the resident set is as large as
    /// the cache — hundreds to thousands of entries — and per connection, so
    /// two processes reconciling at once cannot see each other's.
    func reconcileResidency(with resident: Set<String>, now: Date = Date()) throws {
        // **Filled outside any transaction, deliberately.** A `TEMP` table
        // lives in the connection's own temp database, so these inserts never
        // touch the main file and never take its single writer — which they
        // would have done for the length of the loop had this been wrapped in
        // `BEGIN IMMEDIATE` along with the two updates below. The set is as
        // large as the cache, so that is thousands of statements holding the
        // writer to populate something no other connection can even see.
        try database.run(
            "CREATE TEMP TABLE IF NOT EXISTS resident_now (uuid TEXT PRIMARY KEY);")
        try database.run("DELETE FROM resident_now;")
        for uuid in resident {
            try database.run(
                "INSERT OR IGNORE INTO resident_now (uuid) VALUES (:uuid);",
                ["uuid": .text(uuid)])
        }
        defer { try? database.run("DELETE FROM resident_now;") }

        // The writer is taken here and for exactly this: two statements, both
        // against an index, and together they are the whole reconciliation.
        try database.transaction(.immediate) {
            // Held and unrecorded. The timestamp is now rather than the file's
            // date: this column orders eviction, and what it wants to know is
            // how long ago we last had a reason to keep the photograph, which
            // for a photograph nobody has shown is when we noticed we had it.
            try database.run(
                """
                UPDATE photo SET cached_at = :now
                 WHERE cached_at IS NULL
                   AND uuid IN (SELECT uuid FROM resident_now);
                """,
                ["now": SQLValue(now)])
            // Recorded and not held.
            try database.run(
                """
                UPDATE photo SET cached_at = NULL
                 WHERE cached_at IS NOT NULL
                   AND uuid NOT IN (SELECT uuid FROM resident_now);
                """)
        }
    }

    /// Marks photographs as no longer held, by UUID.
    func releaseResidency(ofPhotos uuids: Set<String>) throws {
        guard !uuids.isEmpty else { return }
        try database.transaction(.immediate) {
            for uuid in uuids {
                try database.run(
                    "UPDATE photo SET cached_at = NULL WHERE uuid = :uuid;",
                    ["uuid": .text(uuid)])
            }
        }
    }

    // MARK: - Where bytes are

    /// A readable URL for a photo's bytes, or nil when they are not resident.
    ///
    /// Referenced photos resolve through `FileAccess` against their source;
    /// materialized ones resolve against the cache root. A consumer asks this
    /// and does not care which it got.
    public func residentURL(forPhoto photoID: Int64) throws -> URL? {
        let row = try database.first(
            """
            SELECT p.storage, p.uuid, p.external_id, p.source_id
              FROM photo p WHERE p.id = :id;
            """,
            ["id": .int(photoID)]
        ) { row in
            (
                storage: PhotoStorage(rawValue: try row.string("storage")) ?? .materialized,
                uuid: try row.string("uuid"),
                externalID: try row.string("external_id"),
                sourceID: try row.int64("source_id")
            )
        }
        guard let row else { return nil }

        switch row.storage {
        case .materialized:
            return store.url(for: PhotoStore.Key(photoUUID: row.uuid))
        case .referenced:
            guard let source = try sources.source(id: row.sourceID) else { return nil }
            // Through the seam, never from the stored path — so this keeps
            // working unchanged if the Mac is ever forced to sandbox.
            return try sources.fileAccess.withPhotoURL(in: source, externalID: row.externalID) { url in
                FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
            }
        }
    }

    // MARK: - Status

    public struct Status: Sendable, Equatable {
        /// Materialized photos whose original is held.
        public let residentCount: Int
        /// Photos referenced in place. Not copied, not budgeted, free.
        public let referencedCount: Int
        /// Materialized photos still waiting for their bytes.
        public let pendingCount: Int
        /// Renderings held, across every size and photograph.
        public let renderingCount: Int
        public let bytesOnDisk: Int64
        public let byteCeiling: Int64
        public let freeBytesOnVolume: Int64
        /// Pictures waiting in the queue, ready to show.
        public let queued: Int
    }

    public func status() throws -> Status {
        let materialized =
            try database.scalarInt(
                "SELECT COUNT(*) FROM photo WHERE storage = 'materialized';") ?? 0
        let referenced =
            try database.scalarInt(
                "SELECT COUNT(*) FROM photo WHERE storage = 'referenced';") ?? 0
        let totals = store.totals

        return Status(
            residentCount: totals.originals,
            referencedCount: referenced,
            pendingCount: max(0, materialized - totals.originals),
            renderingCount: totals.renderings,
            bytesOnDisk: totals.byteCount,
            byteCeiling: settings.byteCeiling,
            freeBytesOnVolume: freeBytesOnVolume(),
            queued: try queue.size()
        )
    }

    func freeBytesOnVolume() -> Int64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    // MARK: - Dealing one card

    /// Deals the next card onto the queue. **It fetches nothing.**
    ///
    /// The queue holds cards, not bytes: it is a shuffled order over every
    /// photograph we know about, whatever state its source is in, and it costs
    /// nothing to fill. Whether a card can actually be shown is found out by
    /// trying to show it — see `serve`.
    ///
    /// This used to be the expensive operation, and the inversion is the point.
    /// Producing *was* fetching, so nothing reached the queue until its bytes
    /// were local — which meant deciding in advance which photographs were
    /// fetchable, which meant keeping track of which sources were mounted and
    /// which photographs were cached. That bookkeeping is what this removes.
    ///
    /// Returns false when there was nothing left to deal, which is ordinary: an
    /// empty library, or everything already queued.
    @discardableResult
    public func deal(settings: DeckSettings = .default, now: Date = Date()) throws -> Bool {
        guard let candidate = try deck.nextCandidate(settings: settings, now: now) else {
            return false
        }
        // No claim to release: dealing takes none. Two fillers are kept apart
        // by the queue, which refuses a photograph it already holds.

        // The byte store is keyed by source, so it has to be told which source a
        // photograph belongs to before anything is written for it — including a
        // rendering of a referenced photograph, which is the only thing we ever
        // hold for one.
        store.note(photoUUID: candidate.uuid, sourceUUID: candidate.sourceUUID)
        guard try queue.append(photoID: candidate.id, sourceID: candidate.sourceID, at: now) else {
            return false
        }
        log(.dealt(photo: candidate.externalID, source: candidate.sourceID, queued: (try? queue.size()) ?? 0))
        return true
    }

    /// What the byte store is holding originals for.
    ///
    /// The deck no longer asks: servability is `cached_at` now, and a `WHERE`
    /// clause answers it. This is left for reporting — `pgr_ctl status` and the
    /// panel — and for the tests that check the column against the disk.
    public var residentPhotoUUIDs: Set<String> { store.residentPhotoUUIDs }

    // MARK: - Caching one picture, off the serving path

    /// Fetches one photograph's bytes into the cache.
    ///
    /// **Called by whatever drains the queue of pictures to cache, never by
    /// serving.** A picture that is not cached costs a request a skip; the fetch
    /// happens behind it, and the photograph goes back on the queue when it
    /// lands.
    ///
    /// Answers false when there was nothing to do or nothing could be done: it
    /// is already held, its source is unreachable, its provider is missing, or
    /// the download failed.
    @discardableResult
    public func cache(photoID: Int64, now: Date = Date()) async throws -> Bool {
        // Free space is checked before fetching, so running out of disk degrades
        // into "the cache stops growing" rather than a full volume.
        let free = freeBytesOnVolume()
        guard free >= self.settings.minimumFreeBytes else {
            Log.cache.notice(
                "not caching: \(free, privacy: .public) bytes free, floor is \(self.settings.minimumFreeBytes, privacy: .public)"
            )
            return false
        }

        guard let card = try deck.card(photoID: photoID) else { return false }
        // Already there. This is how asking for the same picture more than once
        // costs a skip rather than a second fetch — the check is here, when the
        // request comes off the queue, rather than in whatever put it on.
        let originalKey = PhotoStore.Key(photoUUID: card.uuid)
        guard card.storage == .materialized else { return false }
        guard !store.contains(originalKey) else {
            log(.cacheUnnecessary(photo: card.externalID, source: card.sourceID))
            return false
        }

        guard let source = try sources.source(id: card.sourceID),
            source.enabled,
            let provider = sources.provider(for: source.kind)
        else { return false }

        let extension_ = (card.externalID as NSString).pathExtension
        let staging = root.appending(path: Self.stagingDirectory)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let temporary = staging.appending(
            path: extension_.isEmpty ? card.uuid : "\(card.uuid).\(extension_)")

        // Two catches, because the failures mean opposite things. The provider
        // failing is a question about the photograph, answered below by asking
        // its source. Anything after that — adopting into the store, the
        // bookkeeping write — is a failure on *our* side that says nothing
        // about the photograph, and must never delete it.
        let file: MaterializedFile
        do {
            file = try await provider.materialize(
                externalID: card.externalID, from: source, to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            log(.cacheFailed(photo: card.externalID, source: card.sourceID, because: "\(error)"))
            try await handleFailedDownload(card, source: source, provider: provider)
            return false
        }
        do {
            try store.adopt(
                fileAt: temporary, for: originalKey,
                sourceUUID: card.sourceUUID, pathExtension: extension_, now: now)
            // **Residency is recorded in the same statement as the size**, so
            // there is no window in which the bytes are adopted and the deck
            // cannot see them. `cached_at` is what puts this photograph in the
            // deck's pool; until it is written the photograph is still a remote
            // asset as far as every query is concerned.
            try database.run(
                "UPDATE photo SET byte_size = :size, cached_at = :now WHERE id = :id;",
                ["size": .int(file.byteSize), "now": SQLValue(now), "id": .int(card.id)]
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            // **The adopt is undone.** Whatever made this write fail — the
            // volume full, the file gone from under us — the database is in
            // trouble and will not get better on its own. What must not happen
            // meanwhile is bytes on disk that nothing records: the store would
            // report the photograph held, `cached_at` would say otherwise, and
            // the disagreement would stand until the next launch. Dropping the
            // entry leaves both saying *not held*, which is true, and the
            // photograph is simply drawn again.
            store.remove(originalKey)
            log(.cacheFailed(photo: card.externalID, source: card.sourceID, because: "\(error)"))
            Log.cache.error(
                "photo \(card.id, privacy: .public) was fetched and could not be kept: \(String(describing: error), privacy: .public)"
            )
            return false
        }

        // **It does not go back on the queue, and the argument that put it
        // there is answered rather than reversed.**
        //
        // Re-queuing was reinstated on 2026-08-24 after a night of running
        // without it, and the measurement was damning: two sources of 5,899
        // photographs went from 123 pictures shown in an hour to zero for five
        // hours straight, while a source needing no fetch took every turn. The
        // reason was that dealing drew uniformly from the whole library, so a
        // photograph whose bytes had just been paid for had a one-in-fourteen-
        // thousand chance of being the next card. The cache could never catch
        // up.
        //
        // The deck draws from what the cache holds now, so a landed photograph
        // is *already* in the pool the moment this returns. Putting it on the
        // deck as well would be the fetch-completion order deciding the queue's
        // composition, which is the drift the original argument feared.
        log(
            .cached(
                photo: card.externalID, source: card.sourceID,
                bytes: store.url(for: originalKey).flatMap {
                    (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                } ?? 0))
        return true
    }

    // MARK: - The cache refreshing itself

    /// One draw: pick a remote asset at random, and fetch it unless it is
    /// already held.
    ///
    /// This is `CacheRefresher`'s `attempt` closure, and the whole of what the
    /// refresher knows about the library. Everything it decides — whether to
    /// draw again, whether a credit was spent, whether the round is over — it
    /// decides from the answer.
    ///
    /// **It does not put the photograph on the deck.** The demand-driven path
    /// re-queues a completed fetch so the bytes it just paid for are shown
    /// soon; the refresher has no such debt. It makes a photograph *eligible*
    /// and the deck picks it up on its own terms, which is the whole point of
    /// the two halves not knowing about each other.
    /// How many remote assets the cache does not hold — the refresher's stop
    /// condition, forwarded so a caller holding a `PhotoCache` need not also
    /// hold a `Deck`.
    public func unheldRemoteCount() throws -> Int {
        try deck.unheldRemoteCount()
    }

    /// The bench, so a source that has stopped answering is left alone.
    /// Shared across every lane and every round; nil never benches anything.
    public var bench: SourceBench?

    /// What one draw turned up, and what the caller should do about it.
    ///
    /// **The fetch is handed back rather than performed**, because running it
    /// against a deadline means letting go of work that may never return —
    /// which needs a detached task, which needs `Sendable`, which a `PhotoCache`
    /// holding a `Database` is deliberately not. That is the kit's rule showing
    /// its edge in the right place: *which thread runs a fetch and how long it
    /// may take are scheduling*, and scheduling is the host's business.
    public enum Step: Sendable {
        /// The disk says stop, whatever the credits say.
        case blocked
        /// Nothing remote is left to draw.
        case exhausted
        /// Drawn and already held. Free, and the commonest answer as the cache
        /// fills — which is what makes the miss rate a throttle.
        case alreadyHeld
        /// Drawn from a source that is resting.
        case benched
        /// Fetch this one, and give it no longer than `within`.
        case fetch(DeckCard, within: Duration)
    }

    /// How long a photograph from this kind of source may take.
    ///
    /// **Per kind, because the providers differ by an order of magnitude**: a
    /// file on disk has no excuse, and a Photos original was measured stalling
    /// for a fixed 300 seconds before transferring normally.
    public static func deadline(for kind: SourceKind) -> Duration {
        kind.isFileBacked ? CacheSettings.fileFetchLimit : CacheSettings.libraryFetchLimit
    }

    /// Draws one remote asset and says what to do with it.
    public func nextToFetch(now: Date = Date()) -> Step {
        // Asked first, because no credit arithmetic may override it.
        let free = freeBytesOnVolume()
        guard free >= settings.minimumFreeBytes else {
            Log.cache.notice(
                "refresher stopping: \(free, privacy: .public) bytes free, floor is \(self.settings.minimumFreeBytes, privacy: .public)"
            )
            return .blocked
        }

        // `try?` flattens the double optional: a throw and an empty draw are
        // the same answer here, which is that there is nothing to fetch.
        guard let drawn = try? deck.nextRemoteCandidate(now: now) else { return .exhausted }

        // **Already held is the ordinary answer, not a failure.**
        if store.contains(PhotoStore.Key(photoUUID: drawn.uuid)) {
            try? deck.releaseClaim(photoID: drawn.id)
            return .alreadyHeld
        }

        // **A benched source is not asked at all.** It has already shown what
        // it has to give, and a lane spent on it is a lane the healthy sources
        // do not get.
        if bench?.isBenched(drawn.sourceID) == true {
            try? deck.releaseClaim(photoID: drawn.id)
            return .benched
        }

        // A photograph whose source row has gone is a race with removal, not
        // something to fetch. Treated as a free draw so the lane simply tries
        // again rather than spending the round's failure budget on it.
        guard let source = try? sources.source(id: drawn.sourceID) else {
            try? deck.releaseClaim(photoID: drawn.id)
            return .alreadyHeld
        }
        // The claim is deliberately *kept* here: the fetch happens next, in the
        // caller, and the claim is what stops another lane drawing the same
        // photograph while it runs. `finishFetch` releases it.
        return .fetch(drawn, within: Self.deadline(for: source.kind))
    }

    /// Fetches a photograph the caller drew. Answers whether the bytes landed.
    public func fetchDrawn(_ card: DeckCard, now: Date = Date()) async -> Bool {
        (try? await cache(photoID: card.id, now: now)) ?? false
    }

    /// Ends a draw: releases the claim, and tells the bench what happened.
    ///
    /// Called whatever the outcome, including for work that was abandoned —
    /// a claim left behind sidelines a photograph for the whole timeout.
    public func finishFetch(_ card: DeckCard, landed: Bool) {
        try? deck.releaseClaim(photoID: card.id)
        if landed {
            // Anything at all from a source clears its account. An occasional
            // timeout on a working source is weather.
            bench?.succeeded(card.sourceID)
        }
    }

    /// Draw and fetch in one call, **with no deadline**.
    ///
    /// The three-step form above exists because running a fetch against a
    /// deadline means letting go of work that may never return, which the host
    /// has to arrange. A caller that is content to wait — a test, or a
    /// one-shot tool — wants this instead. It is not what the agent uses, and
    /// it is not where the hostile-provider handling lives.
    @discardableResult
    public func refreshOnce(now: Date = Date()) async -> CacheRefresher.Draw {
        switch nextToFetch(now: now) {
        case .blocked: return .blocked
        case .exhausted: return .exhausted
        case .alreadyHeld: return .alreadyHeld
        case .benched: return .benched
        case .fetch(let card, _):
            let landed = await fetchDrawn(card, now: now)
            finishFetch(card, landed: landed)
            return landed ? .fetched : .failed
        }
    }

    /// A fetch that ran out of time. Answers the bench it earned, if any.
    @discardableResult
    public func fetchTimedOut(_ card: DeckCard, after limit: Duration) -> Duration? {
        let benched = bench?.failed(card.sourceID)
        log(
            .cacheTimedOut(photo: card.externalID, source: card.sourceID, after: limit))
        if let benched {
            log(.sourcePaused(source: card.sourceID, until: benched))
        }
        return benched
    }

    /// A fetch the provider failed, and what it means about the photograph.
    ///
    /// **Only a confirmed absence deletes.** The provider is asked the same
    /// three-valued question that guards serving, and the third value is the
    /// point: a failed read proves nothing on its own. `absent` is the
    /// established rule — gone from a source that is right there — and the row
    /// and bytes go. `present` is a file that exists and could not be fetched;
    /// it keeps its row and is retried when its card comes round, and the
    /// retry churn of a permanently unreadable file is accepted over deleting
    /// a photograph that is demonstrably still there (settled 2026-08-24).
    /// `unknown` says nothing, so nothing moves.
    private func handleFailedDownload(
        _ card: DeckCard, source: Source, provider: any SourceProvider
    ) async throws {
        switch await provider.existence(of: card.externalID, in: source) {
        case .absent:
            Log.cache.notice(
                "photo \(card.id, privacy: .public) failed to fetch and its source confirms it absent; removing it from the pool"
            )
            try self.remove(card.id)
        case .present:
            Log.cache.info(
                "photo \(card.id, privacy: .public) is present and could not be fetched; keeping it"
            )
        case .unknown:
            Log.cache.info(
                "photo \(card.id, privacy: .public) could not be confirmed either way; keeping it"
            )
        }
    }

    /// The rendering held for this photograph at this size, if any.
    public func rendering(of card: DeckCard, at size: PhotoStore.Size) -> URL? {
        store.url(for: PhotoStore.Key(photoUUID: card.uuid, size: size))
    }

    /// Keeps a rendering, so the next request for the same photograph at the
    /// same size is a file read rather than a decode.
    @discardableResult
    public func keep(
        _ bytes: Data, of card: DeckCard, at size: PhotoStore.Size, pathExtension: String
    ) throws -> URL {
        let url = try store.store(
            bytes, for: PhotoStore.Key(photoUUID: card.uuid, size: size),
            sourceUUID: card.sourceUUID, pathExtension: pathExtension)
        // Logged here rather than at the caller, so a second thing that renders
        // cannot do it silently. **One line, one event**: where the pixels
        // were decoded from is a different fact from a rendering being kept,
        // and putting both in one sentence made neither easy to find.
        log(
            .rendered(
                photo: card.externalID, source: card.sourceID,
                at: "\(size.width)x\(size.height)", bytes: bytes.count))
        return url
    }

    // MARK: - Serving one picture

    /// One picture, ready to hand over.
    public struct ServedPhoto: Sendable {
        public let card: DeckCard
        /// The bytes to send: either the photograph's original, or a rendering
        /// of it we were already holding at exactly the size that was asked for.
        public let url: URL
        /// True when `url` is that rendering — already the right pixels, so
        /// there is nothing left to decode and nothing to keep.
        public let isRendering: Bool
    }

    /// Takes the next card and hands over its bytes.
    ///
    /// **This used to be a walk, and it is not one any more.** Cards were once
    /// dealt before their bytes existed, so serving had to step over the ones
    /// that were not ready, ask for them to be fetched, and bound itself
    /// against both a cycle of the queue and a two-second clock. The deck deals
    /// nothing it cannot show now, so the first card is the picture.
    ///
    /// What is left is a skip loop for the three things that can still go
    /// wrong between dealing a card and serving it, all of them rare: its
    /// source lost its provider, its bytes disappeared from under us, or the
    /// photograph was deleted where it lives. **It needs no bound.** Every turn
    /// removes a card and nothing adds one while a request is in flight —
    /// topping up follows a picture that reached somebody — so the loop is
    /// bounded by the queue draining.
    ///
    /// **Every picture is still checked against its source in the moment before
    /// it is returned**, including one we hold our own copy of. That is the
    /// guarantee: a photograph the user deleted is never shown again, not even
    /// in the minutes before a refresh would have noticed.
    ///
    /// `fitting` is the box the caller is about to draw into, and naming it is
    /// what lets an **evicted original with a surviving rendering** still be
    /// served. Nil asks for the original, which is what `curl` with no `w` and
    /// `h` wants.
    public func serve(
        to consumerID: Int64? = nil,
        fitting box: PhotoStore.Size? = nil,
        now: Date = Date()
    ) async throws -> ServedPhoto? {
        var skipped = 0

        while let card = try await queue.serve(at: now) {
            // Neither guard below is a photograph that has *gone*, so neither
            // deletes anything. A missing source row is only reachable as a
            // race — foreign keys are on — and a missing provider is a Photos
            // album in a build that cannot enumerate one, where deleting the
            // rows would destroy a library on a downgrade.
            guard let source = try sources.source(id: card.sourceID),
                let provider = sources.provider(for: source.kind)
            else {
                skipped += 1
                log(.skipped(photo: card.externalID, source: card.sourceID, because: "no provider for its source", queued: depth()))
                continue
            }

            // The rendering is looked at before the original because it is the
            // cheaper answer *and* because it may be the only one left: an
            // original can be evicted while a rendering of it survives, and
            // skipping the photograph then would be refusing to send bytes we
            // are holding in exactly the shape the client asked for.
            let held = box.flatMap {
                store.url(for: PhotoStore.Key(photoUUID: card.uuid, size: $0))
            }
            guard let url = try held ?? residentURL(forPhoto: card.id) else {
                // **The bytes went away, and this request is how we find out.**
                // Nothing scans for it. The card was dealt because the library
                // recorded the photograph as held, so the record is wrong: drop
                // it, hand the cache back the credit it spent, and move on. The
                // photograph rejoins the remote assets and is drawn again like
                // any other.
                skipped += 1
                vanished(card)
                continue
            }

            // **Is it still there? — asked last, and only about the one card
            // that is going out.** It is a promise about what is *displayed*,
            // so it belongs to the card being displayed and to no other.
            var unconfirmed: String?
            switch await provider.existence(of: card.externalID, in: source) {
            case .absent:
                skipped += 1
                log(.dropped(photo: card.externalID, source: card.sourceID, because: "gone from a source that is right there", queued: depth()))
                try self.remove(card.id)
                continue

            case .unknown(let reason):
                // **Offline and gone are opposite answers**: one keeps
                // everything and serves the copy we hold, the other means these
                // photographs are never coming back.
                if case .gone(let why) = await provider.availability(of: source) {
                    skipped += 1
                    log(.dropped(photo: card.externalID, source: card.sourceID, because: "its source is \(why)", queued: depth()))
                    try self.remove(card.id)
                    continue
                }
                unconfirmed = reason

            case .present:
                break
            }

            log(
                .serving(
                    photo: card.externalID, source: card.sourceID,
                    rendering: held != nil, unconfirmed: unconfirmed, queued: depth()))
            let seq = try await deck.markShown(photoID: card.id, now: now)
            if let consumerID { try? deck.touch(consumerID: consumerID, at: now) }
            // The deck moved, so anything mirroring its position — a diagnostic
            // panel, another surface's idea of what is next — should go and look.
            doorbells?.post(.deckAdvanced)
            return ServedPhoto(
                card: DeckCard(
                    id: card.id, uuid: card.uuid, sourceID: card.sourceID,
                    sourceUUID: card.sourceUUID, externalID: card.externalID,
                    storage: card.storage, dealSeq: seq
                ),
                url: url,
                isRendering: held != nil
            )
        }

        log(.nothingToShow(walked: skipped, because: "out of cards"))
        return nil
    }

    /// A card whose bytes are not where the library says they are.
    ///
    /// Two things have to happen and neither is a fetch. The record has to stop
    /// claiming the photograph is held, or the deck would deal it again and
    /// again. And the cache has to get its credit back, because it paid for a
    /// photograph it no longer has — see the plan's credit rule, where this is
    /// one of the two involuntary losses.
    private func vanished(_ card: DeckCard) {
        if card.storage == .materialized {
            try? releaseResidency(ofPhotos: [card.uuid])
            creditReturned()
        }
        log(
            .skipped(
                photo: card.externalID, source: card.sourceID,
                because: "its bytes are gone", queued: depth()))
    }

    /// How many cards are queued right now.
    private func depth() -> Int { (try? queue.size()) ?? 0 }

    // MARK: - Keeping the bytes honest

    /// Removes entries from the pool *and* their cached bytes, together.
    ///
    /// This is what "the file is gone" means: the entry goes, its queue place
    /// goes with it by cascade, and the copy we were holding is deleted rather
    /// than left for the next sweep. A photo missing from a source that is
    /// *there* no longer exists, so there is nothing left worth keeping.
    ///
    /// Contrast a source that is merely offline, where the cached bytes are the
    /// most valuable thing we have and keep being served.
    @discardableResult
    public func remove(_ photoIDs: [Int64]) throws -> PhotoPool.Removal {
        let removal = try sources.pool.remove(photoIDs)
        for uuid in removal.orphaned { store.remove(photoUUID: uuid) }
        return removal
    }

    @discardableResult
    public func remove(_ photoID: Int64) throws -> PhotoPool.Removal {
        try remove([photoID])
    }

    // MARK: - Eviction

    public struct EvictionResult: Sendable, Equatable {
        public let evicted: Int
        public let bytesFreed: Int64
    }

    /// Photographs oldest-first by when anybody last had a reason to keep them.
    ///
    /// **Every photograph, not only the ones with bytes fetched for them.** The
    /// first version of this asked for `WHERE cached_at IS NOT NULL`, which
    /// reads as "the ones the cache holds" and is wrong on the ordinary
    /// library: a photograph on the boot volume is *referenced*, read in place,
    /// never copied — so it has no `cached_at` and never will. What the cache
    /// holds for it is a **rendering**, which is the only thing it ever holds
    /// for one, and those renderings were absent from this list. An entry the
    /// order does not rank sorts ahead of everything, so on a library of local
    /// folders the cache evicted every rendering the moment it was over its
    /// ceiling, and the resize cache did nothing but cost decodes.
    ///
    /// **The coalesce is the rest of the rule**, and it now has three terms
    /// because there are three ways to have had a reason to keep a photograph.
    /// It was last shown; or it landed in the cache; or it is merely known
    /// about, which is where a referenced photograph nobody has displayed sits.
    /// Reading a missing value as *viewed infinitely long ago* would invert the
    /// policy in each case.
    func evictionOrder() throws -> [String] {
        try database.all(
            """
            SELECT uuid FROM photo
             ORDER BY COALESCE(last_shown_at, cached_at, added_at), id;
            """
        ) { try $0.string("uuid") }
    }

    /// FIFO by creation time, bounded by bytes, over `(photo, resolution)`
    /// entries rather than over photographs.
    ///
    /// **The original justification for plain FIFO no longer holds, and the
    /// policy is kept for a weaker reason.** It used to be that entries were
    /// written in deck order — bytes entered the cache in the order they would
    /// be shown, so oldest-written was also longest-since-dealt, and the cache
    /// was a sliding window over the deck. Neither half is true now: bytes
    /// arrive from the queue of pictures to cache in the order fetches
    /// *complete*, and cards are placed at random positions rather than at the
    /// back, so nothing connects write order to display order.
    ///
    /// What is left is that it does not matter much. A shuffle shows every
    /// photograph about equally often, so there is no hot set for an LRU to
    /// protect — and `createdAt` is never updated on a hit, so this is FIFO by
    /// *write* time rather than by use either way. Anything queued is skipped
    /// regardless of age, which covers the only entries with a known imminent
    /// reader.
    ///
    /// **Where it would start to matter** is a library whose working set exceeds
    /// the ceiling, so photographs are evicted before their turn comes round.
    /// That needs a library several times the size of any tested here, and it is
    /// the point at which this wants measuring rather than reasoning about.
    @discardableResult
    public func evictIfNeeded() throws -> EvictionResult {
        // The disk-space guard evicts ahead of the ceiling, folded in as a lower
        // effective ceiling rather than as a second pass.
        let free = freeBytesOnVolume()
        if free < settings.criticalFreeBytes {
            Log.cache.notice(
                "evicting ahead of the ceiling: only \(free, privacy: .public) bytes free"
            )
            store.byteCeiling = max(0, settings.byteCeiling / 2)
        } else {
            store.byteCeiling = settings.byteCeiling
        }

        let result = store.evictIfNeeded(inOrder: try evictionOrder())
        // An evicted original is no longer servable, so it leaves the deck's
        // pool in the same breath as it leaves the disk.
        try releaseResidency(ofPhotos: result.releasedOriginals)
        return EvictionResult(evicted: result.evicted, bytesFreed: result.bytesFreed)
    }

    // MARK: - Clearing on purpose

    public enum ClearScope: Sendable, Equatable {
        case everything
        case source(Int64)
        /// Photos belonging to sources that are gone. These can never be
        /// re-fetched anyway, which makes this the variant to reach for first:
        /// it frees space at zero future cost.
        case unavailableSources
    }

    /// What an explicit clear would cost, so the operation can state its price
    /// before charging it.
    ///
    /// Ordinary eviction is incremental, continuous, and invisible. An explicit
    /// clear is the other thing entirely: everything has to be fetched again,
    /// which for an iCloud-optimized library can be tens of gigabytes over a
    /// connection that may be metered.
    public struct ClearCost: Sendable, Equatable {
        /// Materialized photos whose bytes would be discarded and would have to
        /// be fetched again.
        public let needingRefetch: Int
        public let bytesFreed: Int64
        /// Referenced photos in scope — free to "re-retrieve", since that means
        /// opening a file.
        public let referencedAndFree: Int
        /// True when nothing in scope could ever be fetched again, so there is
        /// no future cost to warn about.
        public let costsNothingToRefetch: Bool
    }

    public func costOfClearing(_ scope: ClearScope) throws -> ClearCost {
        let (predicate, bindings) = Self.scopePredicate(scope)
        let rows = try database.all(
            """
            SELECT p.uuid, p.storage FROM photo p JOIN source s ON s.id = p.source_id
             WHERE \(predicate);
            """,
            bindings
        ) { (uuid: try $0.string("uuid"), storage: try $0.string("storage")) }

        var refetch = 0
        var bytes: Int64 = 0
        var referenced = 0
        for row in rows {
            if row.storage == "referenced" { referenced += 1 }
            let held = store.sizes(forPhoto: row.uuid).count
                + (store.contains(PhotoStore.Key(photoUUID: row.uuid)) ? 1 : 0)
            guard held > 0 else { continue }
            if row.storage == "materialized" { refetch += 1 }
        }
        // The byte total comes from the index, since the database no longer
        // records what is held.
        let claimed = Set(rows.map(\.uuid))
        bytes = store.byteCount(ofPhotos: claimed)

        return ClearCost(
            needingRefetch: refetch,
            bytesFreed: bytes,
            referencedAndFree: referenced,
            costsNothingToRefetch: scope == .unavailableSources
        )
    }

    public struct ClearResult: Sendable, Equatable {
        public let cleared: Int
        public let bytesFreed: Int64
        /// Queue entries dropped because their bytes no longer exist.
        public let queueCleared: Int
    }

    /// Discards bytes. Never shuffle state.
    ///
    /// Deal ordinals, shuffle keys, and last-shown times are untouched, so a
    /// cleared cache refills into the same rotation rather than reshuffling the
    /// library. Clearing is a storage operation, never a shuffle operation.
    @discardableResult
    public func clear(_ scope: ClearScope) throws -> ClearResult {
        let (predicate, bindings) = Self.scopePredicate(scope)
        let uuids = try database.all(
            """
            SELECT p.uuid FROM photo p JOIN source s ON s.id = p.source_id
             WHERE \(predicate);
            """,
            bindings
        ) { try $0.string("uuid") }

        var freed: Int64 = 0
        var cleared = 0

        switch scope {
        case .everything:
            freed = store.removeAll()
            cleared = uuids.count
        case .source(let sourceID):
            // One directory removal rather than thousands of unlinks, which is
            // the whole reason the layout has that level.
            if let uuid = try sources.source(id: sourceID)?.uuid {
                freed = store.removeSource(uuid)
            }
            cleared = uuids.count
        case .unavailableSources:
            for uuid in uuids {
                let before = store.byteCount(ofPhotos: [uuid])
                if before > 0 { cleared += 1 }
                freed += store.remove(photoUUID: uuid)
            }
        }

        // The bytes are gone, so nothing in scope is servable any more. One
        // scoped UPDATE rather than a loop, because `.everything` names the
        // whole library.
        try database.run(
            """
            UPDATE photo SET cached_at = NULL
             WHERE cached_at IS NOT NULL
               AND id IN (SELECT p.id FROM photo p JOIN source s ON s.id = p.source_id
                           WHERE \(predicate));
            """,
            bindings)

        // Queued pictures point at bytes that no longer exist, so the queue is
        // emptied too. Refilling is then the cold-start path, which already
        // exists: providers are asked, and pictures arrive as they answer.
        var queueCleared = 0
        if scope == .everything {
            try database.transaction(.immediate) {
                try database.run("DELETE FROM queue;")
                queueCleared = database.changes
            }
        }

        Log.cache.notice(
            "cleared \(cleared, privacy: .public) photographs, freeing \(freed, privacy: .public) bytes"
        )
        return ClearResult(cleared: cleared, bytesFreed: freed, queueCleared: queueCleared)
    }

    private static func scopePredicate(_ scope: ClearScope) -> (String, SQLBindings) {
        switch scope {
        case .everything:
            ("1 = 1", [:])
        case .source(let id):
            ("p.source_id = :source", ["source": .int(id)])
        case .unavailableSources:
            ("s.available = 0", [:])
        }
    }

    // MARK: - SQL

}
