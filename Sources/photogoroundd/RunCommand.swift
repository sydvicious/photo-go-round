import Console
import Foundation
import PhotoGoRoundKit
import PhotoGoRoundAgentAPI

/// The agent loop.
///
/// The kit contains no timers and no opinion about when it is called; this is
/// the thing that calls it. Everything here is scheduling — deciding *when* to
/// refresh, top up the queue, and sweep — and nothing here is policy.
///
/// Photos on the boot volume are referenced in place and never copied; anything
/// on a removable, network, or ubiquitous volume is materialized under the cache
/// root.
struct RunCommand {
    var environment: MacHostEnvironment
    var foldersToAdd: [(url: URL, recursive: Bool)]
    var tick: Duration
    var once: Bool
    /// Development convenience. Production takes this from preferences, where
    /// it can be changed without restarting the agent.
    var scanIntervalOverride: Duration?
    var servicePort: UInt16?
    /// Whether to announce the bound port. False for a scratch agent — see
    /// `Options.publishesPort`.
    var publishesPort = true

    /// Filling is policy and lives in the kit; what stays here is the two facts
    /// it needs — is the queue short, and produce one picture — each of which
    /// wants its own database connection.
    private let filler = FillerBox()

    func run() async throws {
        try environment.prepare()

        let database = try Database(path: environment.databaseURL.path(percentEncoded: false))
        try Migrator.migrate(database)

        var preferences = environment.preferences

        // One index for the whole process, shared by everything that touches
        // bytes: the endpoint's per-request caches, the producer's, maintenance,
        // and the source store — which needs it so that removing a photograph's
        // row removes its bytes in the same breath.
        let store = PhotoStore(
            root: environment.cacheRoot, byteCeiling: preferences.cacheSettings.byteCeiling)
        let sources = SourceStore(database: database, bytes: store)
        let deck = Deck(database: database)
        let cache = PhotoCache(
            database: database,
            root: environment.cacheRoot,
            settings: preferences.cacheSettings,
            sources: sources,
            deck: deck,
            queueSize: preferences.queueSize,
            store: store
        )
        try cache.prepare()

        // The service is the interface: clients ask for a picture and are handed
        // the bytes, and never open the database or the cache themselves.
        //
        // **Serving is what notices the queue has run short**, and therefore what
        // asks for more. A round already in progress absorbs the next request
        // rather than stacking with it, so calling this on every served picture
        // cannot outrun what the providers are willing to do.
        let databasePath = environment.databaseURL.path(percentEncoded: false)
        // Created here rather than beside the cache queue below, because the
        // gauge needs it too: a card out being fetched still counts as the
        // queue's when deciding whether to deal.
        let pendingCaches = CacheQueue.Pending()
        filler.configure(
            databasePath: databasePath, cacheRoot: environment.cacheRoot, store: store,
            pending: pendingCaches)
        let filler = self.filler
        let topUp: @Sendable () -> Void = {
            Task { await filler.servedOne(preferences: environment.preferences) }
        }

        // The queue of pictures to cache. Serving puts photographs on it when
        // their bytes are not local and does not wait; this is what drains it,
        // and its width is the only bound on how many fetches run at once.
        // Read by the fetch itself, which is not an actor and cannot await the
        // queue it was started by, and by the gauge above.
        let cacheQueue = CacheQueue(
            concurrency: preferences.downloadConcurrency,
            fetch: { photoID in
                guard let database = try? Database(path: databasePath) else { return false }
                var filler = PhotoCache(
                    database: database, root: environment.cacheRoot,
                    settings: environment.preferences.cacheSettings,
                    sources: SourceStore(database: database, bytes: store),
                    store: store)
                filler.log = Self.speak
                // The backlog, not the total: this closure logs from inside
                // the fetch, before the queue lets the finishing item go.
                filler.pendingCaches = { pendingCaches.backlog }
                let fetched = (try? await filler.cache(photoID: photoID)) ?? false
                if fetched { environment.announce(.cacheChanged) }
                return fetched
            },
            // **Per photograph, because the providers differ by an order of
            // magnitude.** One scalar query rather than a cached table: this
            // runs twice per fetch, against a database the process already has
            // open elsewhere, and a stale answer here would be a bound applied
            // to the wrong kind of source.
            deadline: { photoID in
                guard let database = try? Database(path: databasePath),
                    let kind = try? database.scalarString(
                        """
                        SELECT s.kind FROM photo p
                          JOIN source s ON s.id = p.source_id
                         WHERE p.id = :id;
                        """,
                        ["id": .int(photoID)])
                else { return CacheSettings.fileFetchLimit }
                return SourceKind(kind).isFileBacked
                    ? CacheSettings.fileFetchLimit : CacheSettings.libraryFetchLimit
            },
            // **Put back, not retried.** Whatever was not ready a moment ago is
            // still not ready, and a card left queued would be asked for again
            // on the next look-ahead and hang the next lane the same way. Out
            // of the queue it goes back to being an ordinary undealt
            // photograph, and gets another turn when the shuffle reaches it.
            abandoned: { photoID in
                guard let database = try? Database(path: databasePath) else { return }
                try? database.run(
                    "DELETE FROM queue WHERE photo_id = :id;", ["id": .int(photoID)])
                Log.deck.notice(
                    "fetch timed out for photo \(photoID, privacy: .public); put back in the pool")
            },
            describe: { photoID in
                guard let database = try? Database(path: databasePath),
                    let card = (try? Deck(database: database).card(photoID: photoID)) ?? nil
                else { return ("photo \(photoID)", nil) }
                return (card.externalID, card.sourceID)
            },
            log: Self.speak,
            pending: pendingCaches
        )
        let wantsCaching: @Sendable (Int64) -> Void = { photoID in
            Task { await cacheQueue.request(photoID) }
        }
        filler.reporting(to: Self.speak)

        let endpoint = PictureEndpoint(
            databasePath: databasePath,
            cacheRoot: environment.cacheRoot,
            preferences: preferences,
            store: store,
            queueRanShort: topUp,
            // **What is already on disk, not more of the same.** An empty walk
            // means every card on hand needs bytes that are not here; dealing
            // uniformly would hand back another cold one and the next walk
            // would answer `204` too. This deals from what the cache holds,
            // which is the same preference the launch bridge makes and for the
            // same reason — it was simply fenced behind a launch-only flag.
            queueCameUpEmpty: {
                Task { await filler.dealWhatIsAlreadyHere(preferences: environment.preferences) }
            },
            wantsCaching: wantsCaching,
            speak: Self.speak
        )
        // Sources are managed over the same listener, because a client cannot
        // meaningfully write preferences and should not open the database. The
        // endpoint writes preferences on its behalf, which rings `.sourcesChanged`
        // — and this loop is already listening for it, so an added folder is
        // scanned within a tick rather than at the next scheduled pass.
        let router = Router(
            pictures: endpoint,
            sources: SourceEndpoint(
                databasePath: databasePath, preferences: preferences, bytes: store)
        )
        // Where the service is, written where every local client can find it:
        // a preference domain is a name rather than a path, which is the only
        // thing both ends can locate without being told.
        // **A test agent says nothing, and is therefore followed by nobody.**
        // `servicePort` is written by whichever agent started most recently, so
        // publishing from a scratch run captures the app's window mid-session
        // and serves it from a different library. `--container` does not help:
        // it isolates storage and the preference domain is shared, which is
        // exactly where the port lives.
        let publishes = publishesPort
        let listener = HTTPListener(
            port: servicePort,
            advertising: PictureEndpoint.path,
            onReady: { port in
                guard publishes else {
                    // Nothing can discover it, so say it plainly enough to copy.
                    Console.event("not published — reach this agent at http://localhost:\(port)")
                    Log.deck.notice(
                        "serving on port \(port, privacy: .public), not published")
                    return
                }
                environment.preferences.publishServicePort(port)
            }
        ) { await router.route($0) }
        // A one-pass run configures and fills; it does not serve. Its listener
        // would publish a port that only a signal withdraws, so `--once` would
        // leave a stale address behind — or overwrite a running agent's, since
        // both write the same preference domain.
        if !once { try listener.start() }
        defer {
            listener.stop()
            // The unwind for a thrown error, which no signal covers. Withdraw
            // only an address this run published: another agent may own the
            // key by now — and a run that published nothing has nothing to take
            // back, so it must not touch a key that belongs to somebody else.
            if publishes, environment.preferences.servicePort == listener.boundPort {
                environment.preferences.withdrawServicePort()
            }
        }

        // **A serving run only ever ends by signal** — launchd sends `SIGTERM`,
        // a person types Ctrl-C — so a `defer` is not where the published port
        // can be withdrawn. Without this, every ordinary stop leaves an address
        // behind and `pgr_ctl status` names a port nothing is answering on.
        let shutdown =
            (once || !publishes)
            ? [] : Self.withdrawPortOnTermination(environment.preferences)
        // A resumed `DispatchSourceSignal` stops delivering when released, and
        // ARC may release a local after its last use — which without this is
        // the line above, in an optimized build, leaving SIGTERM and SIGINT
        // ignored outright once the handler installed `SIG_IGN`.
        defer { withExtendedLifetime(shutdown) {} }

        Console.banner(
            """
            database   \(environment.databaseURL.path(percentEncoded: false))
            cache      \(environment.cacheRoot.path(percentEncoded: false))
            roots from \(environment.origin.rawValue)
            cache      ceiling \(preferences.cacheSettings.byteCeiling / CacheSettings.gigabyte) GB
            queue      \(preferences.queueSize) nominal, \(preferences.downloadConcurrency) fetches per source
            window     \(preferences.deckSettings.repeatWindowFraction)
            """
        )

        // Anything named at launch is written through to preferences, so the
        // first run is configured from the outside and every run after that is
        // configured from preferences — without the launcher having to know
        // which case it is in.
        for folder in foldersToAdd {
            let path = folder.url.standardizedFileURL.path(percentEncoded: false)
            if preferences.addSource(.folder(path, recursive: folder.recursive)) {
                Console.recovered("added source: \(path)")
            }
        }

        // Preferences are the truth; the source table is a projection of them.
        // A database that was deleted rebuilds itself here.
        let reconciled = try sources.reconcile(with: preferences)
        if !reconciled.isEmpty {
            Console.event(
                "sources reconciled with preferences: +\(reconciled.added) -\(reconciled.removed) ~\(reconciled.changed)")
        }

        describeSources(try sources.all(), pool: sources.pool)

        // Raw `defaults write` must work from any terminal with no cooperation,
        // and cross-process UserDefaults observation is unreliable — so the
        // doorbell is what tells us to re-read.
        let preferencesChanged = Flag()
        let preferences_ = environment.doorbells.observe(.preferencesChanged, on: .global()) {
            preferencesChanged.raise()
        }

        // Someone at another terminal added a source. Refresh now rather than
        // at the next scheduled pass — five minutes of apparently nothing
        // happening is the wrong first impression, and the doorbell exists
        // precisely so it does not have to be waited out.
        let sourcesChanged = Flag()
        let sources_ = environment.doorbells.observe(.sourcesChanged, on: .global()) {
            sourcesChanged.raise()
        }
        defer {
            preferences_?.cancel()
            sources_?.cancel()
        }

        // The schedule, lifted out so it can be asserted rather than trusted.
        // See `Heartbeat`, and in particular why every job is stamped when it
        // *finishes*.
        var heartbeat = Heartbeat()
        // The first tick seeds the queue before it refreshes anything, so a
        // restart serves from the pool and cache it already has instead of
        // waiting out a network walk. See `Heartbeat.order(launching:)`.
        var launching = true
        var lastStatus = ""

        repeat {
            let now = Date()
            let order = Heartbeat.order(launching: launching)
            launching = false

            // Re-read every tick, not only when the doorbell rings. `cfprefsd`
            // batches writes and a notification can be missed entirely, so the
            // poll is the mechanism and the doorbell is what makes it prompt.
            // This is what lets `defaults write` reconfigure a running service
            // with no cooperation from anything.
            let rang = preferencesChanged.lower()
            if heartbeat.isDue(.preferences, every: .seconds(30), at: now, forced: rang) {
                preferences.reload()
                preferences = environment.preferences
                heartbeat.finished(.preferences, at: Date())
                let changes = try sources.reconcile(with: preferences)
                if !changes.isEmpty {
                    Self.speak(
                        .configurationChanged(
                            what:
                                "sources changed: +\(changes.added) -\(changes.removed) ~\(changes.changed)"
                                + (changes.bytesFreed > 0
                                    ? ", freed \(Self.bytes(changes.bytesFreed))" : "")))
                    sourcesChanged.raise()
                }
                if rang { Self.speak(.configurationChanged(what: "preferences re-read")) }
            }

            let scanInterval = scanIntervalOverride ?? preferences.scanInterval
            let asked = sourcesChanged.lower()

            // **Run in the order this tick calls for.** At launch that is the
            // queue first, so a restart with a warm cache serves immediately
            // rather than after the slowest network share has been walked.
            for work in order {
                switch work {
                case .preferences, .maintenance:
                    continue  // handled around this loop

                case .refresh:
                    // Not announced. Refreshing promptly when a source changes
                    // is what the agent is supposed to do, and saying so every
                    // time is a line about routine work. What is worth printing
                    // is what the refresh *found*, which it already prints.
                    guard
                        heartbeat.isDue(
                            .refresh, every: scanInterval, at: now, forced: asked || once)
                    else { continue }
                    try await runRefresh(
                        environment: environment, sources: sources,
                        localFirst: heartbeat.lastFinished(.refresh) == nil)
                    heartbeat.finished(.refresh, at: Date())
                    // A ring that lands mid-refresh stays raised and is honoured
                    // on the next tick. Every ring on this topic is now somebody
                    // else changing the durable list — a refresh announces
                    // nothing, so there is no self-ring to guard against, and
                    // re-walking a change the refresh already saw is cheaper
                    // than costing a client its promptness.

                case .queue:
                    // Topping up and sweeping answer to different pressures, so
                    // they run on separate clocks.
                    guard
                        heartbeat.isDue(
                            .queue, every: preferences.queueRefreshInterval, at: now,
                            forced: asked || once)
                    else { continue }
                    try await maintainQueue(
                        sources: sources, preferences: preferences, environment: environment)
                    heartbeat.finished(.queue, at: Date())
                }
            }

            if heartbeat.isDue(
                .maintenance, every: preferences.maintenanceInterval, at: now, forced: once)
            {
                try await runMaintenance(
                    cache: PhotoCache(
                        database: database,
                        root: environment.cacheRoot,
                        settings: preferences.cacheSettings,
                        sources: sources,
                        deck: deck,
                        store: store
                    ),
                    deck: deck,
                    preferences: preferences,
                    environment: environment
                )
                heartbeat.finished(.maintenance, at: Date())
            }

            // Built from the preferences in force rather than reused from
            // launch. The one at line 37 exists to create the directory, and it
            // froze the cap it was born with — so raising `cachePhotoCap` from
            // a terminal left the status line reporting the old number
            // indefinitely, which is the one place a person goes to check that
            // the change took.
            let status = try describe(
                cache: PhotoCache(
                    database: database,
                    root: environment.cacheRoot,
                    settings: preferences.cacheSettings,
                    sources: sources,
                    deck: deck,
                    queueSize: preferences.queueSize,
                    // **The process's index, not a fresh one.** Built per tick
                    // to pick up changed preferences, this used to be handed no
                    // store — so it made an empty one, nobody indexed it, and
                    // the line reported nought held while the cache had
                    // gigabytes in it.
                    store: store
                ),
                deck: deck, preferences: preferences)
            if status != lastStatus {
                Console.summary(status)
                lastStatus = status
            }

            if once { break }
            try? await Task.sleep(for: tick)
        } while !Task.isCancelled
    }

