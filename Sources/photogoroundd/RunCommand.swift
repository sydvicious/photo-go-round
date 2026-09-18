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
        // **Loud when the build is wrong.** A `nonisolated async` function runs
        // on its caller's executor only with this on, and the request path is
        // made of them — so without it every request leaves its lane at the
        // first hop and runs its SQLite on the shared pool, which is what
        // `Lane` exists to prevent. `Package.swift` sets it for the
        // package and the Xcode project for its own targets; this says so if
        // whichever built this agent did not.
        #if !hasFeature(NonisolatedNonsendingByDefault)
            Console.alert(
                "built without NonisolatedNonsendingByDefault: requests will run on the shared pool",
                recording: .kind("launch.requests-on-the-pool"))
        #endif

        // Where a launch's time goes, step by step. See `StartupTimes`.
        var startup = StartupTimes()
        try environment.prepare()
        startup.lap("storage")

        // **Errors are recorded from here on, and in this process only.** Every
        // red line and every error logged with a kind goes into the record the
        // dashboard reads. `pgr_ctl`, the app, and the screensaver log the same
        // kit errors and never start recording, so theirs are logged and kept
        // nowhere else.
        AgentErrors.shared.startRecording()
        Console.recordAlerts { text, kind in AgentErrors.shared.record(kind: kind, text) }
        // The photographs added and removed by source, for the dashboard's
        // photos panel, counted from here on and in this process only.
        LibraryChanges.shared.startRecording()

        let database = try Database(path: environment.databaseURL.path(percentEncoded: false))
        startup.lap("open")
        try Migrator.migrate(database)
        startup.lap("migrate")

        var preferences = environment.preferences

        // One index for the whole process, shared by everything that touches
        // bytes: the endpoint's per-request caches, the producer's, the fetcher's,
        // and the source store — which needs it so that removing a photograph's
        // row removes its bytes in the same breath.
        // **Who is told that the cache was written to.** Rung by whichever
        // thread wrote the file, answered by `Evictor` on a thread of its own;
        // see there. Built before the store because the store carries the ring
        // and the evictor carries the loop.
        let evictionBell = Doorbell()
        let store = PhotoStore(
            root: environment.cacheRoot, byteCeiling: preferences.cacheSettings.byteCeiling,
            evictionBell: { [evictionBell] in evictionBell.ring() })
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
        // **The index is what the database claimed, and the walk follows.**
        // Walking the cache first cost the port 8.9 to 39 seconds after a
        // restart; `Agent Performance Overhaul.md`, Phase 6. Syd: "the agent
        // can ask the database what the cache was the last time it was alive,
        // and can just try to get things out of the cache and return it",
        // "while the cache walk is going on".
        let held = try await cache.prepareFromDatabase()
        startup.lap("index")
        Console.note(
            "cache index from the database: \(held.photos) photographs, \(RunCommand.bytes(held.bytes))")

        // The service is the interface: clients ask for a picture and are handed
        // the bytes, and never open the database or the cache themselves.
        //
        // **Serving is what notices the queue has run short**, and therefore what
        // asks for more. A round already in progress absorbs the next request
        // rather than stacking with it, so calling this on every served picture
        // cannot outrun what the providers are willing to do.
        let databasePath = environment.databaseURL.path(percentEncoded: false)
        filler.configure(
            databasePath: databasePath, cacheRoot: environment.cacheRoot, store: store)
        let filler = self.filler

        // **The queue fetches its own cards.** A card is dealt whether or not
        // its bytes are here, and every deal that puts a cold card on the queue
        // kicks the fetcher, which walks the queue head first and downloads
        // what is missing, `downloadConcurrency` at a time. Nothing draws at
        // random and nothing counts credits: what gets fetched is what was
        // dealt, in the order it will be shown. See the plan's *Deal over
        // everything, and the queue fetches its own cards*.
        //
        // One bench for the process. A source that stops answering is left
        // alone for a while, and the bench is what bounds work that never
        // returns — see `FetchDeadline`, which deliberately has no cap of its
        // own.
        let bench = SourceBench()

        // What the dashboard counts — pictures served, cache lookups on both
        // sides, evictions — from here to exit. Made before the fetcher, which
        // reports what became of each fetch.
        let tally = LaunchTally()
        // **Eviction follows every file written to the cache**, wherever it was
        // written — a fetch's original, or a resized copy on the resizer's
        // thread — so what it took is said from one place. Until 2026-09-16 it
        // ran on the maintenance heartbeat; Syd: "ditch the timer", and "after
        // you write any file to the cache, run evict()". See
        // `PhotoCache.evictAfterWriting()`.
        let evicted: @Sendable (PhotoCache.EvictionResult) -> Void = { eviction in
            tally.record(eviction)
            Console.event(Self.evictedLine(eviction))
            environment.announce(.cacheChanged)
        }
        let evictor = Evictor(
            bell: evictionBell, databasePath: databasePath, root: environment.cacheRoot,
            settings: preferences.cacheSettings, store: store, report: evicted)
        let evicting = Task { await evictor.run() }
        defer {
            evictor.stop()
            evicting.cancel()
        }

        // Rebuilt per use rather than shared: a `Database` belongs to one
        // isolation domain, and these run on whichever lane reaches them.
        let cacheForFetch: @Sendable () -> PhotoCache? = {
            guard let database = try? Database(path: databasePath) else { return nil }
            var cache = PhotoCache(
                database: database, root: environment.cacheRoot,
                settings: environment.preferences.cacheSettings,
                sources: SourceStore(database: database, bytes: store),
                queueSize: environment.preferences.queueSize,
                store: store)
            cache.log = Self.speak
            cache.bench = bench
            cache.evicted = evicted
            return cache
        }

        let fetcher = QueueFetcher(
            concurrency: preferences.downloadConcurrency,
            next: { after in
                guard let cache = cacheForFetch() else { return .blocked }
                return await cache.nextQueuedToFetch(after: after)
            },
            fetch: { card, limit in
                guard let cache = cacheForFetch() else { return .failed }
                // Said before the wait, not after it. See `QueueEvent.caching`.
                Self.speak(.caching(photo: card.spokenName, source: card.sourceID, within: limit))
                // **The lane comes back whatever the provider does.** The fetch
                // is let go of rather than waited for: a read blocked waiting
                // for an iCloud file to materialise answers neither cancellation
                // nor this deadline, and a structured child would be awaited at
                // scope exit — which is the wait this exists to escape.
                // What the fetch did, written inside the deadline's work and
                // read after it. An actor since 2026-09-17; Syd: "I flatout
                // don't want NSLocks".
                let note = FetchNote()
                let answered = await FetchDeadline.run(
                    within: limit,
                    work: {
                        guard let worker = cacheForFetch() else {
                            await note.failed("the library could not be opened to fetch it")
                            return
                        }
                        let answer = await worker.fetch(card)
                        switch answer {
                        case .landed: await note.landed()
                        case .failed(let because): await note.failed(because)
                        }
                        // Whatever happened, the claim must not outlive the
                        // work: a photograph left claimed is sidelined for the
                        // whole timeout for no reason.
                        worker.finishFetch(card, landed: answer.didLand)
                    },
                    whenAbandoned: {
                        Log.cache.notice(
                            "fetch for photo \(card.id, privacy: .public) returned after it was given up on"
                        )
                    })

                guard answered else {
                    // **A card that did not answer leaves the queue.** Its
                    // source is told off by the bench; the photograph itself
                    // goes back into the deck's contention. Should the abandoned
                    // work land later, the bytes are kept and the next deal of
                    // this photograph finds them here.
                    cache.fetchTimedOut(card, after: limit)
                    cache.dropUnfetched(card, because: "its fetch did not answer in \(limit)")
                    tally.record(fetch: .timedOut)
                    return .timedOut
                }
                guard await note.didLand else {
                    // **Told to the bench, the same as a timeout is.** Which of
                    // the two bounds noticed says nothing about the source; a
                    // fetch that produced no bytes is what the bench counts.
                    cache.fetchFailed(card)
                    cache.dropUnfetched(card, because: "its fetch failed")
                    tally.record(fetch: .failed)
                    Self.recordFetchFailure(
                        card, because: await note.reason ?? "it gave no reason")
                    return .failed
                }
                environment.announce(.cacheChanged)
                tally.record(fetch: .fetched)
                return .fetched
            },
            log: { Console.event($0) }
        )

        // **A picture reached somebody: top the deck up, and fetch what the
        // top-up dealt.** The two are one event, so they are rung together —
        // and the kick follows the fill rather than running beside it, because
        // a fetcher kicked before the deal has landed finds nothing to do.
        let topUp: @Sendable () -> Void = {
            Task {
                let round = await filler.servedOne(preferences: environment.preferences)
                if round.produced > 0 { await fetcher.kick() }
            }
        }

        filler.reporting(to: Self.speak)
        // The fetch side of the dashboard's cache lookups, counted as cards are
        // dealt. Before any fill: the filler is built once and keeps its hook.
        filler.countingDealLookups { tally.record($0) }

        let endpoint = PictureEndpoint(
            databasePath: databasePath,
            cacheRoot: environment.cacheRoot,
            preferences: preferences,
            store: store,
            queueRanShort: topUp,
            // **An empty answer refills the deck.** The heartbeat would
            // eventually do it, but it runs behind the refresh — so a source
            // removed while a slow share is being walked leaves the window blank
            // for the length of that walk. The filler has its own connection on
            // its own thread, so this does not wait for the loop.
            deckCameUpEmpty: {
                Task {
                    let round = await filler.topUpIfShort(preferences: environment.preferences)
                    if round.produced > 0 { await fetcher.kick() }
                }
            },
            // A request waiting on a cold head card asks for the fetcher; the
            // kick is absorbed if a round is already on it.
            ensureFetching: { Task { await fetcher.kick() } },
            bench: bench,
            speak: Self.speak,
            tally: tally,
            evicted: evicted
        )
        // Sources are managed over the same listener, because a client cannot
        // meaningfully write preferences and should not open the database. The
        // endpoint writes preferences on its behalf, which rings `.sourcesChanged`
        // — and this loop is already listening for it, so an added folder is
        // scanned within a tick rather than at the next scheduled pass.
        // **One catalog for the agent's lifetime.** Counting the library costs
        // about half a minute of round trips, and it is paid once by whoever
        // opens a picker first — a catalog rebuilt per request would pay it
        // again on every poll and never finish.
        // **Bounded, and one library for both.** A PhotoKit call that never
        // returns is what a wedged `photolibraryd` looks like from here, and an
        // agent that waits on one stops answering the app — see
        // `BoundedPhotoLibrary`. Sharing the instance is incidental; sharing the
        // bounds is the point.
        let photos = BoundedPhotoLibrary(SystemPhotoLibrary())
        let catalog = PhotosCollectionCatalog(library: photos)
        let router = Router(
            pictures: endpoint,
            sources: SourceEndpoint(
                databasePath: databasePath, preferences: preferences, bytes: store),
            photos: PhotosEndpoint(catalog: catalog, library: photos),
            dashboard: DashboardEndpoint(
                databasePath: databasePath, cacheRoot: environment.cacheRoot,
                preferences: preferences, store: store, tally: tally, evicted: evicted)
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
                // Pasteable, on both branches: a scratch agent has a dashboard
                // too, and it is the one nobody can find by the published port.
                Console.event("dashboard at http://localhost:\(port)\(DashboardEndpoint.pagePath)")
                Log.deck.notice(
                    "dashboard at http://localhost:\(port, privacy: .public)\(DashboardEndpoint.pagePath, privacy: .public)")
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
        if !once {
            startup.lap("wiring")
            try listener.start()
            startup.lap("listen")
            startup.report(as: "listening")
            // **The walk, behind the open port.** At launch and every
            // `cacheWalkInterval` after it — Syd, 2026-09-17: "its own
            // interval, default an hour", "but definitly at launch". On its own
            // thread, since it is thousands of `stat` calls; see `CacheWalk`.
            let walker = Lane("cache-walk", qos: .utility)
            let walkRoot = environment.cacheRoot
            Task {
                while !Task.isCancelled {
                    await walker.run {
                        await Self.walkCache(
                            databasePath: databasePath, root: walkRoot,
                            settings: environment.preferences.cacheSettings, store: store)
                    }
                    try? await Task.sleep(for: environment.preferences.cacheWalkInterval)
                }
            }
        }
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
        //
        // **Except when the storage has been relocated and the preferences have
        // not**, which is a trap rather than a mistake. `--container` and
        // `--database` move where the library lives; neither moves the
        // preference domain, so `--container /scratch --add-folder /scratch`
        // reads as an isolated run and quietly edits the real source list. A
        // scratch folder written that way outlives the run, the directory it
        // names, and any memory of how it got there — found in the App Group
        // domain on 2026-08-26, months after the session that put it there.
        //
        // Refused rather than ignored, with the fix named: `PGR_PREFS_SUITE`
        // moves the third thing.
        // **Asked of the environment this run resolved, not of the process.**
        // A caller that injects `PGR_PREFS_SUITE` rather than exporting it — a
        // test, or anything embedding the agent — is just as isolated, and
        // reading `ProcessInfo` would refuse it.
        if !foldersToAdd.isEmpty,
            !Self.mayWriteFoldersThrough(
                origin: environment.origin, prefsPinned: environment.preferencesArePinned)
        {
            Console.alert(
                "refusing --add-folder: storage is relocated but preferences are not, so this "
                    + "would write \(foldersToAdd.count) folder(s) into the real source list",
                recording: .kind("launch.add-folder-refused"))
            Console.note(
                "set PGR_PREFS_SUITE to isolate preferences too, or drop --container/--database")
            throw OptionsError.addFolderWouldEditRealPreferences
        }

        for folder in foldersToAdd {
            let path = folder.url.standardizedFileURL.path(percentEncoded: false)
            if preferences.addSource(.folder(path, recursive: folder.recursive)) {
                Console.recovered("added source: \(path)")
            }
        }

        // Cards left on the queue by the last run may still want their bytes.
        // In the background, because a slow first fetch must not hold up the
        // loop that serves pictures.
        Task { await fetcher.kick() }

        // Preferences are the truth; the source table is a projection of them.
        // A database that was deleted rebuilds itself here.
        let reconciled = try await sources.reconcile(with: preferences)
        startup.lap("sources")
        startup.report(as: "ready")
        if !reconciled.isEmpty {
            Console.event(
                "sources reconciled with preferences: +\(reconciled.added) -\(reconciled.removed) ~\(reconciled.changed)")
        }

        describeSources(try sources.all(), pool: sources.pool)

        // Raw `defaults write` must work from any terminal with no cooperation,
        // and cross-process UserDefaults observation is unreliable — so the
        // doorbell is what tells us to re-read.
        // The callback yields into an `AsyncStream`; a task of its own turns
        // each ring into state the loop reads at the top of a tick. See
        // `Doorbell`.
        let preferencesBell = Doorbell()
        let preferencesChanged = Rang()
        let preferences_ = environment.doorbells.observe(.preferencesChanged, on: .global()) {
            preferencesBell.ring()
        }
        let preferencesHeard = Task {
            for await _ in preferencesBell.pulls { await preferencesChanged.heard() }
        }

        // Someone at another terminal added a source. Refresh now rather than
        // at the next scheduled pass — five minutes of apparently nothing
        // happening is the wrong first impression, and the doorbell exists
        // precisely so it does not have to be waited out.
        let sourcesBell = Doorbell()
        let sourcesChanged = Rang()
        let sources_ = environment.doorbells.observe(.sourcesChanged, on: .global()) {
            sourcesBell.ring()
        }
        let sourcesHeard = Task {
            for await _ in sourcesBell.pulls { await sourcesChanged.heard() }
        }
        defer {
            preferences_?.cancel()
            sources_?.cancel()
            preferencesBell.finish()
            sourcesBell.finish()
            preferencesHeard.cancel()
            sourcesHeard.cancel()
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
        /// One refresh pass at a time. Distinct from `Self.refreshing`, which
        /// admits one walk per *source*: this is one walk of the whole list.
        let refreshPass = Latch()
        /// Raised by a pass when it finishes, so the loop — which owns the
        /// heartbeat — can stamp it on the next tick rather than the pass
        /// reaching across for it.
        let refreshFinished = Rang()

        repeat {
            let now = Date()
            let order = Heartbeat.order(launching: launching)
            launching = false

            // Re-read every tick, not only when the doorbell rings. `cfprefsd`
            // batches writes and a notification can be missed entirely, so the
            // poll is the mechanism and the doorbell is what makes it prompt.
            // This is what lets `defaults write` reconfigure a running service
            // with no cooperation from anything.
            let rang = await preferencesChanged.take()
            if heartbeat.isDue(.preferences, every: .seconds(30), at: now, forced: rang) {
                preferences.reload()
                preferences = environment.preferences
                heartbeat.finished(.preferences, at: Date())
                let changes = try await sources.reconcile(with: preferences)
                if !changes.isEmpty {
                    Self.speak(
                        .configurationChanged(
                            what:
                                "sources changed: +\(changes.added) -\(changes.removed) ~\(changes.changed)"
                                + (changes.bytesFreed > 0
                                    ? ", freed \(Self.bytes(changes.bytesFreed))" : "")))
                    await sourcesChanged.heard()
                }
                if rang { Self.speak(.configurationChanged(what: "preferences re-read")) }
            }

            // A pass that finished since the last tick. Stamped here because
            // the heartbeat belongs to this loop and to nothing else.
            if await refreshFinished.take() {
                heartbeat.finished(.refresh, at: Date())
            }

            let scanInterval = scanIntervalOverride ?? preferences.scanInterval
            let asked = await sourcesChanged.take()

            // **Run in the order this tick calls for.** At launch that is the
            // queue first, so a restart with a warm cache serves immediately
            // rather than after the slowest network share has been walked.
            for work in order {
                switch work {
                case .preferences:
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
                    // **The loop does not wait for the walk.** Every source
                    // was walked inside the tick, so nothing else in the loop
                    // ran meanwhile — no eviction, no preference re-read. That read as solved when the
                    // `walk_seen` diff took a 5,093-photograph source from
                    // eighty-five minutes to 1.1 seconds; a network share of
                    // 4,510 put it back to **30.9 seconds** on 2026-08-26.
                    //
                    // A one-pass run still waits, because it has nothing else
                    // to do and must not exit before it has scanned.
                    let firstPass = heartbeat.lastFinished(.refresh) == nil
                    if once {
                        await Self.runRefresh(
                            databasePath: databasePath, bytes: store, localFirst: firstPass)
                        heartbeat.finished(.refresh, at: Date())
                    } else if await refreshPass.tryEnter() {
                        // **`isDue` keeps saying yes while this runs**, because
                        // it reads the last *finish*. The gate is what stops a
                        // tick starting a second pass over the first.
                        Task {
                            await Self.runRefresh(
                                databasePath: databasePath, bytes: store, localFirst: firstPass)
                            await refreshPass.leave()
                            await refreshFinished.heard()
                        }
                    }
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
                        sources: sources, preferences: preferences, environment: environment,
                        fetcher: fetcher)
                    heartbeat.finished(.queue, at: Date())
                }
            }


            let status = try await describe(
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
    /// **Static, and takes nothing that is not `Sendable`.** The pass runs off
    /// the loop now, which means it is captured by a detached task — and a
    /// `SourceStore` holds a `Database`, which belongs to one isolation domain
    /// and cannot cross. It builds its own from the path, exactly as each
    /// per-source task below already did.
    static func runRefresh(
        databasePath: String, bytes: PhotoStore, localFirst: Bool = false
    ) async {
        guard let database = try? Database(path: databasePath) else { return }
        let sources = SourceStore(database: database, bytes: bytes)
        let reported = Reporter()
        if let all = try? sources.all() { reported.skipped(all.filter { !$0.enabled }) }
        guard let enabled = try? sources.enabled() else { return }
        let due = localFirst ? Self.localFirst(enabled) : enabled
        guard !due.isEmpty else { return }

        let cap = min(Self.maximumConcurrentRefreshes, due.count)

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
                    guard await Self.refreshing.tryEnter(source: source.id) else {
                        Log.sources.notice(
                            "source \(source.id, privacy: .public) is already being refreshed; dropped"
                        )
                        return
                    }
                    // **A lane per source, off the shared pool.** Syd,
                    // 2026-09-16: "the agent should run the refresh and
                    // downloads in separate actors". A walk is blocking file
                    // I/O and synchronous SQLite for as long as the share
                    // takes, and on the pool that is what left requests with
                    // no thread to start on. Released explicitly rather than
                    // by `defer`, since giving the gate back is now `await`.
                    let lane = Lane("refresh-\(source.id)", qos: .utility)
                    await lane.run {
                        // Its own connection: a `Database` belongs to one
                        // isolation domain, and WAL is what makes several of
                        // them safe.
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
                    await Self.refreshing.leave(source: source.id)
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

    /// Whether `--add-folder` may edit the preference domain this run is reading.
    ///
    /// Lifted out so the rule can be asserted without standing up an agent. See
    /// the call site for what it prevents.
    static func mayWriteFoldersThrough(origin: ContainerOrigin, prefsPinned: Bool) -> Bool {
        switch origin {
        // The storage is where the preferences say it is, so writing to them is
        // configuring the library the run belongs to.
        case .production, .development: true
        // Storage was relocated. Writing through would edit a source list this
        // run is not otherwise using — unless the preferences were moved too.
        case .explicitOverride, .environment: prefsPinned
        }
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
        environment: MacHostEnvironment,
        fetcher: QueueFetcher
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
        let round = await filler.topUpIfShort(preferences: preferences)
        // A one-pass run waits for its fetches; a serving agent lets them run.
        if round.produced > 0 {
            if once { await fetcher.kick() } else { Task { await fetcher.kick() } }
        }
    }

    /// One walk of the cache directory, checking the index against the disk.
    ///
    /// Its own connection: it runs on the walk's own lane, and a `Database`
    /// belongs to one isolation domain. Anything it discards is a file the
    /// database does not claim; anything it misses, the next walk finds.
    private static func walkCache(
        databasePath: String, root: URL, settings: CacheSettings, store: PhotoStore
    ) async {
        let started = ContinuousClock.now
        do {
            let database = try Database(path: databasePath)
            var cache = PhotoCache(
                database: database, root: root, settings: settings,
                sources: SourceStore(database: database, bytes: store), store: store)
            cache.log = Self.speak
            let result = try await cache.walkCache()
            let line =
                "CACHE WALK: \(result.kept) held · \(bytes(result.bytes)) · "
                + "\(result.discarded) discarded · \(StageTimes.milliseconds(ContinuousClock.now - started))"
            Console.note(line)
            Log.cache.notice("\(line, privacy: .public)")
        } catch {
            Console.alert(
                "the cache walk failed: \(error)", recording: .kind("cache.walk-failed"))
        }
    }

    /// The console line for an eviction that took something.
    static func evictedLine(_ eviction: PhotoCache.EvictionResult) -> String {
        "evicted \(eviction.evicted) cache entries, freed \(Self.bytes(eviction.bytesFreed))"
            + (eviction.ceilingHalved
                ? " — free space is below the critical floor, so the ceiling was halved" : "")
    }

    private func describe(cache: PhotoCache, deck: Deck, preferences: Preferences) async throws -> String {
        let status = try await cache.status()
        let stats = try deck.stats(settings: preferences.deckSettings)
        return """
            \(stats.dealablePhotos) in pool · \(status.queued)/\(preferences.queueSize) queued · \
            \(status.residentCount) originals · \
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
        case .dropped:
            Console.alert(event.line, recording: .unrecorded)
            Self.record(event)
        // A failed fetch is recorded by its lane, which alone knows whether
        // anyone was still waiting for it. See `recordFetchFailure`.
        case .serving, .cached, .cacheFailed: Console.event(event.line)
        // Red, and it earns it: this is the failure that hides.
        case .cacheTimedOut:
            Console.alert(event.line, recording: .unrecorded)
            Self.record(event)
        // Red as well: a benched source is why nothing from it is appearing.
        case .sourcePaused:
            Console.alert(event.line, recording: .unrecorded)
            Self.record(event)
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

    /// What the error record files a red queue line under: the kind of event
    /// and its source, which stay put while the photograph and the queue depth
    /// on the line change.
    static func recording(for event: QueueEvent) -> Console.Recording {
        switch event {
        case .dropped(_, let source, _, _):
            .kind(AgentErrors.kind("library.photo-dropped", source: source))
        case .cacheTimedOut(_, let source, _):
            .kind(AgentErrors.kind("cache.timed-out", source: source))
        case .sourcePaused(let source, _):
            .kind(AgentErrors.kind("source.paused", source: source))
        case .cacheFailed(_, let source, _):
            .kind(AgentErrors.kind("cache.fetch-failed", source: source))
        default:
            .byText
        }
    }

    /// How long a queue line keeps its row in the error record.
    ///
    /// **A paused source stands until its pause ends.** It is a condition
    /// rather than an event: nothing is fetched from the source for the whole
    /// of it, and a row gone a minute after the line would say the trouble was
    /// over while it still held. Everything else is an event.
    static func lifetime(for event: QueueEvent, at now: Date) -> AgentErrors.Lifetime {
        if case .sourcePaused(_, let until) = event {
            return .standingUntil(now.addingTimeInterval(until.totalSeconds))
        }
        return .transient
    }

    /// A queue line into the error record, under the kind `recording(for:)`
    /// names and for as long as `lifetime(for:at:)` says.
    static func record(
        _ event: QueueEvent, into errors: AgentErrors = .shared, at now: Date = Date()
    ) {
        let kind: String? =
            switch recording(for: event) {
            case .kind(let kind): kind
            default: nil
            }
        errors.record(kind: kind, event.line, lasting: lifetime(for: event, at: now), at: now)
    }

    /// A fetch that produced no bytes, in the error record under its source and
    /// in the words the fetch gave.
    ///
    /// **Recorded by the lane rather than where the fetch failed**, because only
    /// the lane knows whether anyone was still waiting for the answer. A fetch
    /// given up on is recorded as `cache.timed-out` when its lane lets go; were
    /// its later failure recorded too, one fetch would be two rows. So every
    /// fetch the dashboard counts as `failed` is recorded here, and nothing else.
    static func recordFetchFailure(
        _ card: DeckCard, because reason: String, into errors: AgentErrors = .shared,
        at now: Date = Date()
    ) {
        record(
            .cacheFailed(photo: card.spokenName, source: card.sourceID, because: reason),
            into: errors, at: now)
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
            // A disabled source is red here so it is seen, and is not an error.
            Console.alert(
                line.trimmingCharacters(in: .whitespaces),
                recording: source.available
                    ? .unrecorded : .kind(AgentErrors.kind("source.unavailable", source: source.id)))
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

    func configure(databasePath: String, cacheRoot: URL, store: PhotoStore) {
        lock.lock()
        defer { lock.unlock() }
        self.databasePath = databasePath
        self.cacheRoot = cacheRoot
        self.store = store
    }

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
            Log.deck.error(kind: "deal.no-connection", "could not open the dealing connection at \(path)")
            return QueueFiller(isShort: { false }, produce: { false })
        }
        lock.lock()
        let bytes = store
        let report = self.log
        let lookup = self.dealLookup
        lock.unlock()
        let built = QueueFiller(
            isShort: { gauge.isShort(nominalSize: sizes.queueSize) },
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
                    dealer.dealLookedUp = lookup
                    return try await dealer.deal(settings: sizes.deckSettings)
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

    /// Where dealing says whether each materialized card's original was
    /// already held — the fetch side of the dashboard's cache lookups. Set it
    /// before the first fill: the filler is built once and keeps the hook it
    /// was built with.
    private var dealLookup: @Sendable (DealLookup) -> Void = { _ in }

    func countingDealLookups(_ lookup: @escaping @Sendable (DealLookup) -> Void) {
        lock.lock()
        dealLookup = lookup
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

        /// Short is short. **The whole of this method's history was about
        /// cards that had left the queue to be fetched** — they still counted
        /// as the queue's for pacing, except when the queue was empty, where
        /// counting them said *not short* about a queue with nothing in it and
        /// only a landing fetch could make it false again. Cards do not leave
        /// to be fetched any more: a card is dealt because its bytes are
        /// already here.
        func isShort(nominalSize: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let database else { return false }
            let depth = (try? PhotoQueue(database: database, nominalSize: nominalSize).size()) ?? 0
            return depth < nominalSize
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
        let filler = makeFiller()
        sizes?.update(preferences)
        return await filler.fill()
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
    func topUpIfShort(preferences: Preferences) async -> QueueFiller.Round {
        let filler = makeFiller()
        sizes?.update(preferences)

        let (path, _) = paths()
        guard let database = try? Database(path: path),
            let size = try? PhotoQueue(database: database, nominalSize: preferences.queueSize)
                .size(),
            size < preferences.queueSize
        else { return .alreadyRunning }

        return await filler.fill()
    }
}

/// Narrates the concurrent refresh tasks.
final class Reporter: @unchecked Sendable {

    /// The agent's error record. The shared one in the agent; a test hands in
    /// its own.
    let errors: AgentErrors

    init(errors: AgentErrors = .shared) {
        self.errors = errors
    }

    /// Said before the walk rather than after it.
    ///
    /// **A refresh used to be silent unless something changed**, which was right
    /// while a refresh was half a second against a local folder. Over a network
    /// share with five thousand photographs it is minutes, the loop is inside it
    /// the whole time, and "nothing has happened for four minutes" is
    /// indistinguishable from "the agent has stopped". So it says what it is
    /// about to do, and how long it took.
    /// The disabled sources a pass does not refresh, whose standing conditions
    /// are cleared, since no refresh will report them over.
    ///
    /// **`SourceStore.setEnabled` clears them too, and that is not enough on its
    /// own.** `pgr_ctl` disables a source by reconciling in its own process,
    /// against its own error record; by the time the agent reconciles, the row
    /// is already disabled and the agent never calls `setEnabled` at all.
    func skipped(_ disabled: [Source]) {
        for source in disabled { errors.clearStanding(source: source.id) }
    }

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
    ///
    /// **The error record hears the state, not the transition.** An unavailable
    /// source and an empty one are standing conditions, kept on the dashboard
    /// until they clear (Syd, 2026-09-13) — so each is recorded on every refresh
    /// that finds it and cleared by the first that does not. Recorded on the
    /// transition only, a source already unavailable when the agent launched
    /// would never have appeared.
    func finish(_ result: ScanResult, wasAvailable: Bool, took: Duration = .zero) {
        let lost = result.sourceUnavailable && wasAvailable
        let returned = !result.sourceUnavailable && !wasAvailable
        let unavailable = AgentErrors.kind("source.unavailable", source: result.sourceID)
        let empty = AgentErrors.kind("source.empty", source: result.sourceID)

        if result.sourceUnavailable {
            let line = "source \(result.sourceID) unavailable: \(result.reason ?? "unknown")"
            if lost { Console.alert(line, recording: .unrecorded) }
            errors.record(kind: unavailable, line, lasting: .standing)
        } else {
            if returned { Console.recovered("source \(result.sourceID) is available again") }
            errors.clear(kind: unavailable)
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

        // **A source that scanned clean and found nothing says so.**
        //
        // `+0 -0 =0` is what a healthy scan of an empty folder looks like and
        // also what a scan of four and a half thousand photographs looks like
        // when they are all one directory further down than the source reaches.
        // The two are indistinguishable on the line above, and the second is
        // silent for ever: the source is enabled, available, freshly scanned,
        // and contributes nothing. Found on 2026-08-26 on a network share whose
        // 4,517 photographs were in three subdirectories of a source that was
        // not recursive.
        //
        // Said on every scan rather than on the transition, because the
        // condition is a standing one and the reason somebody is reading the
        // log is to find out why nothing is appearing.
        guard Self.scannedEmpty(result) else {
            // It found photographs, or could not look: either way it is not
            // known to be empty any more.
            errors.clear(kind: empty)
            return
        }
        let line = "source \(result.sourceID) is empty — it scanned cleanly and holds no photographs"
        Console.alert(line, recording: .unrecorded)
        errors.record(kind: empty, line, lasting: .standing)
    }

    /// A scan that reached its source and came back with nothing.
    ///
    /// `added + unchanged` is the population the walk actually saw, so this is
    /// true both for a folder that has always been empty and for one whose
    /// last photograph has just been removed. Unavailable sources are excluded:
    /// they report zero because nothing could be counted, which is a different
    /// fact and is already reported as unavailability.
    static func scannedEmpty(_ result: ScanResult) -> Bool {
        !result.sourceUnavailable && result.added + result.unchanged == 0
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

/// Admits one holder at a time and turns everyone else away.
///
/// `Flag` is raise-and-read, which cannot express *test and set* — two ticks
/// could both see it lowered and both start a pass. This is the smaller thing
/// `QueueFiller` and `QueueFetcher` each build inline for their own rounds.
actor Latch {
    private var held = false

    /// True when the caller now holds it and must `leave`.
    func tryEnter() -> Bool {
        guard !held else { return false }
        held = true
        return true
    }

    func leave() {
        held = false
    }

    var isHeld: Bool {
        return held
    }
}

/// What one fetch did, written inside `FetchDeadline.run`'s work and read once
/// it has answered.
///
/// **An actor since 2026-09-17**, where a `Flag` and a `Note` behind `NSLock`s
/// used to be. Syd: "I flatout don't want NSLocks", and "I don't mind
/// everything being async; I prefer it". Both sides are already `async`, so
/// nothing new suspends.
actor FetchNote {
    private var did = false
    private var because: String?

    func landed() { did = true }

    func failed(_ words: String) { because = words }

    var didLand: Bool { did }

    /// Why it did not land, when something said.
    var reason: String? { because }
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
actor RefreshGate {
    private var walking: Set<Int64> = []

    /// True when the caller now owns this source's walk and must `leave` it.
    func tryEnter(source: Int64) -> Bool {
        walking.insert(source).inserted
    }

    func leave(source: Int64) {
        walking.remove(source)
    }

    func isWalking(source: Int64) -> Bool {
        walking.contains(source)
    }

    /// For a status line that would otherwise leave a four-minute silence
    /// unexplained, and for tests.
    var count: Int { walking.count }
}
