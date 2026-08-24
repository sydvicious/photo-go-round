import Foundation

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

    /// Puts a photograph on the queue of pictures to cache.
    ///
    /// Serving calls this and does not wait for it. The host owns the queue and
    /// whatever drains it, because how many fetches run at once is scheduling
    /// and scheduling is not the kit's business.
    public var wantsCaching: @Sendable (Int64) -> Void = { _ in }

    /// How many photographs are waiting to be fetched, so a `CACHE:` line
    /// written from here says the same thing as one written by the queue.
    public var pendingCaches: @Sendable () -> Int = { 0 }

    /// How long one request may spend walking the queue before it answers
    /// nothing.
    ///
    /// **A budget for the request, not for the work.** Walking is nearly all
    /// existence checks against sources, and against a network volume a queue of
    /// a few hundred mostly-uncached cards takes a minute — by which time the
    /// client has given up and the window is still showing the last photograph.
    /// Two seconds is past what a person notices as instant and well short of
    /// what any client waits for, and nothing is lost by stopping: every card
    /// walked has been handed to the cache queue, so the next request begins
    /// warmer than this one did.
    public static let walkBudget = Duration.seconds(2)

    /// How many cards past the one being served are asked for in advance.
    ///
    /// **Warming and serving used to share one walk, and that was the bug.** A
    /// card's bytes were only ever asked for when the walk *stepped over* it, so
    /// the amount of warming a request did was however far it happened to travel
    /// before finding something servable. Add a source whose photographs are
    /// always servable — anything referenced — and the walk stops on the first
    /// card, warming falls to nothing, and the sources that actually need
    /// fetching never fill. Measured on a real library: cache requests dropped
    /// from about 130 per five minutes to 19 the moment such a source came back.
    ///
    /// So looking ahead is deliberate rather than opportunistic. It reads the
    /// queue without consuming it, costs one in-memory lookup per card, and asks
    /// for nothing it already holds.
    ///
    /// Bounded, and the bound is not about this machine: against a folder the
    /// cost of asking is a fetch from a disk you own, but the Photos and Google
    /// providers will make it a request against somebody else's service, where a
    /// request that asks for a queue's worth of originals at once is rude.
    public static let lookAheadDepth = 20

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
    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
        // A crash mid-download leaves its temporary in `.staging`, and the
        // index walk never looks inside — the name is neither `.original` nor
        // a size — so launch is the only place it can be reclaimed.
        try? FileManager.default.removeItem(at: root.appending(path: Self.stagingDirectory))
        try indexCache()
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
    public func indexCache() throws -> (kept: Int, discarded: Int, bytes: Int64) {
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
        return store.rebuild(photos: owners)
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
        // The claim exists so two fillers do not pick the same card. It ends
        // here whatever the outcome, because a card left claimed by a path
        // nobody thought about waits out the timeout for no reason at all.
        defer { try? deck.releaseClaim(photoID: candidate.id) }

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
            log(.cacheUnnecessary(photo: card.externalID, source: card.sourceID, pending: pendingCaches()))
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
            log(.cacheFailed(photo: card.externalID, source: card.sourceID, because: "\(error)", pending: pendingCaches()))
            try await handleFailedDownload(card, source: source, provider: provider)
            return false
        }
        do {
            try store.adopt(
                fileAt: temporary, for: originalKey,
                sourceUUID: card.sourceUUID, pathExtension: extension_, now: now)
            try database.run(
                "UPDATE photo SET byte_size = :size WHERE id = :id;",
                ["size": .int(file.byteSize), "id": .int(card.id)]
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            log(.cacheFailed(photo: card.externalID, source: card.sourceID, because: "\(error)", pending: pendingCaches()))
            Log.cache.error(
                "photo \(card.id, privacy: .public) was fetched and could not be kept: \(String(describing: error), privacy: .public)"
            )
            return false
        }

        // **It goes back on the queue.** Reinstated 2026-08-24 after a night of
        // running without it.
        //
        // The argument for leaving it out was that the queue's composition
        // should be the deck's alone, and that topping it up in the order
        // fetches *complete* lets the fastest source drift into owning it. That
        // reasoning was sound and the conclusion was still wrong, because it
        // assumed the photograph would come round again soon enough. It does
        // not: dealing draws uniformly from the whole library, so a photograph
        // whose bytes were just paid for has a one-in-the-library-size chance of
        // being the next card. **The cache never catches up** — every fetch
        // improves the next draw by one over fourteen thousand, and the cards
        // actually dealt are almost all cold. Measured overnight: two sources of
        // 5,899 photographs went from 123 pictures shown in an hour to zero for
        // five hours straight, while a source needing no fetch took every turn.
        //
        // The drift the old reasoning feared is handled at the other end
        // instead: dealing is now tied to pictures actually *served* rather than
        // to cards consumed, so the deck advances at the rate photographs reach
        // a screen and a skip no longer buys a fresh card. What returns here is
        // the same card that left, not an extra one.
        _ = try? queue.append(photoID: card.id, sourceID: card.sourceID, at: now)
        log(
            .cached(
                photo: card.externalID, source: card.sourceID,
                bytes: store.url(for: originalKey).flatMap {
                    (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                } ?? 0,
                pending: pendingCaches()))
        return true
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
        // cannot do it silently. Where the pixels were read from is worth
        // saying: a referenced photograph is resized straight off the disk it
        // lives on, and this is the only thing the cache ever holds for one.
        log(
            .rendered(
                photo: card.externalID, source: card.sourceID,
                at: "\(size.width)x\(size.height)", bytes: bytes.count,
                from: card.storage == .referenced ? "its file on disk" : "the cached original"))
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

    /// Walks the queue until it finds a picture it can hand over now.
    ///
    /// **A picture that is not cached costs a skip, never a wait.** For each
    /// card: if the bytes are here, that is the picture. If they are not, ask for
    /// them to be fetched, drop the card, and try the next one. If the whole
    /// queue goes by, answer nothing — it will populate soon enough.
    ///
    /// **Every picture is checked against its source in the moment before it is
    /// returned**, including one we hold our own copy of. That is the guarantee:
    /// a photo the user deleted is never shown again, not even in the minutes
    /// before a refresh would have noticed.
    ///
    /// `fitting` is the box the caller is about to draw into, and naming it is
    /// what lets an **evicted original with a surviving rendering** still be
    /// served — a client asking again at a size already held never needs the
    /// original back. Nil asks for the original, which is what `curl` with no `w`
    /// and `h` wants.
    public func serve(
        to consumerID: Int64? = nil,
        fitting box: PhotoStore.Size? = nil,
        now: Date = Date(),
        within budget: Duration = PhotoCache.walkBudget
    ) async throws -> ServedPhoto? {
        // Two bounds, and both are needed.
        //
        // **Cards**: one cycle of the queue and no more. Every card taken is
        // either served, dropped, or handed to the cache queue, so the walk
        // cannot see the same one twice — but the queue is also being appended
        // to behind us, and without a bound a request could chase its own tail.
        //
        // **Time**: a cycle is cheap when the cards are local and is not when
        // they are not. Every uncached card costs an existence check against its
        // source, so a queue of a few hundred on a network volume can take a
        // minute to walk — and a minute-long GET is a client that has given up
        // and a window sitting on a stale photograph. Answering nothing is the
        // better answer: the cards walked so far have all been asked for, so the
        // work is banked and the next request starts warmer.
        var walked = 0
        let cycle = try queue.size()
        let started = ContinuousClock.now

        while walked < cycle {
            // **Before taking a card, not after.** Serving pops the card off the
            // queue, so a walk that took one and then abandoned it on the
            // deadline would consume a card for nothing.
            //
            // The first card is exempt, so a walk always tries at least one.
            // Answering "no photo" without looking at a single card would turn a
            // slow moment into a blank screen.
            if walked > 0, ContinuousClock.now - started >= budget {
                log(.nothingToShow(walked: walked, because: "out of time"))
                return nil
            }
            guard let card = try queue.serve(at: now) else { break }
            walked += 1

            // Neither guard below is a photograph that has *gone*, so neither
            // deletes anything. A missing source row is only reachable as a race
            // — foreign keys are on, so removing a source has already taken its
            // photographs and their queue entries — and a missing provider is a
            // Photos album in a build that cannot enumerate one, where deleting
            // the rows would destroy a library on a downgrade.
            guard let source = try sources.source(id: card.sourceID),
                let provider = sources.provider(for: source.kind)
            else {
                log(.skipped(photo: card.externalID, source: card.sourceID, because: "no provider for its source", queued: depth()))
                continue
            }

            // **Do we hold bytes? — asked first, because it is nearly free.**
            //
            // The rendering is looked at before the original because it is the
            // cheaper answer *and* because it may be the only one left: an
            // original can be evicted while a rendering of it survives, and
            // skipping the photograph then would be refusing to send bytes we
            // are holding in exactly the shape the client asked for.
            let held = box.flatMap {
                store.url(for: PhotoStore.Key(photoUUID: card.uuid, size: $0))
            }
            guard let url = try held ?? residentURL(forPhoto: card.id) else {
                // Not here. Somebody else fetches it; this request moves on. The
                // card leaves the queue and comes back when the bytes do.
                //
                // **And the source is never asked about it.** Confirming a
                // photograph costs a stat against wherever its source lives —
                // most of a second on a network volume — and buys nothing here,
                // because the card is being skipped whatever the answer.
                wantCached(card)
                continue
            }

            // **Is it still there? — asked last, and only about the one card
            // that is going out.** This is the guarantee: a photograph the user
            // deleted is never shown again, not even one we hold our own copy
            // of. It is a promise about what is *displayed*, so it belongs to
            // the card being displayed and to no other.
            var unconfirmed: String?
            switch await provider.existence(of: card.externalID, in: source) {
            case .absent:
                log(.dropped(photo: card.externalID, source: card.sourceID, because: "gone from a source that is right there", queued: depth()))
                try self.remove(card.id)
                continue

            case .unknown(let reason):
                // The photograph could not be confirmed, so the question moves
                // up to the source. **Offline and gone are opposite answers**:
                // one keeps everything and serves the copy we hold, the other
                // means these photographs are never coming back, and their rows
                // and cached bytes are worth nothing.
                if case .gone(let why) = await provider.availability(of: source) {
                    log(.dropped(photo: card.externalID, source: card.sourceID, because: "its source is \(why)", queued: depth()))
                    try self.remove(card.id)
                    continue
                }
                // Merely offline, and we are holding a copy — which is the
                // situation the copy exists for. It goes out, with the doubt
                // recorded on the line rather than left unsaid.
                unconfirmed = reason

            case .present:
                break
            }

            // Says which bytes are going out. Without it a kept resize has no
            // matching line for the moment it is *used*, and whether the
            // renderings are earning their disk is unanswerable from a console.
            log(
                .serving(
                    photo: card.externalID, source: card.sourceID,
                    rendering: held != nil, unconfirmed: unconfirmed, queued: depth()))
            lookAhead()
            let seq = try deck.markShown(photoID: card.id, now: now)
            if let consumerID { try? deck.touch(consumerID: consumerID, at: now) }
            // The deck moved, so anything mirroring its position — a diagnostic
            // panel, another surface's idea of what is next — should go and look.
            DarwinNotification.post(.deckAdvanced)
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

        log(.nothingToShow(walked: walked, because: "out of cards"))
        return nil
    }

    /// How many cards are queued right now.
    ///
    /// Asked at every point either queue changes size, because a depth that
    /// moves without saying so leaves the reader inferring it — and both queues
    /// move on almost every request. A `COUNT` against an indexed table of a few
    /// hundred rows, on a path that already opened a database connection.
    private func depth() -> Int { (try? queue.size()) ?? 0 }

    /// Asks for the bytes of the cards sitting behind the one just served.
    ///
    /// **Reads the queue, never consumes it.** These cards keep their places and
    /// their turn; all that happens is that their bytes are requested now rather
    /// than whenever a walk happens to step over them. A card whose fetch has
    /// not finished by the time its turn comes is skipped exactly as before —
    /// looking ahead makes that less likely, and promises nothing.
    private func lookAhead() {
        guard let cards = try? queue.peek(Self.lookAheadDepth), !cards.isEmpty else { return }
        var asked = 0
        for card in cards where card.storage == .materialized {
            // The same in-memory lookup serving does, and the same reason it is
            // safe to do in bulk: it costs a local stat, not a word to a source.
            guard store.url(for: PhotoStore.Key(photoUUID: card.uuid)) == nil else { continue }
            wantsCaching(card.id)
            asked += 1
        }
        log(.lookedAhead(cards: cards.count, asked: asked, pending: pendingCaches()))
    }

    /// Asks for a photograph's bytes, if asking can achieve anything.
    ///
    /// A referenced photograph is never copied — it *is* the file on its source —
    /// so there is nothing to fetch and nothing to ask for. Everything else goes
    /// on the queue of pictures to cache, which decides when it comes off
    /// whether it is still worth doing.
    private func wantCached(_ card: DeckCard) {
        guard card.storage == .materialized else {
            log(.skipped(photo: card.externalID, source: card.sourceID, because: "its file cannot be reached", queued: depth()))
            return
        }
        log(.skipped(photo: card.externalID, source: card.sourceID, because: "not cached yet", queued: depth()))
        wantsCaching(card.id)
    }

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
        /// Entries over the ceiling that were left alone because their
        /// photograph is queued.
        public let protectedFromEviction: Int
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

        let result = store.evictIfNeeded(protecting: try queuedPhotoUUIDs())
        return EvictionResult(
            evicted: result.evicted,
            bytesFreed: result.bytesFreed,
            protectedFromEviction: result.protected
        )
    }

    /// Photographs waiting in the queue, which eviction must not touch whatever
    /// their age — they are about to be shown.
    func queuedPhotoUUIDs() throws -> Set<String> {
        Set(
            try database.all(
                "SELECT p.uuid FROM queue q JOIN photo p ON p.id = q.photo_id;"
            ) { try $0.string("uuid") })
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
