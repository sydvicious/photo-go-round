import Console
import Foundation
import PhotoGoRoundKit

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
        filler.configure(
            databasePath: databasePath, cacheRoot: environment.cacheRoot, store: store)
        let filler = self.filler
        let topUp: @Sendable () -> Void = {
            Task { await filler.fill(preferences: environment.preferences) }
        }

        // The queue of pictures to cache. Serving puts photographs on it when
        // their bytes are not local and does not wait; this is what drains it,
        // and its width is the only bound on how many fetches run at once.
        // Read by the fetch itself, which is not an actor and cannot await the
        // queue it was started by.
        let pendingCaches = CacheQueue.Pending()
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
                filler.pendingCaches = { pendingCaches.count }
                let fetched = (try? await filler.cache(photoID: photoID)) ?? false
                if fetched { environment.announce(.cacheChanged) }
                return fetched
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
        let listener = HTTPListener(
            port: servicePort,
            advertising: PictureEndpoint.path,
            onReady: { environment.preferences.publishServicePort($0) }
        ) { await router.route($0) }
        try listener.start()
        defer { listener.stop() }

        // **This process only ever ends by signal** — launchd sends `SIGTERM`,
        // a person types Ctrl-C — so a `defer` is not where the published port
        // can be withdrawn. Without this, every ordinary stop leaves an address
        // behind and `pgr_ctl status` names a port nothing is answering on.
        let shutdown = Self.withdrawPortOnTermination(environment.preferences)
        _ = shutdown

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
        let preferences_ = DarwinNotification.observe(.preferencesChanged, on: .global()) {
            preferencesChanged.raise()
        }

        // Someone at another terminal added a source. Refresh now rather than
        // at the next scheduled pass — five minutes of apparently nothing
        // happening is the wrong first impression, and the doorbell exists
        // precisely so it does not have to be waited out.
        let sourcesChanged = Flag()
        let sources_ = DarwinNotification.observe(.sourcesChanged, on: .global()) {
            sourcesChanged.raise()
        }
        defer {
            preferences_?.cancel()
            sources_?.cancel()
        }

        var lastPreferenceCheck = Date.distantPast
        var lastScan = Date.distantPast
        var lastQueueRefresh = Date.distantPast
        var lastMaintenance = Date.distantPast
        var lastStatus = ""

        repeat {
            let now = Date()

            // Re-read every tick, not only when the doorbell rings. `cfprefsd`
            // batches writes and a notification can be missed entirely, so the
            // poll is the mechanism and the doorbell is what makes it prompt.
            // This is what lets `defaults write` reconfigure a running service
            // with no cooperation from anything.
            let rang = preferencesChanged.lower()
            if rang || now.timeIntervalSince(lastPreferenceCheck) >= 30 {
                preferences.reload()
                preferences = environment.preferences
                lastPreferenceCheck = now
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
            // Not announced. Refreshing promptly when a source changes is what
            // the agent is supposed to do, and saying so every time is a line
            // about routine work. What is worth printing is what the refresh
            // *found*, which it already prints.
            let asked = sourcesChanged.lower()
            if asked || now.timeIntervalSince(lastScan) >= scanInterval.totalSeconds || once {
                try await runRefresh(environment: environment, sources: sources)
                lastScan = now

                // A refresh that changed something announces it, and we observe
                // our own announcements — Darwin notifications carry no sender,
                // so there is no way to tell ours from a terminal's. Left alone
                // that is a self-sustaining cycle: refresh, ring, refresh. It
                // only shows up while a source is genuinely churning, such as a
                // folder mid-copy, where every pass truthfully finds new files
                // and the agent walks the directory continuously.
                //
                // We have just done the work the ring would ask for, so drop it.
                // A terminal that rang during the refresh loses its promptness
                // and waits for the next scheduled scan, which is the cheaper
                // of the two mistakes.
                _ = sourcesChanged.lower()
            }

            // Topping up and sweeping answer to different pressures, so they
            // run on separate clocks.
            if asked
                || now.timeIntervalSince(lastQueueRefresh) >= preferences.queueRefreshInterval.totalSeconds
                || once
            {
                try await maintainQueue(
                    sources: sources, preferences: preferences, environment: environment)
                lastQueueRefresh = now
            }

            if now.timeIntervalSince(lastMaintenance) >= preferences.maintenanceInterval.totalSeconds
                || once
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
                lastMaintenance = now
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
    private func runRefresh(environment: MacHostEnvironment, sources: SourceStore) async throws {
        let due = try sources.enabled()
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

        if reported.sawAnything() { environment.announce(.sourcesChanged) }
    }

    static let maximumConcurrentRefreshes = 4


    /// The queue maintainer, which always runs.
    ///
    /// Its whole job is: if the queue is below nominal, ask every source for a
    /// picture. Sources still working on the previous request ignore it, so
    /// there is nothing to track and nothing to reconcile — and because each can
    /// contribute at most one entry per round, the queue overshoots nominal by
    /// at most the number of sources.
    /// The queue maintainer, which always runs.
    ///
    /// Asks every source for a picture whenever the queue is below nominal, and
    /// **keeps asking as each answer lands** rather than firing a fixed number
    /// and waiting for the next tick. That distinction is the difference between
    /// filling at the rate providers can manage and filling at whatever rate the
    /// timer happens to have: a folder of referenced photos costs nothing to
    /// produce from, so it should fill a thousand-entry queue in about a second,
    /// not in twenty minutes.
    ///
    /// A source still at its concurrency limit ignores the request, so this
    /// cannot outrun what the providers are willing to do. A source that answers
    /// "nothing" is left alone until the next round, which is what stops an
    /// exhausted library spinning.
    /// The queue maintainer, which always runs.
    private func maintainQueue(
        sources: SourceStore,
        preferences: Preferences,
        environment: MacHostEnvironment
    ) async throws {


        // The heartbeat, for when nothing is serving. Serving is what normally
        // notices the queue is short; with no consumer there is nothing to
        // notice it, so the loop asks on its own schedule.
        await filler.fill(preferences: preferences)
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
        case .dropped, .cacheFailed: Console.alert(event.line)
        case .serving, .cached: Console.event(event.line)
        default: Console.note(event.line)
        }
        event.report()
    }

    static func bytes(_ count: Int64) -> String {
        // `.byteCount` renders zero as "Zero kB", which reads as a bug.
        count == 0 ? "0 bytes" : count.formatted(.byteCount(style: .file))
    }
}