    /// One refresh task per source, running concurrently against its own
    /// database connection.
    ///
    /// The kit deliberately has no opinion about this — concurrency is
    /// scheduling, and scheduling is the host's job. What it buys is isolation:
    /// a folder on a dead network share takes its timeout in its own task while
    /// every other source finishes, and none of it touches the queue, which goes
    /// on dealing throughout.
    ///
    /// Capped, because fifty sources should not mean fifty simultaneous
    /// directory walks competing for the same disk.
    private func runRefresh(
        environment: MacHostEnvironment, sources: SourceStore, localFirst: Bool = false
    ) async throws {
        let due = localFirst ? Self.localFirst(try sources.enabled()) : try sources.enabled()
        guard !due.isEmpty else { return }

        let databasePath = environment.databaseURL.path(percentEncoded: false)
        // The refresh is where photographs leave a source, so each task carries
        // the process's byte index and frees what it removes.
        let bytes = sources.bytes
        let cap = min(Self.maximumConcurrentRefreshes, due.count)
        let reported = Reporter()

        await withTaskGroup(of: Void.self) { group in
            var next = due.startIndex
            func schedule() {
                guard next < due.endIndex else { return }
                let source = due[next]
                next = due.index(after: next)
                group.addTask {
                    // **One walk per source, and the guard is per source rather
                    // than per pass.**
                    //
                    // A pass-wide gate would let one folder on a slow share hold
                    // up every other source behind it, which is the opposite of
                    // why these run concurrently at all. What must not overlap is
                    // two walks of the *same* source: they would each open a
                    // connection, find the same photographs, and contend for the
                    // single writer to insert rows the other is already
                    // inserting.
                    //
                    // Dropped rather than queued, because a refresh is
                    // idempotent — the walk already running sees everything the
                    // second would have, so repeating it is pure cost.
                    guard Self.refreshing.tryEnter(source: source.id) else {
                        Log.sources.notice(
                            "source \(source.id, privacy: .public) is already being refreshed; dropped"
                        )
                        return
                    }
                    defer { Self.refreshing.leave(source: source.id) }

                    // Its own connection: a `Database` belongs to one isolation
                    // domain, and WAL is what makes several of them safe.
                    guard let database = try? Database(path: databasePath) else { return }
                    let store = SourceStore(database: database, bytes: bytes)
                    reported.began(source)
                    let started = ContinuousClock.now
                    let result = await store.refresh(source) { change in
                        reported.change(change, source: source.id)
                    }
                    reported.finish(
                        result, wasAvailable: source.available,
                        took: ContinuousClock.now - started)
                }
            }
            for _ in 0..<cap { schedule() }
            while await group.next() != nil { schedule() }
        }
        // What a refresh found is *not* announced. Nothing listens — clients
        // ask over HTTP, and the panel polls — while the agent itself does
        // listen, so announcing here was the agent ringing its own doorbell:
        // a churning source, such as a folder mid-copy, drove a refresh loop
        // at the tick rate for as long as the copy ran. Notifications flow
        // from the outside world to the service, never back.
    }

