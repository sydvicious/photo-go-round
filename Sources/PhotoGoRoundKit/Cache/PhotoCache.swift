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

    /// Told what serving found each time it looks for a materialized card's
    /// bytes. Nothing by default; the agent counts them for its dashboard.
    public var lookedUp: @Sendable (CacheLookup) -> Void = { _ in }

    /// Told, for each materialized card dealt, whether its original was already
    /// held. Nothing by default; the agent counts them for its dashboard.
    public var dealLookedUp: @Sendable (DealLookup) -> Void = { _ in }

    /// Whether this launch has cleared resized-copy files that no row records.
    /// The process's own by default; a test brings its own.
    public var copySweep: ResizedCopies.Sweep = .launch

    /// Told what an eviction took, when it took anything. The agent counts it
    /// for the dashboard and says so on the console; see `evictAfterWriting()`.
    public var evicted: @Sendable (EvictionResult) -> Void = { _ in }

    /// Rows deleted per transaction when evicted copies are forgotten. "Long
    /// locks in the database are death."
    static let copyRowPage = 100

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
    public func prepare() async throws -> PhotoStore.IndexResult {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
        // A crash mid-download leaves its temporary in `.staging`. The index
        // walk would now sweep it as a leftover rendering directory, which is
        // the right outcome by luck rather than by design, so it is still taken
        // here explicitly and stays correct when that sweep is deleted.
        try? FileManager.default.removeItem(at: root.appending(path: Self.stagingDirectory))
        let result = try await indexCache()
        await store.walked()
        return result
    }

    /// What the database says this cache held, as the index to open on.
    ///
    /// **Phase 6 of `Agent Performance Overhaul.md`.** The walk that used to
    /// build the index took 8.9 s after a restart against 137 ms warm, and the
    /// listener opened only after it. This is one query, and the walk follows
    /// in the background — `walkCache()`.
    ///
    /// A photograph is believed when its row says `cached_at`; the file's name
    /// is the photograph's uuid and its source's, with the extension the
    /// external id carries, which is what `adopt` wrote.
    @discardableResult
    public func prepareFromDatabase() async throws -> Held {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
        try? FileManager.default.removeItem(at: root.appending(path: Self.stagingDirectory))

        var believed: [PhotoStore.Believed] = []
        var bytes: Int64 = 0
        try database.query(
            """
            SELECT p.uuid AS photo_uuid, s.uuid AS source_uuid, p.external_id AS external_id,
                   COALESCE(p.byte_size, 0) AS byte_size
              FROM photo p JOIN source s ON s.id = p.source_id
             WHERE p.cached_at IS NOT NULL;
            """
        ) { row in
            let photoUUID = try row.string("photo_uuid")
            let sourceUUID = try row.string("source_uuid")
            let byteCount = try row.int64("byte_size")
            let url = store.url(
                forPhoto: photoUUID, sourceUUID: sourceUUID,
                pathExtension: (try row.string("external_id") as NSString).pathExtension)
            believed.append(
                PhotoStore.Believed(
                    uuid: photoUUID, sourceUUID: sourceUUID, url: url, byteCount: byteCount))
            bytes += byteCount
        }
        await store.believe(believed)
        return Held(photos: believed.count, bytes: bytes)
    }

    /// What the database claimed at launch.
    public struct Held: Sendable, Equatable {
        public let photos: Int
        public let bytes: Int64
    }

    /// The walk, for a caller that has already opened on the database's index.
    ///
    /// **At launch and every `cacheWalkInterval` after it**, in the background.
    /// Syd, 2026-09-17: "you still need to do the cache walk periodically,
    /// especially at startup, to make sure that the agent's idea of the
    /// filesystem matches what is actually on disk", and "its own interval,
    /// default an hour". It is the same walk `prepare()` does, and it is what
    /// lets eviction run.
    @discardableResult
    public func walkCache() async throws -> PhotoStore.IndexResult {
        let result = try await indexCache()
        await store.walked()
        return result
    }

    /// Where a fetch writes before adopting into the store. Beside the source
    /// directories, and removed at launch rather than indexed.
    static let stagingDirectory = ".staging"

    /// Rebuilds the byte index from the disk, discarding anything the database
    /// does not claim.
    ///
    /// This is the whole of what used to be `verifyResidency` and
    /// `sweepOrphans`: an index built *from* the filesystem cannot disagree with
    /// it, and a file whose UUID is unknown has no owner left that could name it
    /// correctly.
    @discardableResult
    public func indexCache() async throws -> PhotoStore.IndexResult {
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
        let result = await store.rebuild(photos: owners)
        // **The disk wins.** The walk above is the truth about what is held;
        // `cached_at` is a projection of it, and this is where a projection
        // that drifted — a file deleted by hand, a database restored from a
        // backup, an upgrade that arrived with the column empty — is put back.
        try reconcileResidency(with: await store.residentPhotoUUIDs)
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
    public func residentURL(forPhoto photoID: Int64) async throws -> URL? {
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
            return await store.url(forPhoto: row.uuid)
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
        public let bytesOnDisk: Int64
        public let byteCeiling: Int64
        public let freeBytesOnVolume: Int64
        /// Pictures waiting in the queue, ready to show.
        public let queued: Int
    }

    /// What the cache occupies against its ceiling: originals and resized
    /// copies, which share it.
    public func bytesOnDisk() async throws -> Int64 {
        await store.totals.byteCount + (try ResizedCopies.byteCount(in: database))
    }

    public func status() async throws -> Status {
        let materialized =
            try database.scalarInt(
                "SELECT COUNT(*) FROM photo WHERE storage = 'materialized';") ?? 0
        let referenced =
            try database.scalarInt(
                "SELECT COUNT(*) FROM photo WHERE storage = 'referenced';") ?? 0
        let totals = await store.totals

        return Status(
            residentCount: totals.entries,
            referencedCount: referenced,
            pendingCount: max(0, materialized - totals.entries),
            bytesOnDisk: try await bytesOnDisk(),
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
    public func deal(settings: DeckSettings = .default, now: Date = Date()) async throws -> Bool {
        guard let candidate = try deck.nextCandidate(settings: settings, now: now) else {
            return false
        }
        // No claim to release: dealing takes none. Two fillers are kept apart
        // by the queue, which refuses a photograph it already holds.

        // The byte store is keyed by source, so it has to be told which source a
        // photograph belongs to before anything is written for it. **Only a
        // materialized photograph is ever written**, since the resize cache went
        // on 2026-09-06 and a referenced one is read where it lies; this is
        // called for every candidate anyway, because it is one dictionary write
        // and the alternative is a second place that has to know the rule.
        await store.note(photoUUID: candidate.uuid, sourceUUID: candidate.sourceUUID)
        guard try queue.append(photoID: candidate.id, sourceID: candidate.sourceID, at: now) else {
            return false
        }
        // The fetch side of the hit rate, counted only for a card that was
        // actually dealt. A referenced photograph never touches the cache.
        if candidate.storage == .materialized {
            dealLookedUp(await store.contains(photo: candidate.uuid) ? .hit : .miss)
        }
        log(.dealt(photo: candidate.externalID, source: candidate.sourceID, queued: (try? queue.size()) ?? 0))
        return true
    }

    // MARK: - Caching one picture, off the serving path

    /// Fetches one photograph's bytes into the cache.
    ///
    /// **Called by the queue's fetcher, never by serving.** The card is on the
    /// queue when this starts and this lands its bytes behind it — though a
    /// request that met the card cold may have dropped it in the meantime, which
    /// changes nothing here: the bytes belong to the photograph.
    ///
    /// Answers false when there was nothing to do or nothing could be done: it
    /// is already held, its source is unreachable, its provider is missing, or
    /// the download failed. A failure is said on the console, with why.
    @discardableResult
    public func cache(photoID: Int64, now: Date = Date()) async throws -> Bool {
        switch try await attemptCache(photoID: photoID, now: now) {
        case .landed:
            return true
        case .unnecessary:
            return false
        case .failed(let reason, let card):
            if let card {
                log(.cacheFailed(photo: card.spokenName, source: card.sourceID, because: reason))
            }
            return false
        }
    }

    /// What trying to cache one photograph came to.
    enum CacheAttempt: Sendable {
        case landed
        /// Nothing to fetch, and why: its bytes are already here, or it is read
        /// in place.
        case unnecessary(String)
        /// Nothing fetched, and why — with the card, when it could be read.
        case failed(String, DeckCard?)
    }

    /// The work of `cache(photoID:)`, answering why when nothing landed.
    ///
    /// **A failure is not said here**, because each of its two callers says it
    /// once: `cache(photoID:)` on the console, and `fetch` on the console and
    /// back to the agent's fetcher, which puts the words in the error record.
    /// Every way this comes to nothing has words, including the ones that used
    /// to answer a bare false — a disabled source, a missing provider, the disk
    /// at its floor — so no failed fetch reaches the record without a reason.
    func attemptCache(photoID: Int64, now: Date) async throws -> CacheAttempt {
        // Free space is checked before fetching, so running out of disk degrades
        // into "the cache stops growing" rather than a full volume.
        let free = freeBytesOnVolume()
        guard free >= self.settings.minimumFreeBytes else {
            Log.cache.notice(
                "not caching: \(free, privacy: .public) bytes free, floor is \(self.settings.minimumFreeBytes, privacy: .public)"
            )
            return .failed(
                "\(free) bytes free on the cache's volume, below the floor of \(self.settings.minimumFreeBytes)",
                nil)
        }

        guard let card = try deck.card(photoID: photoID) else {
            return .failed("it is no longer in the library", nil)
        }
        // Already there. This is how asking for the same picture more than once
        // costs a skip rather than a second fetch — the check is here, when the
        // request comes off the queue, rather than in whatever put it on.
        guard card.storage == .materialized else {
            return .unnecessary("it is read in place and never fetched")
        }
        guard await !store.contains(photo: card.uuid) else {
            log(.cacheUnnecessary(photo: card.spokenName, source: card.sourceID))
            return .unnecessary("its bytes are already here")
        }

        guard let source = try sources.source(id: card.sourceID) else {
            return .failed("its source is gone", card)
        }
        guard source.enabled else { return .failed("its source is disabled", card) }
        guard let provider = sources.provider(for: source.kind) else {
            return .failed("this build has no provider for \(source.kind.rawValue) sources", card)
        }

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
            let gone = try await handleFailedDownload(card, source: source, provider: provider)
            return .failed(
                gone ? "\(error); its source confirms it gone, so it has left the library" : "\(error)",
                card)
        }
        do {
            try await store.adopt(
                fileAt: temporary, forPhoto: card.uuid,
                sourceUUID: card.sourceUUID, pathExtension: extension_)
            // **Residency is recorded in the same statement as the size.**
            // `cached_at` is the projection of what the store holds; the
            // eviction order reads it, the status lines count it, and the
            // queue's fetcher uses it to find cards that still need bytes.
            //
            // **The name goes in the same statement**, when the provider knew
            // one: this is the moment it holds the asset's resources, and
            // anywhere else the name is a round trip to Photos. A fetch that
            // does not say keeps whatever was recorded rather than clearing it.
            try database.run(
                """
                UPDATE photo
                   SET byte_size = :size, cached_at = :now,
                       original_filename = COALESCE(:name, original_filename)
                 WHERE id = :id;
                """,
                [
                    "size": .int(file.byteSize), "now": SQLValue(now),
                    "name": SQLValue(file.originalFilename), "id": .int(card.id),
                ]
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
            await store.remove(photoUUID: card.uuid)
            // Only logged here. The agent's fetcher records it with every other
            // reason a fetch comes to nothing, as `cache.fetch-failed`; this was
            // `cache.could-not-keep` until 2026-09-13, which recorded it twice.
            Log.cache.error(
                kind: nil, "photo \(card.id) was fetched and could not be kept: \(error)")
            return .failed("it was fetched and could not be kept: \(error)", card)
        }

        if let ring = evictionBell { ring() } else { await evictNow() }

        // **Nothing about the queue changes here**, including when the card
        // these bytes were fetched for is no longer on it. Usually it is, and
        // keeps its place — that is why they were fetched. But a request that
        // met it cold will have dropped it out from under this fetch, which is
        // what the short serve wait is for, and the bytes are adopted just the
        // same: they are the photograph's, not the card's, and the next deal of
        // it finds them here. The v1 starvation, where a fetched card had left
        // the queue and had a one-in-the-library chance of coming back, cannot
        // recur either way — that was the *deck* forgetting it, and the row is
        // untouched here.
        // Named with what this fetch just learned, which the card read before
        // it cannot know.
        let named = DeckCard(
            id: card.id, uuid: card.uuid, sourceID: card.sourceID, sourceUUID: card.sourceUUID,
            externalID: card.externalID, storage: card.storage, dealSeq: card.dealSeq,
            originalFilename: file.originalFilename ?? card.originalFilename)
        log(
            .cached(
                photo: named.spokenName, source: card.sourceID,
                bytes: await store.url(forPhoto: card.uuid).flatMap {
                    (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                } ?? 0))
        return .landed
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
    public func nextQueuedToFetch(after rank: Int64? = nil, now: Date = Date()) async
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
            if await store.contains(photo: card.uuid) { continue }

            // **A benched source is not asked at all.** Its card stays where it
            // is and is looked at again on the next kick; the lane moves past
            // it so the healthy sources behind it are fetched.
            if await bench?.isBenched(card.sourceID) == true { return .benched(rank: found.rank) }

            // A source row gone from under its card is a race with removal —
            // the cascade will take the card too. Walk on.
            guard let source = try? sources.source(id: card.sourceID) else { continue }

            // Another lane got here first. Its claim is what keeps this one
            // from downloading the same bytes; walk on.
            guard (try? deck.claim(photoID: card.id, now: now)) == true else { continue }

            return .card(card, rank: found.rank, within: Self.deadline(for: source.kind))
        }
    }

    /// What a queued card's fetch came to.
    public enum FetchAnswer: Sendable, Equatable {
        /// Its bytes are here — including when another path landed them first,
        /// which is not a failure and must not drop the card.
        case landed
        /// They are not, and why, in words for the console and the agent's
        /// error record.
        case failed(because: String)

        public var didLand: Bool { self == .landed }
    }

    /// Fetches a queued card's bytes, and says why on the console when they are
    /// not here afterwards.
    public func fetch(_ card: DeckCard, now: Date = Date()) async -> FetchAnswer {
        let reason: String
        do {
            switch try await attemptCache(photoID: card.id, now: now) {
            case .landed: return .landed
            case .unnecessary(let why): reason = why
            case .failed(let why, _): reason = why
            }
        } catch {
            reason = "\(error)"
        }
        if await store.contains(photo: card.uuid) { return .landed }
        log(.cacheFailed(photo: card.spokenName, source: card.sourceID, because: reason))
        return .failed(because: reason)
    }

    /// Ends a fetch: releases the claim, and tells the bench what happened.
    ///
    /// Called whatever the outcome, including for work that was abandoned —
    /// a claim left behind sidelines a photograph for the whole timeout.
    ///
    /// **Only the success is reported from here.** A failure is reported by the
    /// lane, through `fetchFailed`, because this runs inside work the lane may
    /// already have given up on: reporting the failure here as well would count
    /// an abandoned fetch twice, once when its lane wrote it off and once more
    /// when it finally came back.
    public func finishFetch(_ card: DeckCard, landed: Bool) async {
        try? deck.releaseClaim(photoID: card.id)
        if landed {
            // One fetch that produced bytes pays off one failure. An occasional
            // timeout on a working source is weather; see `SourceBench`, where
            // the bucket and the reason it is not a reset are written down.
            await bench?.succeeded(card.sourceID)
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
                photo: card.spokenName, source: card.sourceID, because: reason, queued: depth()))
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
        switch await nextQueuedToFetch(after: rank, now: now) {
        case .blocked: return .blocked
        case .drained: return .drained
        case .benched(let rank): return .benched(rank: rank)
        case .card(let card, let rank, let limit):
            log(.caching(photo: card.spokenName, source: card.sourceID, within: limit))
            let landed = await fetch(card, now: now).didLand
            await finishFetch(card, landed: landed)
            if !landed { dropUnfetched(card, because: "its fetch failed") }
            return landed ? .fetched(rank: rank) : .failed(rank: rank)
        }
    }

    /// A fetch that ran out of time. Answers the bench it earned, if any.
    @discardableResult
    public func fetchTimedOut(_ card: DeckCard, after limit: Duration) async -> Duration? {
        let benched = await bench?.failed(card.sourceID)
        log(
            .cacheTimedOut(photo: card.spokenName, source: card.sourceID, after: limit))
        if let benched {
            log(.sourcePaused(source: card.sourceID, until: benched))
        }
        return benched
    }

    /// A fetch that answered, and answered with nothing. Answers the bench it
    /// earned, if any.
    ///
    /// **The bench could not see this until 2026-09-07, and that made it
    /// inert.** `fetchTimedOut` was its only informant, and that fires only when
    /// the host's outer `FetchDeadline` gives up — which stopped happening at
    /// all once `SystemPhotoLibrary.write` was taken off the cooperative pool
    /// and its own sixty-second limit began firing on time. The two bounds are
    /// equal, so the inner one now always wins and the outer one never speaks.
    /// Measured the same evening: 116 failed fetches, no call to `failed`, no
    /// bench.
    ///
    /// A fetch that produced no bytes is a fetch that produced no bytes,
    /// whichever bound noticed. Both say so now.
    @discardableResult
    public func fetchFailed(_ card: DeckCard) async -> Duration? {
        let benched = await bench?.failed(card.sourceID)
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
    ///
    /// Answers whether the photograph was removed.
    private func handleFailedDownload(
        _ card: DeckCard, source: Source, provider: any SourceProvider
    ) async throws -> Bool {
        switch await provider.existence(of: card.externalID, in: source) {
        case .absent:
            Log.cache.notice(
                "photo \(card.id, privacy: .public) failed to fetch and its source confirms it absent; removing it from the pool"
            )
            try await self.remove(card.id)
            return true
        case .present:
            Log.cache.info(
                "photo \(card.id, privacy: .public) is present and could not be fetched; keeping it"
            )
            return false
        case .unknown:
            Log.cache.info(
                "photo \(card.id, privacy: .public) could not be confirmed either way; keeping it"
            )
            return false
        }
    }

    // MARK: - Serving one picture

    /// One picture, ready to hand over.
    public struct ServedPhoto: Sendable {
        public let card: DeckCard
        /// The source it came from, as serving found it — so the host can say
        /// what the source is called without a second read.
        public let source: Source
        /// The bytes to send: the photograph's original, in place for a
        /// referenced file and in the cache for a materialized one. **Always
        /// the original** — the store stopped holding renderings on 2026-09-06,
        /// so there is no longer a second thing this could be, and the caller
        /// renders from it on every request.
        public let url: URL
        /// The resized copy for the box the request asked for, when the cache
        /// keeps one. Nil for a request that asked for no box.
        public var copy: ResizedCopies.Copy? = nil
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
    /// **The wait is spent once per request, and every cold card the request
    /// meets leaves the queue.** When the wait runs out the head is dropped —
    /// the card was dealt but no bytes were served; such is life, and next time
    /// it is dealt maybe the bytes will be there. The request then takes the
    /// new head, and drops that too if it is cold, until it meets a card whose
    /// bytes are here or the queue is empty. A card whose source is benched is
    /// dropped without waiting at all, because nothing is fetching it and
    /// nothing will for at least a minute.
    ///
    /// **The cards it passes over used to keep their places, and that was the
    /// fault.** They were still being fetched, so leaving them looked like the
    /// generous reading; what it means in practice is that the next request
    /// meets them again, in the same order, ahead of every card that could have
    /// been shown. A run of photographs the network will not deliver settles at
    /// the head and each request pays for the whole run. Measured 2026-09-07
    /// with the network off: twenty cards queued, seventeen of them warm, both
    /// windows stalled behind one that was not.
    ///
    /// Dropping is cheap, which is what makes the rule safe. The photograph
    /// keeps its row and goes back into the deck's contention; the fetch
    /// running for it is not cancelled and its bytes are still adopted when they
    /// land, so the next deal of it finds them here.
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
    /// in the minutes before a refresh would have noticed. **Unless the source
    /// will not say.** The check has `ServiceTiming.serveCheckBudget` for the
    /// whole request, and a source that runs it out is `.unknown` — the held
    /// copy goes out, because a client that has stopped listening is shown
    /// nothing at all.
    ///
    /// **The box the caller is about to draw into is its business again since
    /// 2026-09-16.** `serve` took a `fitting:` size until 2026-09-06, so that a
    /// photograph whose original had been evicted could still be answered from
    /// a rendering held at that size, and dropped it when renderings stopped
    /// being kept. With resized copies kept again, `fitting:` is back for the
    /// same reason: a card is ready if its original is here **or** it has a copy
    /// for the box asked for, and `ServedPhoto.copy` carries that copy. A
    /// request with no box needs the original, as before.
    public func serve(
        to consumerID: Int64? = nil,
        now: Date = Date(),
        fitting request: ResizedCopies.Request? = nil
    ) async throws -> ServedPhoto? {
        var timing = StageTimes()
        return try await serve(to: consumerID, now: now, fitting: request, timing: &timing)
    }

    /// The same, charging each step to `timing` for the endpoint's `TIMING:`
    /// line: `queue` for reading and walking the head, `wait` for a cold
    /// card's bytes, `check` for asking the source, `remove` for the pop, and
    /// `shown` for recording the deal.
    public func serve(
        to consumerID: Int64? = nil,
        now: Date = Date(),
        fitting request: ResizedCopies.Request? = nil,
        timing: inout StageTimes
    ) async throws -> ServedPhoto? {
        var skipped = 0
        // How long this request may still wait for a cold card. Spent once.
        var patience = serveWait
        // How long this request may spend asking sources whether the card going
        // out is still there. Also spent once, across every card it checks.
        let checking = RequestBudget(ServiceTiming.serveCheckBudget)

        while true {
            // **Always the head.** Every turn either serves it or takes it off
            // the queue, so the head is the only card a request ever looks at.
            guard let card = try queue.peek().first else {
                timing.lap("queue")
                log(.nothingToShow(walked: skipped, because: "out of cards"))
                return nil
            }
            let foundBytes = try await bytesHere(for: card)
            // **The copy for the box asked for, if the cache keeps one**, so a
            // card whose original has been evicted is ready all the same. Syd,
            // 2026-09-16: "You can serve the copy if the original has been
            // evicted." Until then a card was ready only if its original was
            // here, and one whose original had gone waited for a fetch and was
            // dropped, however many copies of it were kept.
            let copyRoot = store.root
            let copy = try request.flatMap { wanted in
                try ResizedCopies.find(
                    photoID: card.id, boxWidth: wanted.width, boxHeight: wanted.height,
                    format: wanted.format, root: copyRoot, database: database)
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
                log(.skipped(photo: card.spokenName, source: card.sourceID, because: "no provider for its source", queued: depth()))
                continue
            }

            // Counted here, after the provider guard, so a card skipped for
            // want of a source is not a lookup at all.
            if foundBytes != nil || copy != nil, card.storage == .materialized { lookedUp(.hit) }

            var bytes = foundBytes ?? copy?.url
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
                if await bench?.isBenched(card.sourceID) == true {
                    skipped += 1
                    lookedUp(.miss(.droppedWithoutWaiting))
                    dropCold(card, because: "its source is not answering")
                    continue
                }

                // **The wait is spent once, and afterwards a cold card is
                // dropped on sight.** It used to keep its place while the
                // request walked past it, which is the fault this rule exists
                // to remove: the card is met again by the next request, and the
                // one after that, so a run of photographs the network will not
                // deliver settles at the head of the queue and every request
                // pays for all of them. Measured 2026-09-07 with the network
                // off — twenty cards queued, seventeen of them warm, and both
                // windows stalled behind one that was not.
                //
                // Dropping costs a deal and not a photograph: the row stays in
                // the pool, the fetch that is running for it is not cancelled,
                // and its bytes are simply here the next time it is dealt.
                guard patience > .zero else {
                    skipped += 1
                    lookedUp(.miss(.droppedWithoutWaiting))
                    dropCold(card, because: "its bytes are not here and the wait is spent")
                    continue
                }

                log(.waiting(photo: card.spokenName, source: card.sourceID, upTo: patience, queued: depth()))
                // Join the fetch already running for it, or have one started.
                ensureFetching()
                timing.lap("queue")
                let waited = try await waitForBytes(of: card, upTo: patience)
                timing.lap("wait")
                switch waited {
                case .landed(let url):
                    lookedUp(.miss(.landed))
                    bytes = url
                case .gone:
                    // The fetcher dropped it, or its source confirmed it gone
                    // and the row went. Either way the head has moved.
                    skipped += 1
                    lookedUp(.miss(.leftDuringWait))
                    continue
                case .timedOut:
                    skipped += 1
                    lookedUp(.miss(.timedOut))
                    patience = .zero
                    dropCold(card, because: "its bytes did not arrive in \(serveWait)")
                    continue
                }
            }
            guard let url = bytes else { continue }

            // **Is it still there? — asked last, and only about the one card
            // that is going out.** It is a promise about what is *displayed*,
            // so it belongs to the card being displayed and to no other.
            //
            // **Inside one budget for the whole request, and silence is
            // `.unknown`.** A source that does not answer in time has said
            // nothing about the photograph, which is exactly what `.unknown`
            // means — so the copy we hold goes out, as it would have after the
            // source's own, much longer, bound. See
            // `ServiceTiming.serveCheckBudget` for the twenty seconds this was.
            var unconfirmed: String?
            let externalID = card.externalID
            timing.lap("queue")
            let existence =
                await checking.attempt { await provider.existence(of: externalID, in: source) }
                ?? .unknown(reason: Self.checkUnanswered)
            timing.lap("check")
            switch existence {
            case .absent:
                skipped += 1
                log(.dropped(photo: card.spokenName, source: card.sourceID, because: "gone from a source that is right there", queued: depth()))
                try await self.remove(card.id)
                continue

            case .unknown(let reason):
                // **Offline and gone are opposite answers**: one keeps
                // everything and serves the copy we hold, the other means these
                // photographs are never coming back.
                //
                // Out of the same budget. A source that has not answered in
                // time is not `.gone`, so running out keeps the picture.
                let availability = await checking.attempt { await provider.availability(of: source) }
                timing.lap("check")
                if case .gone(let why)? = availability {
                    skipped += 1
                    log(.dropped(photo: card.spokenName, source: card.sourceID, because: "its source is \(why)", queued: depth()))
                    try await self.remove(card.id)
                    continue
                }
                unconfirmed = reason

            case .present:
                break
            }

            // **The pop, and the atomicity.** Two consumers may both have
            // chosen this card; the `DELETE` under `BEGIN IMMEDIATE` lets
            // exactly one of them take it, and the other goes round again.
            timing.lap("queue")
            let removed = try await queue.remove(photoID: card.id)
            timing.lap("remove")
            guard removed else { continue }

            log(
                .serving(
                    photo: card.spokenName, source: card.sourceID,
                    unconfirmed: unconfirmed, queued: depth()))
            let seq = try await deck.markShown(photoID: card.id, now: now)
            if let consumerID { try? deck.touch(consumerID: consumerID, at: now) }
            timing.lap("shown")
            // The deck moved, so anything mirroring its position — a diagnostic
            // panel, another surface's idea of what is next — should go and look.
            doorbells?.post(.deckAdvanced)
            return ServedPhoto(
                card: DeckCard(
                    id: card.id, uuid: card.uuid, sourceID: card.sourceID,
                    sourceUUID: card.sourceUUID, externalID: card.externalID,
                    storage: card.storage, dealSeq: seq,
                    originalFilename: card.originalFilename
                ),
                source: source,
                url: url,
                copy: copy
            )
        }
    }

    /// How long a request may wait for the head card's bytes. The host sets it
    /// from `Preferences.serveWait`, where the two seconds are measured and the
    /// measurement is written down; zero never waits. Cold cards are dropped
    /// either way — the wait decides how long one is given first, not whether
    /// it keeps its place.
    public var serveWait: Duration = .seconds(2)

    /// Why a card went out unconfirmed when its source ran out the request's
    /// check budget. Logged on the `SERVE:` line as *unconfirmed (…)*.
    static let checkUnanswered =
        "its source did not answer within \(ServiceTiming.serveCheckBudget.spokenSeconds)"

    /// Asked to make sure the card a request is waiting on is being fetched.
    /// The agent wires it to the queue fetcher's kick, which is absorbed when
    /// a round is already running; a cache built in a test need not wire it.
    public var ensureFetching: @Sendable () -> Void = {}

    /// Where a card's bytes are, if they are here. **One place to look now**:
    /// the original, in the cache for a materialized photograph and in place
    /// through `FileAccess` for a referenced one. It used to check for a
    /// rendering at the requested size first.
    private func bytesHere(for card: DeckCard) async throws -> URL? {
        try await residentURL(forPhoto: card.id)
    }

    /// A cold card leaving the queue at a request's hand.
    ///
    /// **The claim is left alone, and that is the whole difference from
    /// `dropUnfetched`.** The claim belongs to the fetch, not to the card's
    /// place in the queue, and serving drops cards out from under fetches that
    /// are still running — that is the point of the short wait. Releasing it
    /// here would let a re-deal of this photograph hand it to a second lane
    /// while the first is still streaming, and both write `staging/<uuid>` at
    /// once: one corrupt image, which reaches a person as a photograph that
    /// retires itself after three render failures.
    ///
    /// Nothing is lost by leaving it. A card no lane has reached is unclaimed
    /// already, so this is a no-op for it; a card being fetched has its claim
    /// released by `finishFetch` when the fetch ends, and `Deck.claimTimeout`
    /// is the backstop above that.
    private func dropCold(_ card: DeckCard, because reason: String) {
        guard (try? queue.remove(photoID: card.id)) == true else { return }
        log(
            .cacheDropped(
                photo: card.spokenName, source: card.sourceID, because: reason, queued: depth()))
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
        of card: DeckCard, upTo limit: Duration
    ) async throws -> Waited {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while true {
            if let url = try await bytesHere(for: card) { return .landed(url) }
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
                photo: card.spokenName, source: card.sourceID,
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
    public func remove(_ photoIDs: [Int64]) async throws -> PhotoPool.Removal {
        let removal = try await sources.pool.remove(photoIDs)
        await store.discard(removal)
        return removal
    }

    @discardableResult
    public func remove(_ photoID: Int64) async throws -> PhotoPool.Removal {
        try await remove([photoID])
    }

    // MARK: - Eviction

    public struct EvictionResult: Sendable, Equatable {
        public let evicted: Int
        public let bytesFreed: Int64
        /// Whether free space was below `criticalFreeBytes`, so the pass aimed
        /// at half the ceiling. Set whether or not anything was evicted: it
        /// says what the pass was trying for, not what it took.
        public var ceilingHalved: Bool = false
    }

    /// Every file the cache holds, oldest first by when it was made: originals
    /// by `cached_at`, resized copies by `created_at`, in one order.
    ///
    /// **Changed 2026-09-16.** Until then this ranked photographs by the latest
    /// of `last_shown_at`, `cached_at` and `added_at` — when anybody last had a
    /// reason to keep one — and the store held originals only. When the resize
    /// cache came back and shared the ceiling, Syd: "oldest file first, whether
    /// or not is an original", and asked whether an original shown a minute ago
    /// should still count as new, "when the file was made." So an original
    /// fetched a month ago and shown a minute ago is among the first to go.
    ///
    /// The 2026-09-06 fault this replaced — a card fetched seconds ago evicted
    /// before it was shown, because showing outranked landing — cannot recur
    /// under this order, since landing is now the only thing that counts. See
    /// `CacheTests.freshlyFetchedOutlivesRecentlyShown`.
    ///
    /// Ties go to the original, then by row id, so the order is stable.
    func evictionOrder() throws -> [PhotoStore.EvictionCandidate] {
        let originals = try database.all(
            "SELECT uuid, COALESCE(cached_at, 0) AS made, id FROM photo WHERE cached_at IS NOT NULL;"
        ) {
            (made: try $0.int64("made"), kind: 0, id: try $0.int64("id"),
             candidate: PhotoStore.EvictionCandidate.original(try $0.string("uuid")))
        }
        let copies = try database.all(
            "SELECT id, file, byte_size, created_at FROM resized;"
        ) {
            (made: try $0.int64("created_at"), kind: 1, id: try $0.int64("id"),
             candidate: PhotoStore.EvictionCandidate.copy(
                file: try $0.string("file"), bytes: try $0.int64("byte_size")))
        }
        return (originals + copies)
            .sorted { ($0.made, $0.kind, $0.id) < ($1.made, $1.kind, $1.id) }
            .map(\.candidate)
    }

    /// Least-recently-wanted first, bounded by bytes, one entry per photograph.
    ///
    /// **The ordering comes from the database, not from the files.** The rank is
    /// `evictionOrder()` above — `COALESCE(last_shown_at, cached_at, added_at)`
    /// — so this is oldest-reason-to-keep first rather than the FIFO by write
    /// time the header used to claim. `PhotoStore.Entry` carried a `createdAt`
    /// for that FIFO and nothing ever read it; it went on 2026-09-06.
    ///
    /// **It was over `(photo, resolution)` entries until 2026-09-06**, with the
    /// original evicted before its own renderings so a display-ready fraction of
    /// the bytes survived. One photograph is one file now, so there is no
    /// within-photograph order left to decide.
    ///
    /// A shuffle shows every photograph about equally often, so there is no hot
    /// set for anything cleverer to protect. Anything queued is skipped
    /// regardless of age, which covers the only entries with a known imminent
    /// reader.
    ///
    /// **Where it would start to matter** is a library whose working set exceeds
    /// the ceiling, so photographs are evicted before their turn comes round.
    /// That needs a library several times the size of any tested here, and it is
    /// the point at which this wants measuring rather than reasoning about.
    @discardableResult
    public func evictIfNeeded() async throws -> EvictionResult {
        // **Nothing is evicted before the disk has been walked.** At launch the
        // index is what the database claimed (`prepareFromDatabase`), and a
        // total nobody has checked is not one to delete photographs over.
        guard await store.hasWalked else {
            Log.cache.info("eviction waits for the first cache walk")
            return EvictionResult(evicted: 0, bytesFreed: 0, ceilingHalved: false)
        }
        guard await store.claimEviction() else {
            Log.cache.info("an eviction is already running; this one is skipped")
            return EvictionResult(evicted: 0, bytesFreed: 0, ceilingHalved: false)
        }
        defer { await store.endEviction() }

        // The disk-space guard evicts ahead of the ceiling, folded in as a lower
        // effective ceiling rather than as a second pass.
        let free = freeBytesOnVolume()
        let halved = free < settings.criticalFreeBytes
        if halved {
            Log.cache.notice(
                "evicting ahead of the ceiling: only \(free, privacy: .public) bytes free"
            )
            await store.setByteCeiling(max(0, settings.byteCeiling / 2))
        } else {
            await store.setByteCeiling(settings.byteCeiling)
        }

        // Copies share the ceiling with originals. Syd, 2026-09-16: "no,
        // combined limit."
        let copyBytes = try ResizedCopies.byteCount(in: database)
        let held = await store.totals.byteCount
        let ceiling = await store.byteCeiling
        guard held + copyBytes > ceiling else {
            return EvictionResult(evicted: 0, bytesFreed: 0, ceilingHalved: halved)
        }
        // A file with no row — a copy written and never recorded, which takes
        // dying between the two — is cleared at the first eviction after launch.
        if copySweep.claim() {
            try ResizedCopies.removeUnclaimedFiles(root: store.root, database: database)
        }

        let result = await store.evictIfNeeded(inOrder: try evictionOrder(), copyBytes: copyBytes)
        // An evicted original is no longer servable, so it leaves the deck's
        // pool in the same breath as it leaves the disk.
        try releaseResidency(ofPhotos: result.releasedOriginals)
        // An evicted copy's row goes after its file, a hundred at a time.
        for page in result.evictedCopies.chunked(into: Self.copyRowPage) {
            try await database.transaction(.immediate) {
                for file in page {
                    try database.run("DELETE FROM resized WHERE file = :file;", ["file": .text(file)])
                }
            }
        }
        return EvictionResult(
            evicted: result.evicted, bytesFreed: result.bytesFreed, ceilingHalved: halved)
    }

    /// Evicts if the file just written took the cache over its ceiling.
    ///
    /// **After every file written to the cache, and at no other time.** Syd,
    /// 2026-09-16: "you should evict when you know the total size is too big,
    /// and not any other time", then "ditch the timer", and "So, after you
    /// write any file to the cache, run evict()." Until then eviction ran on
    /// the agent's maintenance heartbeat, every `maintenanceIntervalSeconds`.
    /// The files written are an original a fetch adopts and a resized copy
    /// kept (`keep`). Between the write and this, the cache is over its
    /// ceiling — "you might temporarily exceed the space, but that's fine".
    ///
    /// A failure is logged and the write stands: the file is the point, and
    /// the next write evicts again.
    /// Runs the eviction here, on the thread that wrote the file.
    ///
    /// Only when there is no `PhotoStore.evictionBell` to ring: `pgr_ctl`, and
    /// the tests, where the write and its eviction being one act is what makes
    /// them legible.
    private func evictNow() async {
        do {
            let result = try await evictIfNeeded()
            if result.evicted > 0 { evicted(result) }
        } catch {
            Log.cache.error(kind: nil, "eviction after a write failed: \(error)")
        }
    }

    /// Whoever evicts for this cache, if it is not this cache.
    ///
    /// **Rung, never awaited.** Syd, 2026-09-17: "you only need to use `await
    /// …` when you need the result, or you need the side effect", and "async
    /// code is all about getting stuff out of the way." Nothing a write does
    /// next reads anything eviction sets, so the writer rings and carries on —
    /// "you might temporarily exceed the space, but that's fine".
    ///
    /// **Why a bell rather than a `Task`.** Eviction reads `resized`, builds the
    /// order and writes in a transaction, all on this cache's `Database`, and
    /// one connection belongs to one isolation domain. Detaching the work means
    /// detaching a connection with it, which is what the agent's `Evictor`
    /// owns.
    private nonisolated var evictionBell: (@Sendable () -> Void)? { store.evictionBell }

    /// Saves a resized copy, and evicts if it took the cache over its ceiling.
    ///
    /// Nil, and nothing evicted, when the photograph went while it was being
    /// resized; see `ResizedCopies.save`.
    @discardableResult
    public func keep(
        _ rendered: PhotoRenderer.Rendered, photoID: Int64, photoUUID: String,
        boxWidth: Int, boxHeight: Int, now: Date = Date()
    ) async throws -> ResizedCopies.Copy? {
        let copy = try ResizedCopies.save(
            rendered, photoID: photoID, photoUUID: photoUUID, boxWidth: boxWidth,
            boxHeight: boxHeight, root: root, database: database, now: now)
        if copy != nil {
            if let ring = evictionBell { ring() } else { await evictNow() }
        }
        return copy
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

    public func costOfClearing(_ scope: ClearScope) async throws -> ClearCost {
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
            guard await store.contains(photo: row.uuid) else { continue }
            if row.storage == "materialized" { refetch += 1 }
        }
        // The byte total comes from the index, since the database no longer
        // records what is held.
        let claimed = Set(rows.map(\.uuid))
        bytes = await store.byteCount(ofPhotos: claimed)

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
    public func clear(_ scope: ClearScope) async throws -> ClearResult {
        let (predicate, bindings) = Self.scopePredicate(scope)
        let uuids = try database.all(
            """
            SELECT p.uuid FROM photo p JOIN source s ON s.id = p.source_id
             WHERE \(predicate);
            """,
            bindings
        ) { try $0.string("uuid") }

        // The resized copies in scope go too: clearing is asking for the
        // cache's bytes back, and copies are the cache's bytes. Read before
        // anything is deleted, so `.everything`, which removes the whole root,
        // still counts them.
        let copies = try database.all(
            """
            SELECT r.file AS file, r.byte_size AS bytes
              FROM resized r JOIN photo p ON p.id = r.photo_id JOIN source s ON s.id = p.source_id
             WHERE \(predicate);
            """,
            bindings
        ) { (file: try $0.string("file"), bytes: try $0.int64("bytes")) }

        var freed: Int64 = copies.reduce(0) { $0 + $1.bytes }
        var cleared = 0
        if scope != .everything {
            ResizedCopies.removeFiles(copies.map(\.file), root: store.root)
        }
        try await database.transaction(.immediate) {
            try database.run(
                """
                DELETE FROM resized
                 WHERE photo_id IN (SELECT p.id FROM photo p JOIN source s ON s.id = p.source_id
                                     WHERE \(predicate));
                """,
                bindings)
        }

        switch scope {
        case .everything:
            freed += await store.removeAll()
            cleared = uuids.count
        case .source(let sourceID):
            // One directory removal rather than thousands of unlinks, which is
            // the whole reason the layout has that level.
            if let uuid = try sources.source(id: sourceID)?.uuid {
                freed += await store.removeSource(uuid)
            }
            cleared = uuids.count
        case .unavailableSources:
            for uuid in uuids {
                let before = await store.byteCount(ofPhotos: [uuid])
                if before > 0 { cleared += 1 }
                freed += await store.remove(photoUUID: uuid)
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
            try await database.transaction(.immediate) {
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
