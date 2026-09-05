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

    // MARK: - Caching one picture, off the serving path

    /// Fetches one photograph's bytes into the cache.
    ///
    /// **Called by the queue's fetcher, never by serving.** The card is already
    /// on the queue and keeps its place; this lands its bytes behind it.
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
            // **Residency is recorded in the same statement as the size.**
            // `cached_at` is the projection of what the store holds; the
            // eviction order reads it, the status lines count it, and the
            // queue's fetcher uses it to find cards that still need bytes.
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

        // **Nothing about the queue changes here.** The card whose bytes these
        // are is already on the queue — that is why they were fetched — and it
        // keeps its place. The v1 starvation, where a fetched card had left the
        // queue and had a one-in-the-library chance of coming back, cannot
        // recur: the card never left.
        log(
            .cached(
                photo: card.externalID, source: card.sourceID,
                bytes: store.url(for: originalKey).flatMap {
                    (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                } ?? 0))
        return true
    }

    // MARK: - The queue fetching its own cards

    /// The bench, so a source that has stopped answering is left alone.
    /// Shared across every lane and every round; nil never benches anything.
    public var bench: SourceBench?

    /// How long a fetch of this kind may take before its lane is taken back.
    ///
    /// One number for every kind since 2026-09-05; the function stays so the
    /// place to differentiate is still named. A file on the boot volume has no
    /// excuse for taking a minute, and a Photos original stalling for longer
    /// was measured on a day everything touching iCloud on the machine was
    /// wedged — see `CacheSettings.libraryFetchLimit`.
    public static func deadline(for kind: SourceKind) -> Duration {
        kind.isFileBacked ? CacheSettings.fileFetchLimit : CacheSettings.libraryFetchLimit
    }

    /// The next queued card whose bytes are not here, past `rank` in the
    /// queue's order, **claimed for the caller**.
    ///
    /// This is `QueueFetcher`'s `next` closure, and the whole of what the
    /// fetcher knows about the library. It walks the queue head first; `nil`
    /// starts at the head, and a lane passes back the rank it was given to ask
    /// for the one after it.
    ///
    /// **The fetch is handed back rather than performed**, because running it
    /// against a deadline means letting go of work that may never return —
    /// which needs a detached task, which needs `Sendable`, which a `PhotoCache`
    /// holding a `Database` is deliberately not. Which thread runs a fetch and
    /// how long it may take are scheduling, and scheduling is the host's.
    public func nextQueuedToFetch(after rank: Int64? = nil, now: Date = Date())
        -> QueueFetcher.Next
    {
        // Asked first: the disk is the bound nothing else may override.
        let free = freeBytesOnVolume()
        guard free >= settings.minimumFreeBytes else {
            Log.cache.notice(
                "fetching stopped: \(free, privacy: .public) bytes free, floor is \(self.settings.minimumFreeBytes, privacy: .public)"
            )
            return .blocked
        }

        let expiry = now.addingTimeInterval(-Deck.claimTimeout)
        var after = rank ?? -1
        while true {
            guard let found = try? queue.nextUnheld(after: after, claimedBefore: expiry)
            else { return .drained }
            after = found.rank
            let card = found.card

            // The column said not held and the store says otherwise: the store
            // is the truth, and there is nothing to fetch. Walk on.
            if store.contains(PhotoStore.Key(photoUUID: card.uuid)) { continue }

            // **A benched source is not asked at all.** Its card stays where it
            // is and is looked at again on the next kick; the lane moves past
            // it so the healthy sources behind it are fetched.
            if bench?.isBenched(card.sourceID) == true { return .benched(rank: found.rank) }

            // A source row gone from under its card is a race with removal —
            // the cascade will take the card too. Walk on.
            guard let source = try? sources.source(id: card.sourceID) else { continue }

            // Another lane got here first. Its claim is what keeps this one
            // from downloading the same bytes; walk on.
            guard (try? deck.claim(photoID: card.id, now: now)) == true else { continue }

            return .card(card, rank: found.rank, within: Self.deadline(for: source.kind))
        }
    }

    /// Fetches a queued card's bytes. Answers whether they are here now —
    /// including the case where another path landed them first, which is not
    /// a failure and must not drop the card.
    public func fetch(_ card: DeckCard, now: Date = Date()) async -> Bool {
        let landed = (try? await cache(photoID: card.id, now: now)) ?? false
        return landed || store.contains(PhotoStore.Key(photoUUID: card.uuid))
    }

    /// Ends a fetch: releases the claim, and tells the bench what happened.
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

    /// A card whose fetch did not produce bytes leaves the queue.
    ///
    /// **Syd's rule: if something goes wrong with the fetch, move on with the
    /// next card.** The photograph keeps its row — a failed read proves
    /// nothing about it, and `handleFailedDownload` has already deleted it if
    /// its source confirmed it gone — and goes back into the deck's contention
    /// like any other. Nothing is said when the card was already gone, which is
    /// what a confirmed absence's cascade leaves behind.
    public func dropUnfetched(_ card: DeckCard, because reason: String) {
        try? deck.releaseClaim(photoID: card.id)
        guard (try? queue.remove(photoID: card.id)) == true else { return }
        log(
            .cacheDropped(
                photo: card.externalID, source: card.sourceID, because: reason, queued: depth()))
    }

    /// What one step of fetching from the queue did, for a caller content to
    /// wait: a test, or a one-shot tool.
    public enum FetchStep: Sendable, Equatable {
        case fetched(rank: Int64)
        /// The fetch failed and the card has left the queue.
        case failed(rank: Int64)
        case benched(rank: Int64)
        case blocked
        case drained
    }

    /// Next, fetch, finish, in one call and **with no deadline**.
    ///
    /// The three-step form above exists because running a fetch against a
    /// deadline means letting go of work that may never return, which the host
    /// has to arrange. This is not what the agent uses, and it is not where the
    /// hostile-provider handling lives.
    @discardableResult
    public func fetchQueuedOnce(after rank: Int64? = nil, now: Date = Date()) async
        -> FetchStep
    {
        switch nextQueuedToFetch(after: rank, now: now) {
        case .blocked: return .blocked
        case .drained: return .drained
        case .benched(let rank): return .benched(rank: rank)
        case .card(let card, let rank, let limit):
            log(.caching(photo: card.externalID, source: card.sourceID, within: limit))
            let landed = await fetch(card, now: now)
            finishFetch(card, landed: landed)
            if !landed { dropUnfetched(card, because: "its fetch failed") }
            return landed ? .fetched(rank: rank) : .failed(rank: rank)
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

    /// **Serving takes the head card, waits for its bytes if they are not here
    /// yet, and hands it over.** Decided 2026-09-05; see the plan's *Deal over
    /// everything, and the queue fetches its own cards*.
    ///
    /// A card is dealt whether or not its bytes are here, and the queue's
    /// fetcher has been working on it since it was dealt — so by the time it
    /// reaches the head it has usually had twenty pictures' worth of time and
    /// the bytes are simply here. When they are not, the request waits, up to
    /// `serveWait`, polling for one of three things: the bytes land, and the
    /// card is served; the card leaves the queue, because its fetch failed and
    /// the fetcher dropped it, and the request moves to the new head; or the
    /// wait runs out.
    ///
    /// **The wait is spent once per request.** When it runs out the cold card
    /// is dropped from the queue — the card was dealt but no bytes were served;
    /// such is life, and next time it is dealt maybe the bytes will be there —
    /// and the request takes the first queued card whose bytes *are* here,
    /// without waiting again. Nothing else is dropped: the cards it passes over
    /// are still being fetched and keep their places. A card whose source is
    /// benched is dropped without waiting at all, because nothing is fetching
    /// it and nothing will for at least a minute.
    ///
    /// Three other things can still go wrong between dealing a card and serving
    /// it, all rare: its source lost its provider, a referenced file is gone
    /// from under us, or the photograph was deleted where it lives. Each skips.
    /// **The loop needs no bound**: every turn removes a card, or spends the
    /// one wait, and nothing adds a card while a request is in flight.
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
        // How long this request may still wait for a cold card. Spent once.
        var patience = serveWait

        while true {
            // The head — or, once the wait is spent, the first card with bytes.
            let candidate: (card: DeckCard, bytes: URL?)?
            if patience > .zero {
                candidate = try queue.peek().first.map { ($0, try bytesHere(for: $0, fitting: box)) }
            } else {
                candidate = try firstQueuedWithBytes(fitting: box)
            }
            guard let (card, foundBytes) = candidate else {
                log(.nothingToShow(walked: skipped, because: "out of cards"))
                return nil
            }

            // Neither guard below is a photograph that has *gone*, so neither
            // deletes anything. A missing source row is only reachable as a
            // race — foreign keys are on — and a missing provider is a Photos
            // album in a build that cannot enumerate one, where deleting the
            // rows would destroy a library on a downgrade.
            guard let source = try sources.source(id: card.sourceID),
                let provider = sources.provider(for: source.kind)
            else {
                skipped += 1
                _ = try await queue.remove(photoID: card.id)
                log(.skipped(photo: card.externalID, source: card.sourceID, because: "no provider for its source", queued: depth()))
                continue
            }

            var bytes = foundBytes
            if bytes == nil {
                // A referenced photograph *is* its file; there is nothing to
                // wait for. Its file being gone is the eviction race's last
                // door, or a folder edited under us, and either way it skips.
                guard card.storage == .materialized else {
                    skipped += 1
                    _ = try await queue.remove(photoID: card.id)
                    vanished(card)
                    continue
                }
                // **Cold.** If the record said held, it lied — correct it, so
                // the fetcher sees this card as something to fetch.
                try releaseResidency(ofPhotos: [card.uuid])

                // A benched source is not being fetched from and will not be
                // for at least a minute. Waiting on its card is a minute spent
                // learning what the bench already knows.
                if bench?.isBenched(card.sourceID) == true {
                    skipped += 1
                    dropUnfetched(card, because: "its source is not answering")
                    continue
                }

                log(.waiting(photo: card.externalID, source: card.sourceID, upTo: patience, queued: depth()))
                // Join the fetch already running for it, or have one started.
                ensureFetching()
                switch try await waitForBytes(of: card, fitting: box, upTo: patience) {
                case .landed(let url):
                    bytes = url
                case .gone:
                    // The fetcher dropped it, or its source confirmed it gone
                    // and the row went. Either way the head has moved.
                    skipped += 1
                    continue
                case .timedOut:
                    skipped += 1
                    patience = .zero
                    dropUnfetched(card, because: "its bytes did not arrive in \(serveWait)")
                    continue
                }
            }
            guard let url = bytes else { continue }
            let isRendering = box.map { store.url(for: PhotoStore.Key(photoUUID: card.uuid, size: $0)) == url } ?? false

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

            // **The pop, and the atomicity.** Two consumers may both have
            // chosen this card; the `DELETE` under `BEGIN IMMEDIATE` lets
            // exactly one of them take it, and the other goes round again.
            guard try await queue.remove(photoID: card.id) else { continue }

            log(
                .serving(
                    photo: card.externalID, source: card.sourceID,
                    rendering: isRendering, unconfirmed: unconfirmed, queued: depth()))
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
                isRendering: isRendering
            )
        }
    }

    /// How long a request may wait for the head card's bytes. The host sets it
    /// from `Preferences.serveWait`; sixty seconds unless told otherwise, and
    /// zero never waits.
    public var serveWait: Duration = .seconds(60)

    /// Asked to make sure the card a request is waiting on is being fetched.
    /// The agent wires it to the queue fetcher's kick, which is absorbed when
    /// a round is already running; a cache built in a test need not wire it.
    public var ensureFetching: @Sendable () -> Void = {}

    /// Where a card's bytes are, if they are here: a rendering at the requested
    /// size, looked at first because it is the cheaper answer *and* may be the
    /// only one left after the original was evicted; otherwise the original.
    private func bytesHere(for card: DeckCard, fitting box: PhotoStore.Size?) throws -> URL? {
        let held = box.flatMap { store.url(for: PhotoStore.Key(photoUUID: card.uuid, size: $0)) }
        return try held ?? residentURL(forPhoto: card.id)
    }

    /// The first queued card, head first, whose bytes are here. For a request
    /// that has spent its wait and is not waiting again.
    private func firstQueuedWithBytes(fitting box: PhotoStore.Size?) throws -> (card: DeckCard, bytes: URL?)? {
        for card in try queue.peek(max(queue.nominalSize * 2, 64)) {
            if let url = try bytesHere(for: card, fitting: box) { return (card, url) }
        }
        return nil
    }

    private enum Waited {
        case landed(URL)
        case gone
        case timedOut
    }

    /// Polls for a cold card's bytes until they land, the card leaves the
    /// queue, or `limit` passes. A poll rather than a notification, because the
    /// fetch lands on another connection in another isolation domain and the
    /// store's index is the one thing both sides can see; a tenth of a second
    /// is nothing beside a fetch and beside the picture's dwell.
    private func waitForBytes(
        of card: DeckCard, fitting box: PhotoStore.Size?, upTo limit: Duration
    ) async throws -> Waited {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while true {
            if let url = try bytesHere(for: card, fitting: box) { return .landed(url) }
            guard try queue.contains(photoID: card.id) else { return .gone }
            guard clock.now < deadline else { return .timedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A card whose bytes are not where the library says they are.
    ///
    /// The record has to stop claiming the photograph is held, so the queue's
    /// fetcher sees it as something to fetch the next time it is dealt. Nothing
    /// else: there is no credit to return any more.
    private func vanished(_ card: DeckCard) {
        if card.storage == .materialized {
            try? releaseResidency(ofPhotos: [card.uuid])
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