    /// Sources on the boot volume first, everything else after, each keeping its
    /// order otherwise.
    ///
    /// **For the first pass after launch, and no other.** Walking a local folder
    /// is milliseconds; walking a network share is minutes. In id order the
    /// cheap source is wherever the user happened to add it — on this library it
    /// was last, behind ten network folders, so the one source that could have
    /// put a picture on screen immediately was the last one enumerated and the
    /// agent showed nothing for the length of the pass.
    ///
    /// Only the first pass, because after that there is nothing to be first
    /// *for*: the queue is full, the shuffle is in force, and reordering every
    /// pass would be churn in aid of a problem that only exists at launch.
    ///
    /// Stable within each group, so two local folders keep the order they were
    /// added in and the walk stays predictable.
    static func localFirst(_ sources: [Source]) -> [Source] {
        let ranked = sources.enumerated().map { (offset, source) in
            (offset: offset, local: isOnBootVolume(source), source: source)
        }
        return
            ranked
            .sorted { left, right in
                left.local == right.local ? left.offset < right.offset : left.local
            }
            .map(\.source)
    }

    /// Whether this source's photographs can be read without fetching anything.
    ///
    /// The boot volume and not iCloud. A ubiquitous folder looks local — it is
    /// under `~/Library/Mobile Documents` on an internal disk — and is not:
    /// its contents may be evicted placeholders that have to come down first.
    static func isOnBootVolume(_ source: Source) -> Bool {
        guard source.kind.isFileBacked else { return false }
        let url = URL(filePath: source.locator)
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            return false
        }
        let values = try? url.resourceValues(
            forKeys: [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRemovableKey])
        guard values?.volumeIsRemovable != true else { return false }
        return values?.volumeIsInternal == true
    }

    static let maximumConcurrentRefreshes = 4

    /// Which sources are being walked right now. Process-wide, because what it
    /// protects is process-wide: the one writer on one database.
    static let refreshing = RefreshGate()


    /// The queue maintainer, which always runs — and since dealing moved to
    /// serving, all it does is seed.
    private func maintainQueue(
        sources: SourceStore,
        preferences: Preferences,
        environment: MacHostEnvironment
    ) async throws {


        // **A seed, not a top-up.** Serving is what advances the deck now — one
        // card dealt per picture actually shown — so a heartbeat that filled to
        // nominal would put the churn straight back: cards skipped while their
        // bytes are in flight would each be replaced by a fresh cold card, and
        // the warm one would come back to a queue that had already moved on.
        //
        // The heartbeat still answers the cold start it was written for — with
        // nothing dealt, nothing can be served; with nothing served, nothing is
        // dealt — but it no longer waits for empty. Dealing is independent of
        // anybody asking for a picture, so an idle agent spends its idle time
        // getting the next few ready rather than discovering at the last moment
        // that they need fetching.
        if filler.isBridging() {
            await filler.seedServableFirst(preferences: preferences)
        } else {
            await filler.topUpIfShort(preferences: preferences)
        }
    }

    private func runMaintenance(
        cache: PhotoCache,
        deck: Deck,
        preferences: Preferences,
        environment: MacHostEnvironment
    ) async throws {
        // No residency check and no orphan sweep: the index is built from the
        // filesystem at launch, so it cannot disagree with it, and a file whose
        // UUID nothing claims is deleted there rather than swept later.
        let eviction = try cache.evictIfNeeded()
        if eviction.evicted > 0 {
            Console.event(
                "evicted \(eviction.evicted) cache entries, freed \(Self.bytes(eviction.bytesFreed))"
                    + (eviction.protectedFromEviction > 0
                        ? " (\(eviction.protectedFromEviction) queued)" : "")
            )
            environment.announce(.cacheChanged)
        }
    }

    private func describe(cache: PhotoCache, deck: Deck, preferences: Preferences) throws -> String {
        let status = try cache.status()
        let stats = try deck.stats(settings: preferences.deckSettings)
        return """
            \(stats.dealablePhotos) in pool · \(status.queued)/\(preferences.queueSize) queued · \
            \(status.residentCount) originals · \(status.renderingCount) renderings · \
            \(status.referencedCount) referenced · \(Self.bytes(status.bytesOnDisk)) on disk
            """
    }

    /// Every queue decision, on the console where a person is watching and in
    /// the unified log. The prefixes are what keep two interleaved queues
    /// readable: `SERVE:`, `CACHE:`, `CONFIG:`.
    static let speak: @Sendable (QueueEvent) -> Void = { event in
        switch event {
        // **Red is for the library changing, not for a fetch that could not
        // happen.** A photograph dropped has left the library; a source that
        // went away is reported where sources are. A fetch that failed because
        // its volume is not mounted is the ordinary, expected shape of a
        // library that spans removable storage — it changes nothing, it
        // resolves itself when the drive returns, and colouring it red draws
        // the eye to the one line on the console that needs no attention.
        case .dropped: Console.alert(event.line)
        case .serving, .cached, .cacheFailed: Console.event(event.line)
        // Red, and it earns it: this is the failure that hides.
        case .cacheTimedOut: Console.alert(event.line)
        // Red as well: a benched source is why nothing from it is appearing.
        case .sourcePaused: Console.alert(event.line)
        // **Timestamped, because all of these happen inside the loop.** This
        // was `Console.note` — untimestamped, and documented as being for the
        // banner and for anything printed before the loop starts — so lines
        // were promoted to `event` one at a time as somebody noticed one
        // sorting oddly. `DEAL:`, `asked for`, `fetching`, `looked ahead` and
        // `resized` never were, and a console that timestamps some of a burst
        // and not the rest is unreadable when you come back to it.
        default: Console.event(event.line)
        }
        event.report()
    }

    static func bytes(_ count: Int64) -> String {
        // `.byteCount` renders zero as "Zero kB", which reads as a bug.
        count == 0 ? "0 bytes" : count.formatted(.byteCount(style: .file))
    }
}

