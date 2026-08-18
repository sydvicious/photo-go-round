import Foundation
import Testing

@testable import PhotoGoRoundKit

@Suite("Host environment and preferences")
struct HostTests {

    /// A throwaway defaults suite, so a test never writes into the real
    /// preferences of whoever is running it.
    private final class Suite {
        let name = "com.sydpolk.photogoround.tests.\(UUID().uuidString)"
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        var preferences: Preferences { Preferences(defaults: defaults) }

        /// Tearing a defaults suite down takes all three steps, and skipping any
        /// of them leaves a plist in `~/Library/Preferences` for ever. This ran
        /// with only the first for a while and had left five hundred behind.
        ///
        /// `removePersistentDomain` empties the domain, `removeSuite` detaches
        /// it, and the file removal deals with `cfprefsd` having already flushed
        /// — or flushing afterwards, which is why the file is checked rather
        /// than assumed gone.
        /// `cfprefsd` owns these files, writes them on its own schedule, and
        /// will flush one back out *after* the test process has exited — so a
        /// few survive `deinit` and an `atexit` handler cannot catch them
        /// either. Nothing inside this process can win that race.
        ///
        /// So the sweep runs at the start instead, clearing what the previous
        /// run left. Both hooks together bound the leak at one run's worth
        /// rather than letting it accumulate; unswept, it had reached five
        /// hundred files.
        ///
        /// Only files older than this process are removed, so two test runs at
        /// once cannot delete each other's live suites.
        private static let sweep: Void = {
            let directory = URL.homeDirectory.appending(path: "Library/Preferences")
            let started = Date()
            let files =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files
            where file.lastPathComponent.hasPrefix("com.sydpolk.photogoround.tests.") {
                let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                if let modified, modified >= started { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }()

        init() { _ = Self.sweep }

        deinit {
            let defaults = UserDefaults(suiteName: name)
            defaults?.removePersistentDomain(forName: name)
            defaults?.synchronize()
            UserDefaults.standard.removeSuite(named: name)

            let plist = URL.homeDirectory
                .appending(path: "Library/Preferences")
                .appending(path: "\(name).plist")
            try? FileManager.default.removeItem(at: plist)
        }
    }

    // MARK: - Storage roots

    private static let build = URL(filePath: "/repo/.build/arm64-apple-macosx/debug/photogoroundd")

    @Test("Development is the default, and it cannot reach the real library")
    func developmentIsTheDefault() {
        // The safety has to live in the program rather than in a wrapper script,
        // or it evaporates the moment somebody runs the binary directly.
        let resolved = MacHostEnvironment.resolveContainer(
            deployment: .development, override: nil, environment: [:], executableURL: Self.build
        )
        #expect(resolved.origin == .development)
        #expect(resolved.container.path(percentEncoded: false) == "/repo/.build/pgr-container")
    }

    @Test("`--prod` moves the storage root, the cache, and the preferences together")
    func productionMovesAllThree() {
        // Two of the three are obviously per-deployment and the third silently
        // is not: relocating the container alone would leave the source list
        // pointing at the real one, so a run that believed it was isolated could
        // remove somebody's sources for good.
        let container = MacHostEnvironment.resolveContainer(
            deployment: .production, override: nil, environment: [:]
        )
        #expect(container.origin == .production)
        #expect(container.container.path(percentEncoded: false).hasSuffix(
            "/Library/Containers/com.sydpolk.photogoround"))

