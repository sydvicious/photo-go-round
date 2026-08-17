import Foundation
import PhotoGoRoundKit

/// The agent loop.
///
/// The kit contains no timers and no opinion about when it is called; this is
/// the thing that calls it. Everything here is scheduling — deciding *when* to
/// scan, prefetch, evict, and reap — and nothing here is policy.
///
/// Unlike `watch`, this one fills the cache. Photos on the boot volume are still
/// referenced in place and never copied; anything on a removable, network, or
/// ubiquitous volume is materialized under the cache root.
struct RunCommand {
    var environment: MacHostEnvironment
    var foldersToAdd: [URL]
    var recursive: Bool
    var tick: Duration
    var once: Bool

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
            deck: deck
        )
        try cache.prepare()

        Console.banner(
            """
            database   \(environment.databaseURL.path(percentEncoded: false))
            cache      \(environment.cacheRoot.path(percentEncoded: false))
            roots from \(environment.origin.rawValue)
            sources    \(try sources.all().count)
            cache cap  \(preferences.cacheSettings.photoCap) photos, \
            ceiling \(preferences.cacheSettings.byteCeiling / CacheSettings.gigabyte) GB
            window     \(preferences.deckSettings.repeatWindowFraction)
            """
        )

        for folder in foldersToAdd {
            try await ensureFolderSource(folder, in: sources)
        }

        // Raw `defaults write` must work from any terminal with no cooperation,
        // and cross-process UserDefaults observation is unreliable — so the
        // doorbell is what tells us to re-read.
        let preferencesChanged = Flag()
        let observation = DarwinNotification.observe(.preferencesChanged, on: .global()) {
            preferencesChanged.raise()
        }
        defer { observation?.cancel() }

        var lastScan = Date.distantPast
        var lastMaintenance = Date.distantPast
        var lastStatus = ""

        repeat {
            let now = Date()

            if preferencesChanged.lower() {
                preferences.reload()
                preferences = environment.preferences
                Console.event("preferences re-read")
            }

            if now.timeIntervalSince(lastScan) >= preferences.scanInterval.totalSeconds || once {
                try await runScan(sources: sources, environment: environment)
                lastScan = now
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

            let status = try describe(cache: cache, deck: deck, preferences: preferences)
            if status != lastStatus {
                Console.summary(status)
                lastStatus = status
            }

            if once { break }
            try? await Task.sleep(for: tick)
        } while !Task.isCancelled
    }

    private func ensureFolderSource(_ folder: URL, in sources: SourceStore) async throws {
        let path = folder.standardizedFileURL.path(percentEncoded: false)
        if try sources.all().contains(where: { $0.kind == .folder && $0.locator == path }) {
            return
        }
        let source = try sources.add(kind: .folder, locator: path, recursive: recursive)
        Console.recovered("added folder source #\(source.id): \(path)")
    }

    private func runScan(sources: SourceStore, environment: MacHostEnvironment) async throws {
        var changed = false
        let results = try await sources.scanAll { source, change in
            changed = true
            switch change {
            case .added(let id): Console.change("+", id, .green, suffix: "source \(source.id)")
            case .returned(let id): Console.change("~", id, .cyan, suffix: "source \(source.id)")
            case .vanished(let id): Console.change("-", id, .red, suffix: "source \(source.id)")
            }
        }
        for result in results where result.sourceUnavailable {
            Console.alert("source \(result.sourceID) unavailable: \(result.reason ?? "unknown")")
            changed = true
        }
        if changed { environment.announce(.sourcesChanged) }
    }

    private func runMaintenance(
        cache: PhotoCache,
        deck: Deck,
        preferences: Preferences,
        environment: MacHostEnvironment
    ) async throws {
        // Chunked, so there are natural checkpoints to notice a disabled source
        // or a filling disk between batches.
        switch try await cache.fill(maximumChunks: 8) {
        case .materialized(let count, let bytes) where count > 0:
            Console.event("materialized \(count) photos, \(Self.bytes(bytes))")
            environment.announce(.cacheChanged)
        case .pausedForDiskSpace(let free):
            Console.alert("materialization paused: only \(Self.bytes(free)) free")
        case .capReached, .nothingToDo, .materialized:
            break
        }

        let eviction = try cache.evictIfNeeded()
        if eviction.evicted > 0 {
            Console.event(
                "evicted \(eviction.evicted) photos, freed \(Self.bytes(eviction.bytesFreed))"
                    + (eviction.protectedFromEviction > 0
                        ? " (\(eviction.protectedFromEviction) held by outstanding hands)" : "")
            )
            environment.announce(.cacheChanged)
        }

        let reaped = try deck.reapAbandonedHands(idleFor: preferences.abandonedHandTimeout)
        if reaped.consumersReaped > 0 {
            Console.event(
                "reclaimed \(reaped.cardsReturned) cards from \(reaped.consumersReaped) abandoned hands"
            )
            environment.announce(.deckAdvanced)
        }
    }

    private func describe(cache: PhotoCache, deck: Deck, preferences: Preferences) throws -> String {
        let status = try cache.status()
        let stats = try deck.stats(settings: preferences.deckSettings)
        return """
            \(stats.dealablePhotos) in deck · \(status.residentCount)/\(status.cap) cached · \
            \(status.referencedCount) referenced · \(status.pendingCount) pending · \
            \(Self.bytes(status.bytesOnDisk)) on disk
            """
    }

    static func bytes(_ count: Int64) -> String {
        // `.byteCount` renders zero as "Zero kB", which reads as a bug.
        count == 0 ? "0 bytes" : count.formatted(.byteCount(style: .file))
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