/// What the agent is actually pointed at, printed once at startup.
///
/// A count of sources is the one number that is never enough: the whole class
/// of "it is running but showing nothing" turns out, every time, to be a source
/// that is disabled, unavailable, or pointing one directory to the side of the
/// one that was meant. Naming each one makes that visible in the first second
/// rather than after a session of reading the log.
private func describeSources(_ sources: [Source], pool: PhotoPool) {
    guard !sources.isEmpty else {
        Console.note("no sources — add one with --add-folder, or defaults write")
        return
    }

    print()
    Console.note("sources")
    for source in sources {
        let counted = (try? pool.size(forSource: source.id)).map { "\($0) photos" } ?? "uncounted"
        var traits: [String] = []
        if source.recursive == true { traits.append("recursive") }
        if !source.enabled { traits.append("disabled") }
        if !source.available {
            traits.append("unavailable: \(source.unavailableReason ?? "unknown")")
        }
        if source.scannedAt == nil { traits.append("not yet scanned") }
        let suffix = traits.isEmpty ? "" : "  (" + traits.joined(separator: ", ") + ")"
        let line = "  \(source.kind)  \(source.locator)  \(counted)\(suffix)"
        if source.enabled && source.available {
            Console.note(line)
        } else {
            Console.alert(line.trimmingCharacters(in: .whitespaces))
        }
    }
    print()
}