        let cache = MacHostEnvironment.defaultCacheRoot(
            deployment: .production, container: container.container, origin: .production)
        #expect(cache.path(percentEncoded: false).hasSuffix(
            "/Library/Caches/com.sydpolk.photogoround"))

        #expect(MacHostEnvironment.preferenceDomain(for: .production) == "com.sydpolk.photogoround")
        #expect(MacHostEnvironment.preferenceDomain(for: .development) != "com.sydpolk.photogoround")
    }

    @Test("The cache is not nested inside the container")
    func cacheIsItsOwnDirectory() {
        // ~/Library/Caches is purgeable, which is right for bytes we can fetch
        // again and wrong for the database. Nesting would forfeit that.
        let production = MacHostEnvironment.resolveContainer(
            deployment: .production, override: nil, environment: [:])
        let cache = MacHostEnvironment.defaultCacheRoot(
            deployment: .production, container: production.container, origin: .production)
        #expect(!cache.path(percentEncoded: false).hasPrefix(
            production.container.path(percentEncoded: false)))
    }

    @Test("Naming a container takes the cache with it")
    func explicitContainerCarriesTheCache() {
        // Somebody who named one directory meant both.
        let cache = MacHostEnvironment.defaultCacheRoot(
            deployment: .development,
            container: URL(filePath: "/tmp/mine"),
            origin: .explicitOverride
        )
        #expect(cache.path(percentEncoded: false) == "/tmp/mine/cache")
    }

    @Test("Flags beat environment beats the deployment default")
    func resolutionPrecedence() {
        let fromFlag = MacHostEnvironment.resolveContainer(
            deployment: .production,
            override: URL(filePath: "/tmp/flag"),
            environment: ["PGR_CONTAINER": "/tmp/env"]
        )
        #expect(fromFlag.origin == .explicitOverride)

        // A launchd plist sets environment variables far more naturally than it
        // sets argv, so both have to work.
        let fromEnvironment = MacHostEnvironment.resolveContainer(
            deployment: .production, override: nil, environment: ["PGR_CONTAINER": "/tmp/env"]
        )
        #expect(fromEnvironment.origin == .environment)
        #expect(fromEnvironment.container.path(percentEncoded: false) == "/tmp/env")

        // An empty variable is not a value.
        #expect(
            MacHostEnvironment.resolveContainer(
                deployment: .development, override: nil, environment: ["PGR_CONTAINER": ""],
                executableURL: Self.build
            ).origin == .development
        )
    }

    @Test("Database and cache can each be moved on their own")
    func databaseAndCacheAreSeparable() {
        let split = MacHostEnvironment(
            deployment: .development,
            containerOverride: URL(filePath: "/tmp/pgr-root"),
            databaseOverride: URL(filePath: "/tmp/elsewhere/db.sqlite"),
            cacheOverride: URL(filePath: "/tmp/scratch/cache"),
            environment: [:]
        )
        #expect(split.databaseURL.path(percentEncoded: false) == "/tmp/elsewhere/db.sqlite")
        #expect(split.cacheRoot.path(percentEncoded: false) == "/tmp/scratch/cache")
    }

    // MARK: - Preferences

    @Test("Unset preferences give the shipping defaults")
    func defaultsWhenUnset() {
        let suite = Suite()
        #expect(suite.preferences.deckSettings == DeckSettings.default)
        #expect(suite.preferences.cacheSettings == CacheSettings.default)
        #expect(suite.preferences.scanInterval == .seconds(300))
    }

    @Test("A value that is set is used")
    func setValuesAreRead() {
        let suite = Suite()
        suite.defaults.set(0.25, forKey: Preferences.Key.repeatWindowFraction.rawValue)
        suite.defaults.set(250, forKey: Preferences.Key.cachePhotoCap.rawValue)
        #expect(suite.preferences.deckSettings.repeatWindowFraction == 0.25)
        #expect(suite.preferences.cacheSettings.photoCap == 250)
    }

    @Test("Nonsense from `defaults write` is clamped, never accepted")
    func garbageIsClamped() {
        // `defaults write` accepts anything: a negative cache cap, a fraction of
        // 42, a string where a number belongs. Every read is a parse with a
        // default and a clamp, which is the direct consequence of exposing a
        // typed configuration surface to an untyped command.
        let suite = Suite()
        suite.defaults.set(42.0, forKey: Preferences.Key.repeatWindowFraction.rawValue)
        #expect(suite.preferences.deckSettings.repeatWindowFraction == 1.0)

        suite.defaults.set(-9, forKey: Preferences.Key.repeatWindowFraction.rawValue)
        #expect(suite.preferences.deckSettings.repeatWindowFraction == 0.0)

        suite.defaults.set(-500, forKey: Preferences.Key.cachePhotoCap.rawValue)
        #expect(suite.preferences.cacheSettings.photoCap == 0)

        suite.defaults.set(0, forKey: Preferences.Key.queueSize.rawValue)
        #expect(suite.preferences.queueSize == 1)

        suite.defaults.set(99, forKey: Preferences.Key.downloadConcurrency.rawValue)
        #expect(suite.preferences.downloadConcurrency == 32)

        suite.defaults.set("nonsense", forKey: Preferences.Key.scanIntervalSeconds.rawValue)
        #expect(suite.preferences.scanInterval == .seconds(1))
    }

    @Test("Preferences are read through, never cached at initialization")
    func preferencesAreNotStale() {
        // Nothing reads a preference into a stored property, so there is no
        // cached copy to go stale and no init-order dependency to reason about.
        let suite = Suite()
        let preferences = suite.preferences
        #expect(preferences.deckSettings.repeatWindowFraction == 0.5)

        suite.defaults.set(0.75, forKey: Preferences.Key.repeatWindowFraction.rawValue)
        #expect(preferences.deckSettings.repeatWindowFraction == 0.75)
    }

    @Test("The critical disk floor can never exceed the pause floor")
    func diskFloorsAreOrdered() {
        // Otherwise the cache would evict ahead of the cap before it ever
        // stopped materializing, which is backwards.
        let settings = CacheSettings(minimumFreeBytes: 100, criticalFreeBytes: 5000)
        #expect(settings.criticalFreeBytes <= settings.minimumFreeBytes)
    }

    // MARK: - The doorbell

    @Test("A posted notification reaches an observer")
    func notificationsAreDelivered() async throws {
        let topic = DarwinNotification.Topic("tests.\(UUID().uuidString.prefix(8))")
        let received = Mutex(0)

        let observation = try #require(
            DarwinNotification.observe(topic, on: .global()) {
                received.withLock { $0 += 1 }
            }
        )
        defer { observation.cancel() }

        DarwinNotification.post(topic)
        // Darwin notifications are asynchronous by nature; poll rather than
        // assuming an ordering the mechanism does not promise.
        for _ in 0..<50 where received.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(received.withLock { $0 } >= 1)
    }

    @Test("A cancelled observation stops hearing")
    func cancellingStopsDelivery() async throws {
        let topic = DarwinNotification.Topic("tests.\(UUID().uuidString.prefix(8))")
        let received = Mutex(0)
        let observation = try #require(
            DarwinNotification.observe(topic, on: .global()) { received.withLock { $0 += 1 } }
        )
        observation.cancel()
        // Cancelling twice is not an error.
        observation.cancel()

        DarwinNotification.post(topic)
        try await Task.sleep(for: .milliseconds(200))
        #expect(received.withLock { $0 } == 0)
    }
}