/// Keeps asking sources for pictures while the queue is short.
///
/// The distinction that matters is **asking again as each answer lands**, rather
/// than firing a fixed number per timer tick and waiting for the next one. That
/// is the difference between filling at the rate the providers can manage and
/// filling at whatever rate the timer happens to have — a folder of referenced
/// photos costs nothing to produce from, so it should fill a thousand-entry
/// queue in about a second rather than in twenty minutes.
///
/// Two things stop it running away, and neither needs a counter here. A source
/// already at its concurrency limit ignores the request, so this cannot outrun
/// what a provider is willing to do. And a source that answers "nothing" is
/// dropped for the rest of the round, which is what keeps an exhausted library
/// from spinning.
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

    func configure(databasePath: String, cacheRoot: URL, store: PhotoStore) {
        lock.lock()
        defer { lock.unlock() }
        self.databasePath = databasePath
        self.cacheRoot = cacheRoot
        self.store = store
    }

    private var store: PhotoStore?

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
    private func makeFiller(nominalSize: Int) -> QueueFiller {
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
        lock.lock()
        let bytes = store
        let report = self.log
        lock.unlock()
        let built = QueueFiller(
            isShort: { gauge.isShort(nominalSize: sizes.queueSize) },
            produce: {
                guard let database = try? Database(path: path) else { return false }
                let store = SourceStore(database: database)
                var dealer = PhotoCache(
                    database: database, root: root, settings: sizes.cacheSettings,
                    sources: store, queueSize: sizes.queueSize, store: bytes)
                dealer.log = report
                return (try? dealer.deal(settings: sizes.deckSettings)) ?? false
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

        func isShort(nominalSize: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let database else { return false }
            return (try? PhotoQueue(database: database, nominalSize: nominalSize).needsTopUp())
                == true
        }
    }

    @discardableResult
    func fill(preferences: Preferences) async -> QueueFiller.Round {
        let filler = makeFiller(nominalSize: preferences.queueSize)
        sizes?.update(preferences)

        return await filler.fill()
    }
}

/// Collects what the concurrent refresh tasks have to say, so their output does
/// not interleave into nonsense.
final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private var anything = false

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
        lock.lock()
        anything = true
        lock.unlock()
        switch change {
        case .added(let id): Console.change("+", id, .green, suffix: "source \(source)")
        case .removed(let id): Console.change("-", id, .red, suffix: "source \(source)")
        }
    }

    /// Reports the *transition*, not the state.
    ///
    /// Unavailability persists — a folder that is gone is gone at every refresh
    /// — so printing it each time turns one fact into a line every few seconds,
    /// and announcing it each time was worse than noisy: the agent observes its
    /// own `.sourcesChanged`, so a source that stayed unavailable rang a
    /// doorbell that scheduled the refresh that rang it again. That is the loop
    /// behind two identical lines three seconds apart.
    ///
    /// `wasAvailable` is the row as it stood before this refresh, which is all
    /// the edge detection needs.
    func finish(_ result: ScanResult, wasAvailable: Bool, took: Duration = .zero) {
        let lost = result.sourceUnavailable && wasAvailable
        let returned = !result.sourceUnavailable && !wasAvailable

        lock.lock()
        if !result.isEmpty || lost || returned { anything = true }
        lock.unlock()

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

    func sawAnything() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return anything
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