/// Owns the filler and the connections its two closures need.
///
/// A box rather than a bare `QueueFiller` because the paths are not known until
/// `run()` has resolved them, and because the *same* filler has to survive every
/// call — the guard that drops overlapping rounds is on the instance, and a fast
/// consumer starts rounds faster than they finish.
final class FillerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var databasePath = ""
    private var cacheRoot = URL(filePath: "/")
    private var filler: QueueFiller?

    func configure(
        databasePath: String, cacheRoot: URL, store: PhotoStore,
        pending: CacheQueue.Pending? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.databasePath = databasePath
        self.cacheRoot = cacheRoot
        self.store = store
        self.pending = pending
    }

    /// How many photographs are out being fetched. Read by the gauge, because a
    /// card in flight is still the queue's — see `Gauge.isShort`.
    private var pending: CacheQueue.Pending?

    private var store: PhotoStore?

    /// Read in a synchronous method for the same reason `paths()` is: `NSLock`
    /// is unavailable from an async context, and holding one across a suspension
    /// is exactly the bug that restriction exists to prevent.
    private func storeAndLog() -> (PhotoStore?, @Sendable (QueueEvent) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        return (store, log)
    }

    private func paths() -> (database: String, cache: URL) {
        lock.lock()
        defer { lock.unlock() }
        return (databasePath, cacheRoot)
    }

    /// One connection for the gauge, serialised, because `needsTopUp` is a COUNT
    /// asked once per iteration and opening a connection each time would cost
    /// more than the answer. Dealing gets its own, because a `Database` belongs
    /// to one isolation domain.
    ///
    /// **Dealing no longer fetches anything**, so this is the cheap operation it
    /// looks like: a row read and a row written, with no provider involved and
    /// nothing to be slow about. Bytes are fetched by the queue of pictures to
    /// cache, which serving fills as it discovers what it does not hold.
    private func makeFiller() -> QueueFiller {
        lock.lock()
        if let filler {
            lock.unlock()
            return filler
        }
        let path = databasePath
        let root = cacheRoot
        lock.unlock()

        let gauge = Gauge(databasePath: path)
        let sizes = Sizes()
        // One connection for dealing, on a thread of its own, for the life of
        // the process. See `ConfinedDatabase`.
        guard let dealing = try? ConfinedDatabase(path: path, label: "dealing") else {
            // Nothing can be dealt without a connection, and a filler that
            // silently never produces is the failure this whole change exists
            // to stop being invisible.
            Log.deck.error("could not open the dealing connection at \(path, privacy: .public)")
            return QueueFiller(isShort: { false }, produce: { false })
        }
        lock.lock()
        let bytes = store
        let report = self.log
        lock.unlock()
        let pending = self.pending
        let built = QueueFiller(
            isShort: {
                gauge.isShort(nominalSize: sizes.queueSize, inFlight: pending?.count ?? 0)
            },
            produce: { [dealing] in
                // **On the dealing connection's own thread, and errors travel.**
                //
                // This used to open a connection per call and swallow whatever
                // came back with `try?`. Both were wrong in the same direction:
                // dealing is the hot path that takes the write lock, so it is
                // exactly the work that must not occupy a cooperative-pool
                // thread while it waits — and a database that was merely busy
                // arrived at `QueueFiller` as `false`, which reads as a deck
                // with nothing left in it and stops the round.
                try await dealing.run { database in
                    let store = SourceStore(database: database)
                    var dealer = PhotoCache(
                        database: database, root: root, settings: sizes.cacheSettings,
                        sources: store, queueSize: sizes.queueSize, store: bytes)
                    dealer.log = report
                    return try dealer.deal(settings: sizes.deckSettings)
                }
            })
        lock.lock()
        filler = built
        self.sizes = sizes
        lock.unlock()
        return built
    }

    /// Where the queues say what they did. Set by the host so the lines reach a
    /// console; the unified log takes them either way.
    private var log: @Sendable (QueueEvent) -> Void = { $0.report() }

    func reporting(to log: @escaping @Sendable (QueueEvent) -> Void) {
        lock.lock()
        self.log = log
        lock.unlock()
    }

    private var sizes: Sizes?

    /// The current preference values, re-read per round so a change takes effect
    /// at the next fill rather than at the next launch.
    final class Sizes: @unchecked Sendable {
        private let lock = NSLock()
        private var _queueSize = 1000
        private var _cacheSettings = CacheSettings.default
        private var _deckSettings = DeckSettings.default

        var queueSize: Int { lock.lock(); defer { lock.unlock() }; return _queueSize }
        var cacheSettings: CacheSettings { lock.lock(); defer { lock.unlock() }; return _cacheSettings }
        var deckSettings: DeckSettings { lock.lock(); defer { lock.unlock() }; return _deckSettings }

        func update(_ preferences: Preferences) {
            lock.lock()
            _queueSize = preferences.queueSize
            _cacheSettings = preferences.cacheSettings
            _deckSettings = preferences.deckSettings
            lock.unlock()
        }
    }

    final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private let database: Database?

        init(databasePath: String) {
            database = try? Database(path: databasePath)
        }

        /// **Cards out for fetching still count as the queue's.**
        ///
        /// A card skipped while its bytes are fetched has left the table and is
        /// coming back, so the depth alone understates the queue by however many
        /// are in flight. Dealing to cover that dip would replace cards that are
        /// about to return, and the queue would overshoot by exactly the number
        /// of fetches — which is the churn that pacing the deal to serving
        /// exists to remove.
        /// **An empty queue is short whatever is in flight, and that exception is
        /// the whole of this method's history.**
        ///
        /// The accounting above is right about *pacing* and wrong about
        /// starvation, because it reasons as though a card in flight were
        /// interchangeable with one on the queue. It is not: a card in flight
        /// cannot be served. On a cold library over a slow link every card is
        /// skipped for want of bytes, so the depth falls to zero while the
        /// in-flight count climbs to nominal — and `depth + inFlight < nominal`
        /// then answers *not short* about a queue with nothing in it.
        ///
        /// Nothing dealing can do makes that false statement true again. Only a
        /// *fetch* landing does, so the outage lasts as long as the slowest
        /// outstanding download — observed at several minutes over a hotel
        /// network on 2026-08-25, with 2.3 GB of perfectly good cached
        /// photographs that were never dealt because no card could be added to
        /// ask for them.
        ///
        /// So: a queue at zero is always short. Dealing one card at a time from
        /// there is deliberate rather than grudging — each one is tried, and a
        /// photograph whose bytes are already held is served on the spot, which
        /// is how the system walks out of the hole instead of waiting in it.
        func isShort(nominalSize: Int, inFlight: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let database else { return false }
            let depth = (try? PhotoQueue(database: database, nominalSize: nominalSize).size()) ?? 0
            guard depth > 0 else { return true }
            return depth + inFlight < nominalSize
        }
    }

    /// A picture was served, so top the queue back up toward its target.
    ///
    /// **The deck advances at the rate photographs reach a screen**, not at the
    /// rate cards leave the queue. Those are different numbers: a walk consumes
    /// every card it skips as well as the one it shows, and dealing to replace
    /// all of them means a skipped photograph is swapped for a fresh cold one
    /// while its bytes are still being fetched.
    ///
    /// The distinction is kept by the gauge rather than by dealing a fixed
    /// number — cards out for fetching still count as the queue's, so in the
    /// steady state this deals exactly the one that was served. **Dealing
    /// exactly one was the first attempt and it was wrong**: one per picture can
    /// hold a depth but never raise one, so putting `queueSize` up left the
    /// queue stuck at its old size indefinitely while putting it down worked
    /// fine.
    @discardableResult
    func servedOne(preferences: Preferences) async -> QueueFiller.Round {
        // While the bridge is in force this is the path that matters: a `204`
        // rings it, and that happens long before the heartbeat's next tick.
        if isBridging() { return await seedServableFirst(preferences: preferences) }
        let filler = makeFiller()
        sizes?.update(preferences)
        return await filler.fill()
    }

    /// How many immediately-servable cards the startup bridge deals.
    ///
    /// **Deliberately a handful, not a queueful.** Filling all twenty from the
    /// one local folder would put twenty consecutive pictures from a single
    /// source on the screen, which is precisely the opposite of the shuffle
    /// being in force. Three is enough that a request right now succeeds and
    /// that the next couple do too, which is all the time the ordinary cards
    /// need for their fetches to land.
    static let servableBridge = 3

    /// The startup bridge: a few pictures that can be shown *now*, then the
    /// ordinary shuffle.
    ///
    /// **A cold start deals a full queue it cannot serve.** Every card's bytes
    /// are still arriving, so the walk goes through all twenty and answers
    /// `204` — seen on 2026-08-25 as `out of cards, walked 20` against a full
    /// pool and an empty cache. Photographs already here need no fetch:
    /// `referenced` files are read in place, and a warm restart still holds
    /// whatever was cached.
    ///
    /// **It keeps preferring until the queue is actually full**, rather than
    /// firing once. The first tick after a deleted database has an empty pool
    /// and nothing to prefer; what makes the bridge work is that it is still in
    /// force a moment later, once the first sources have been walked.
    /// Deals cards that can be shown without fetching anything, **whatever the
    /// queue's depth**.
    ///
    /// `seedServableFirst` stops once the queue holds a handful, which is right
    /// at launch: the queue is empty and the point is to get a few pictures on
    /// screen. It is exactly wrong when a walk has just come up empty, because
    /// the queue is then *full* — of cards whose bytes are not here. Observed
    /// 2026-08-26: twenty queued cards, eighty-eight originals in the cache,
    /// and every walk answering `nothing to show — out of cards`.
    ///
    /// **It fills the queue, where the bridge deals a handful.** The bridge's
    /// argument against filling is a good one *at launch*: twenty consecutive
    /// pictures from the one local folder that happens to be warm is the
    /// opposite of the shuffle being in force, and the ordinary cards are only
    /// seconds away.
    ///
    /// It does not hold here. This runs when a walk has already come up with
    /// nothing, so the alternative is not a slightly biased queue but a blank
    /// wall — and dealing three meant *empty answer, three pictures, empty
    /// again*, every cycle of which is an interval with nothing on screen.
    /// Measured 2026-08-26 with iCloud Drive wedged: fifteen pictures served
    /// against thirty-two empty answers.
    @discardableResult
    func dealWhatIsAlreadyHere(preferences: Preferences) async -> QueueFiller.Round {
        let (path, root) = paths()
        let (bytes, report) = storeAndLog()
        guard let database = try? Database(path: path), let bytes else { return .alreadyRunning }

        var dealer = PhotoCache(
            database: database, root: root, settings: preferences.cacheSettings,
            sources: SourceStore(database: database),
            queueSize: preferences.queueSize, store: bytes)
        dealer.log = report

        let resident = bytes.residentPhotoUUIDs
        let queue = PhotoQueue(database: database, nominalSize: preferences.queueSize)
        var dealt = 0
        // Bounded by attempts as well as by depth: `dealServable` answering
        // true for a card already queued would otherwise spin.
        for _ in 0..<preferences.queueSize {
            guard ((try? queue.size()) ?? 0) < preferences.queueSize else { break }
            guard
                let more = try? dealer.dealServable(
                    settings: preferences.deckSettings, resident: resident), more
            else { break }
            dealt += 1
        }
        return QueueFiller.Round(produced: dealt, exhausted: dealt == 0, skipped: false)
    }

    @discardableResult
    func seedServableFirst(preferences: Preferences) async -> QueueFiller.Round {
        let (path, root) = paths()
        let (bytes, report) = storeAndLog()

        if let database = try? Database(path: path), let bytes {
            var dealer = PhotoCache(
                database: database, root: root, settings: preferences.cacheSettings,
                sources: SourceStore(database: database),
                queueSize: preferences.queueSize, store: bytes)
            dealer.log = report
            let resident = bytes.residentPhotoUUIDs
            let queue = PhotoQueue(database: database, nominalSize: preferences.queueSize)
            var dealt = 0
            while (try? queue.size()) ?? 0 < min(Self.servableBridge, preferences.queueSize) {
                guard
                    let more = try? dealer.dealServable(
                        settings: preferences.deckSettings, resident: resident), more
                else { break }
                dealt += 1
            }
            if dealt > 0 {
                Console.event(
                    "bridged \(dealt) picture\(dealt == 1 ? "" : "s") that need no fetching")
                Log.deck.notice(
                    "launch bridge queued \(dealt, privacy: .public) immediately servable photographs"
                )
            }
        }

        // The rest of the queue is the ordinary shuffle, so the fetches those
        // cards need start now rather than a tick from now.
        let round = await topUpIfShort(preferences: preferences, force: true)

        // **The shuffle takes over the moment the queue is full.** The bridge is
        // for the gap at launch and for nothing else; left in force it would be
        // a standing bias towards whichever source happens to be local.
        if let database = try? Database(path: path),
            let size = try? PhotoQueue(database: database, nominalSize: preferences.queueSize)
                .size(), size >= preferences.queueSize
        {
            stopBridging()
        }
        return round
    }

    /// True until the queue has been filled once. See `seedServableFirst`.
    private var bridging = true

    func isBridging() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return bridging
    }

    private func stopBridging() {
        lock.lock()
        let was = bridging
        bridging = false
        lock.unlock()
        if was { Log.deck.notice("launch bridge finished; the shuffle is in force") }
    }

    /// Fills a queue that is short of its target, and leaves a full one alone.
    ///
    /// **It used to fill only an *empty* queue**, on the reasoning that serving
    /// tops up a merely short one and a heartbeat doing it as well was churn.
    /// That held while every fetch was a local file read: a queue one card
    /// short stayed short for a couple of seconds.
    ///
    /// It does not hold now. A Photos fetch can take five minutes, and a
    /// top-up that only follows a serve leaves an idle agent doing nothing
    /// with the time it has most of — then makes the first picture after idle
    /// wait on a cold fetch. Dealing has to happen whether or not anybody
    /// asked, which is what this is.
    ///
    /// Still a top-*up*, not a deal-every-tick: a queue at its target is left
    /// alone, because claiming cards nobody is going to see was the churn the
    /// earlier design was right to avoid.
    @discardableResult
    func topUpIfShort(
        preferences: Preferences, force: Bool = false
    ) async -> QueueFiller.Round {
        let filler = makeFiller()
        sizes?.update(preferences)

        if !force {
            let (path, _) = paths()
            guard let database = try? Database(path: path),
                let size = try? PhotoQueue(database: database, nominalSize: preferences.queueSize)
                    .size(),
                size < preferences.queueSize
            else { return .alreadyRunning }
        }

        return await filler.fill()
    }
}

