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
    var recursive: Bool
    var tick: Duration
    var once: Bool
    /// Development convenience. Production takes this from preferences, where
    /// it can be changed without restarting the agent.
    var scanIntervalOverride: Duration?
    var servicePort: UInt16

    /// Filling is policy and lives in the kit; what stays here is the two facts
    /// it needs — is the queue short, and produce one picture — each of which
    /// wants its own database connection.
    private let filler = FillerBox()

    func run() async throws {
        try environment.prepare()

        let database = try Database(path: environment.databaseURL.path(percentEncoded: false))
        try Migrator.migrate(database)

        let sources = SourceStore(database: database)
        let deck = Deck(database: database)
        var preferences = environment.preferences

        let cache = PhotoCache(
            database: database,
            root: environment.cacheRoot,
            settings: preferences.cacheSettings,
            sources: sources,
            deck: deck,
            queueSize: preferences.queueSize
        )
        try cache.prepare()

        // The service is the interface: clients ask for a picture and are handed
        // the bytes, and never open the database or the cache themselves.
        //
        // **Serving is what notices the queue has run short**, and therefore what
        // asks for more. Without this the queue only ever refilled on the
        // maintenance tick, so a consumer drawing faster than that tick drained it
        // and got *no photos available* while the library sat there full.
        // A source already at its concurrency limit drops the request on the
        // floor, so calling this on every served picture cannot outrun what the
        // providers are willing to do.
        let databasePath = environment.databaseURL.path(percentEncoded: false)
        filler.configure(databasePath: databasePath, cacheRoot: environment.cacheRoot)
        let filler = self.filler
        let topUp: @Sendable () -> Void = {
            Task { await filler.fill(preferences: environment.preferences) }
        }

        let endpoint = PictureEndpoint(
            databasePath: databasePath,
            cacheRoot: environment.cacheRoot,
            preferences: preferences,
            queueRanShort: topUp
        )
        let listener = HTTPListener(port: servicePort) { await endpoint.route($0) }
        try listener.start()
        defer { listener.stop() }

        Console.banner(
            """
            database   \(environment.databaseURL.path(percentEncoded: false))
            cache      \(environment.cacheRoot.path(percentEncoded: false))
            roots from \(environment.origin.rawValue)
            cache cap  \(preferences.cacheSettings.photoCap) photos, \
            ceiling \(preferences.cacheSettings.byteCeiling / CacheSettings.gigabyte) GB
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
        let reconciled = try sources.reconcile(with: preferences.sources)
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
                let changes = try sources.reconcile(with: preferences.sources)
                if !changes.isEmpty {
                    Console.event(
                        "sources changed in preferences: +\(changes.added) -\(changes.removed) ~\(changes.changed)")
                    sourcesChanged.raise()
                }
                if rang { Console.event("preferences re-read") }
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
                        deck: deck
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
                    queueSize: preferences.queueSize
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
                    let store = SourceStore(database: database)
                    let result = await store.refresh(source) { change in
                        reported.change(change, source: source.id)
                    }
                    reported.finish(result, wasAvailable: source.available)
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


        // The pump keeps asking as each answer lands. What stops it is a source
        // that has nothing left to offer, which is answered once and remembered
        // for the round — so a library smaller than the queue's target does not
        // spin, it simply stops early. An earlier version paced this on the
        // maintenance tick instead, which starved a small library the moment
        // anything drew from it: fifty photos against a thousand-entry queue
        // meant one picture every five seconds however fast the queue drained.
        await filler.fill(preferences: preferences)
    }

    private func runMaintenance(
        cache: PhotoCache,
        deck: Deck,
        preferences: Preferences,
        environment: MacHostEnvironment
    ) async throws {
        let lost = try cache.verifyResidency()
        if lost > 0 {
            Console.event("\(lost) cache entries had lost their bytes")
        }

        let orphans = try cache.sweepOrphans()
        if orphans.files > 0 {
            Console.event(
                "swept \(orphans.files) orphaned cache files, freeing \(Self.bytes(orphans.bytes))")
        }

        let eviction = try cache.evictIfNeeded()
        if eviction.evicted > 0 {
            Console.event(
                "evicted \(eviction.evicted) photos, freed \(Self.bytes(eviction.bytesFreed))"
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
            \(status.residentCount)/\(status.cap) cached · \(status.referencedCount) referenced · \
            \(Self.bytes(status.bytesOnDisk)) on disk
            """
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

    func configure(databasePath: String, cacheRoot: URL) {
        lock.lock()
        defer { lock.unlock() }
        self.databasePath = databasePath
        self.cacheRoot = cacheRoot
    }

    private func paths() -> (database: String, cache: URL) {
        lock.lock()
        defer { lock.unlock() }
        return (databasePath, cacheRoot)
    }

    /// One connection for the gauge, serialised, because `needsTopUp` is a COUNT
    /// asked once per lane per iteration and opening a connection each time would
    /// cost more than the answer. Producing gets its own connection per ask, since
    /// it is doing real I/O anyway and a `Database` belongs to one isolation domain.
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
        let built = QueueFiller(
            isShort: { gauge.isShort(nominalSize: sizes.queueSize) },
            produce: { sourceID in
                guard let database = try? Database(path: path) else { return false }
                let store = SourceStore(database: database)
                let producer = PhotoCache(
                    database: database, root: root, settings: sizes.cacheSettings,
                    sources: store, queueSize: sizes.queueSize)
                return (try? await producer.produce(
                    forSource: sourceID, settings: sizes.deckSettings)) ?? false
            })
        lock.lock()
        filler = built
        self.sizes = sizes
        lock.unlock()
        return built
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

        let (path, _) = paths()
        guard let database = try? Database(path: path),
            let enabled = try? SourceStore(database: database).enabled()
        else { return .alreadyRunning }

        return await filler.fill(
            sources: enabled.map(\.id), concurrency: preferences.downloadConcurrency)
    }
}

/// Collects what the concurrent refresh tasks have to say, so their output does
/// not interleave into nonsense.
final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private var anything = false

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
    func finish(_ result: ScanResult, wasAvailable: Bool) {
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
    }

    func sawAnything() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return anything
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