/// Narrates the concurrent refresh tasks.
final class Reporter: @unchecked Sendable {

    /// Said before the walk rather than after it.
    ///
    /// **A refresh used to be silent unless something changed**, which was right
    /// while a refresh was half a second against a local folder. Over a network
    /// share with five thousand photographs it is minutes, the loop is inside it
    /// the whole time, and "nothing has happened for four minutes" is
    /// indistinguishable from "the agent has stopped". So it says what it is
    /// about to do, and how long it took.
    func began(_ source: Source) {
        Console.note("refreshing #\(source.id)  \(source.locator)")
    }

    func change(_ change: ScanChange, source: Int64) {
        switch change {
        // **Cyan rather than green, and across the whole name.**
        //
        // Green against the yellow of a served picture is the one pair that
        // red-green colour blindness cannot separate, and it was invisible to
        // the person these lines are for. Blue against yellow is the axis that
        // survives every common form of it, so that is the axis these use.
        //
        // Hue is the second cue regardless. The first is width: a scan line is
        // coloured end to end and a served picture is not, which reads the same
        // whether or not colour arrives at all — piped to a file, on a monochrome
        // terminal, or by anyone who sees hue differently.
        case .added(let id):
            Console.change("+", id, .cyan, suffix: "source \(source)", whole: true)
        case .removed(let id):
            Console.change("-", id, .red, suffix: "source \(source)", whole: true)
        }
    }

    /// Reports the *transition*, not the state.
    ///
    /// Unavailability persists — a folder that is gone is gone at every refresh
    /// — so printing it each time turns one fact into an alert every few
    /// seconds. `wasAvailable` is the row as it stood before this refresh,
    /// which is all the edge detection needs.
    func finish(_ result: ScanResult, wasAvailable: Bool, took: Duration = .zero) {
        let lost = result.sourceUnavailable && wasAvailable
        let returned = !result.sourceUnavailable && !wasAvailable

        if lost {
            Console.alert("source \(result.sourceID) unavailable: \(result.reason ?? "unknown")")
        } else if returned {
            Console.recovered("source \(result.sourceID) is available again")
        }

        // Always, including when nothing changed — that *is* the news when a
        // walk takes minutes. The duration is the number worth having: it is how
        // a slow source announces itself, and it is what the loop spent not
        // topping up the queue.
        let counts =
            result.sourceUnavailable
            ? "unavailable: \(result.reason ?? "unknown")"
            : "+\(result.added)  -\(result.removed)  =\(result.unchanged)"
        Console.note(
            "refreshed #\(result.sourceID)  \(counts)  in \(Self.seconds(took))"
                + (result.bytesFreed > 0 ? "  (freed \(RunCommand.bytes(result.bytesFreed)))" : ""))
    }

    private static func seconds(_ duration: Duration) -> String {
        duration.totalSeconds.formatted(.number.precision(.fractionLength(1))) + "s"
    }

}

/// Takes the published address back down on the way out.
///
/// The sources are returned rather than discarded because a `DispatchSourceSignal`
/// stops firing the moment nothing holds it, and this one has to outlive the
/// call that made it.
extension RunCommand {

    static func withdrawPortOnTermination(_ preferences: Preferences) -> [DispatchSourceSignal] {
        [SIGTERM, SIGINT].map { number in
            // The default disposition kills the process before the handler ever
            // runs, so it has to be turned off first.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number)
            source.setEventHandler {
                preferences.withdrawServicePort()
                exit(0)
            }
            source.resume()
            return source
        }
    }
}

/// A one-bit cross-thread signal, for the notification callback to hand work
/// back to the loop rather than doing it on whatever queue it arrived on.
final class Flag: @unchecked Sendable {
    private var raised = false
    private let lock = NSLock()

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    /// Reads and clears.
    func lower() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let was = raised
        raised = false
        return was
    }
}

/// Admits one walk per source and turns every other ask for that source away.
///
/// **Per source rather than per pass**, so a folder on a slow network share
/// cannot hold up a local one queued behind it — which is the whole reason the
/// walks run concurrently in the first place.
///
/// Deliberately not a lock a second caller waits on. Waiting would serialise the
/// walks rather than collapse them, which is the same contention arriving a
/// little later; a refresh is idempotent, so the walk already running covers
/// whatever the one being turned away would have found.
final class RefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var walking: Set<Int64> = []

    /// True when the caller now owns this source's walk and must `leave` it.
    func tryEnter(source: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return walking.insert(source).inserted
    }

    func leave(source: Int64) {
        lock.lock()
        walking.remove(source)
        lock.unlock()
    }

    func isWalking(source: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return walking.contains(source)
    }

    /// For a status line that would otherwise leave a four-minute silence
    /// unexplained, and for tests.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return walking.count
    }
}
