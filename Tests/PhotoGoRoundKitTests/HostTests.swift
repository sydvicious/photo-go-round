import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import PhotoGoRoundAgentAPI

@Suite("Host environment and preferences")
struct HostTests {

    /// A throwaway defaults suite, so a test never writes into the real
    /// preferences of whoever is running it.
    private final class Suite {
        let name = scratchSuiteName("host")
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        var preferences: Preferences { Preferences(defaults: defaults) }

        deinit { discardScratchSuite(name) }
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

    @Test("Every path has an environment form, and the flag wins over it")
    func environmentNamesEveryPath() {
        // A launchd plist sets environment variables far more naturally than it
        // sets argv, which is the whole reason these exist.
        let fromEnvironment = MacHostEnvironment(
            deployment: .development,
            environment: [
                "PGR_DATABASE": "/tmp/env/db.sqlite",
                "PGR_CACHE": "/tmp/env/cache",
            ]
        )
        #expect(fromEnvironment.databaseURL.path(percentEncoded: false) == "/tmp/env/db.sqlite")
        #expect(fromEnvironment.cacheRoot.path(percentEncoded: false) == "/tmp/env/cache")

        let flagged = MacHostEnvironment(
            deployment: .development,
            databaseOverride: URL(filePath: "/tmp/flag/db.sqlite"),
            cacheOverride: URL(filePath: "/tmp/flag/cache"),
            environment: [
                "PGR_DATABASE": "/tmp/env/db.sqlite",
                "PGR_CACHE": "/tmp/env/cache",
            ]
        )
        #expect(flagged.databaseURL.path(percentEncoded: false) == "/tmp/flag/db.sqlite")
        #expect(flagged.cacheRoot.path(percentEncoded: false) == "/tmp/flag/cache")

        // An empty variable is not a value, here as everywhere else.
        let empty = MacHostEnvironment(
            deployment: .development,
            environment: ["PGR_DATABASE": "", "PGR_CACHE": ""],
            executableURL: Self.build
        )
        #expect(empty.databaseURL.lastPathComponent == Deployment.databaseFilename)
        #expect(empty.cacheRoot.lastPathComponent == "pgr-cache")
    }

    @Test("Relocating the container does not relocate preferences; PGR_PREFS_SUITE is what does")
    func onlyThePrefsSuiteMovesTheSourceList() {
        // **The hazard this pins is one that has already been paid for.** A
        // scratch agent started with `--container` and `--cache-root` is *not*
        // isolated: preferences are global to the executable, so the source
        // list — and `servicePort` — are still the real ones, and a run that
        // believed it was isolated could remove somebody's sources for good.
        let relocated = MacHostEnvironment(
            deployment: .development,
            containerOverride: URL(filePath: "/tmp/pgr-scratch"),
            cacheOverride: URL(filePath: "/tmp/pgr-scratch/cache"),
            environment: [:]
        )
        #expect(
            relocated.preferences.synchronisedDomain
                == MacHostEnvironment.preferenceDomain(for: .development),
            "moving the storage root moved the preference domain with it")

        // The environment form is the only thing that isolates the third rung.
        let name = scratchSuiteName("prefs-suite")
        defer { discardScratchSuite(name) }
        let isolated = MacHostEnvironment(
            deployment: .development,
            containerOverride: URL(filePath: "/tmp/pgr-scratch"),
            environment: ["PGR_PREFS_SUITE": name]
        )
        #expect(isolated.preferences.synchronisedDomain == name)

        // And an empty one is not a value, so it falls back to the deployment's
        // domain rather than to an unnamed suite.
        let blank = MacHostEnvironment(
            deployment: .production, environment: ["PGR_PREFS_SUITE": ""]
        )
        #expect(blank.preferences.synchronisedDomain == Deployment.identifier)
    }

    // MARK: - Preferences

    @Test("Unset preferences give the shipping defaults")
    func defaultsWhenUnset() {
        let suite = Suite()
        #expect(suite.preferences.deckSettings == DeckSettings.default)
        #expect(suite.preferences.cacheSettings == CacheSettings.default)
        #expect(suite.preferences.scanInterval == .seconds(300))
    }

    @Test("The effective value is what the agent would use, set or not")
    func effectiveValueAnswersWhatTheAgentWouldUse() {
        let suite = Suite()

        // Nothing stored: the answer is the default rather than a blank,
        // because the question is what the agent would use.
        #expect(suite.preferences.effectiveValue(for: .queueSize) == "20")
        #expect(suite.preferences.effectiveValue(for: .downloadConcurrency) == "4")
        #expect(suite.preferences.effectiveValue(for: .repeatWindowFraction) == "0.5")

        suite.defaults.set(250, forKey: Preferences.Key.queueSize.rawValue)
        #expect(suite.preferences.effectiveValue(for: .queueSize) == "250")

        // Clamped on the way out, so this reports what the agent would use
        // rather than what was typed.
        suite.defaults.set(999, forKey: Preferences.Key.downloadConcurrency.rawValue)
        #expect(suite.preferences.effectiveValue(for: .downloadConcurrency) == "32")

        // The source list is not a scalar setting and has no effective value.
        #expect(suite.preferences.effectiveValue(for: .sources) == nil)
    }

    // MARK: - Where the service says it is

    @Test("Nothing is published until an agent says so")
    func servicePortIsUnsetUntilPublished() {
        let suite = Suite()
        #expect(suite.preferences.servicePort == nil)
    }

    @Test("A published port is what a client reads back")
    func servicePortRoundTrips() {
        let suite = Suite()
        suite.preferences.publishServicePort(52_001)
        #expect(suite.preferences.servicePort == 52_001)

        // A second agent's launch replaces it rather than accumulating.
        suite.preferences.publishServicePort(52_002)
        #expect(suite.preferences.servicePort == 52_002)

        suite.preferences.withdrawServicePort()
        #expect(suite.preferences.servicePort == nil)
    }

    @Test("A port that cannot be one reads as nothing published")
    func servicePortRejectsNonsense() {
        // `defaults write` reaches this domain, and 0 is what an unbound
        // listener would report. Neither is an address, so neither is offered
        // as one.
        let suite = Suite()
        for nonsense in [0, -1, 70_000] {
            suite.defaults.set(nonsense, forKey: Preferences.Key.servicePort.rawValue)
            #expect(suite.preferences.servicePort == nil, "\(nonsense) is not a port")
        }
    }

    @Test("The published port is not a preference anyone sets")
    func servicePortIsNotASetting() {
        // It is state the agent writes, so it stays out of the list `pgr_ctl
        // get` walks and `pgr_ctl set` validates against — a person setting it
        // would be lying to every client about where to look.
        #expect(!Preferences.allKeys.contains(.servicePort))
    }

    @Test("A value that is set is used")
    func setValuesAreRead() {
        let suite = Suite()
        suite.defaults.set(0.25, forKey: Preferences.Key.repeatWindowFraction.rawValue)
        suite.defaults.set(9_000_000_000, forKey: Preferences.Key.cacheByteCeiling.rawValue)
        #expect(suite.preferences.deckSettings.repeatWindowFraction == 0.25)
        #expect(suite.preferences.cacheSettings.byteCeiling == 9_000_000_000)
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

        suite.defaults.set(-500, forKey: Preferences.Key.cacheByteCeiling.rawValue)
        #expect(suite.preferences.cacheSettings.byteCeiling == 0)

        suite.defaults.set(0, forKey: Preferences.Key.queueSize.rawValue)
        #expect(suite.preferences.queueSize == 1)

        suite.defaults.set(99, forKey: Preferences.Key.downloadConcurrency.rawValue)
        #expect(suite.preferences.downloadConcurrency == 32)

        suite.defaults.set("nonsense", forKey: Preferences.Key.scanIntervalSeconds.rawValue)
        #expect(suite.preferences.scanInterval == .seconds(1))
    }

    @Test("The serve wait is sixty seconds, may be zero, and is clamped at an hour")
    func serveWaitDefaultsAndClamps() {
        let suite = Suite()
        #expect(suite.preferences.serveWait == .seconds(60))
        #expect(suite.preferences.effectiveValue(for: .serveWaitSeconds) == "60")
        #expect(Preferences.allKeys.contains(.serveWaitSeconds), "pgr_ctl get would not list it")

        // Zero is a value, not an error: it means never wait.
        suite.defaults.set(0, forKey: Preferences.Key.serveWaitSeconds.rawValue)
        #expect(suite.preferences.serveWait == .zero)

        suite.defaults.set(99_999, forKey: Preferences.Key.serveWaitSeconds.rawValue)
        #expect(suite.preferences.serveWait == .seconds(3600))
        suite.defaults.set(-5, forKey: Preferences.Key.serveWaitSeconds.rawValue)
        #expect(suite.preferences.serveWait == .zero)
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

    // MARK: - The source list

    @Test("A batch of new sources is added in the order given")
    func batchAdds() {
        let suite = Suite()
        let added = suite.preferences.addSources([
            .folder("/tmp/a"), .folder("/tmp/b"), .folder("/tmp/c"),
        ])
        #expect(added.count == 3)
        // Folders carry a trailing slash, decided once at construction so that
        // every path agrees on one spelling of the identity.
        #expect(suite.preferences.sources.map(\.locator) == ["/tmp/a/", "/tmp/b/", "/tmp/c/"])
    }

    @Test("A batch skips what is already listed and keeps the rest")
    func batchSkipsDuplicates() {
        let suite = Suite()
        suite.preferences.addSources([.folder("/tmp/a")])

        let added = suite.preferences.addSources([.folder("/tmp/a"), .folder("/tmp/b")])
        #expect(added.map(\.locator) == ["/tmp/b/"])
        #expect(suite.preferences.sources.count == 2)
    }

    /// Duplicates *within* one batch too, since a dialog can hand back the same
    /// path twice by way of a symlink.
    @Test("A batch containing the same path twice adds it once")
    func batchDeduplicatesItself() {
        let suite = Suite()
        let added = suite.preferences.addSources([.folder("/tmp/a"), .folder("/tmp/a")])
        #expect(added.count == 1)
        #expect(suite.preferences.sources.count == 1)
    }

    /// The point of the batch: one write, therefore one notification, because
    /// the agent refreshes on every one it hears.
    /// The point of the batch: one write, therefore one notification, because
    /// the agent refreshes on every one it hears.
    ///
    /// What is asserted here is the contract that guards the write — nothing
    /// new, so nothing written. **The notification itself is deliberately not
    /// counted**: Darwin notifications are process-wide and carry no payload,
    /// so an observer of `.sourcesChanged` hears every other test that writes a
    /// source list, and there is no way to tell those from this one. That
    /// property is verified against a live agent instead, by watching a
    /// multi-file add produce one refresh in `pgr_ctl log` rather than one per
    /// file.
    @Test("A batch of sources already listed, asked for as they already are, adds nothing")
    func batchOfIdenticalDuplicatesIsSilent() {
        let suite = Suite()
        suite.preferences.addSources([.folder("/tmp/a", recursive: true)])

        let added = suite.preferences.addSources([
            .folder("/tmp/a", recursive: true), .folder("/tmp/a", recursive: true),
        ])
        #expect(added.isEmpty)
        #expect(suite.preferences.sources.count == 1)
        #expect(suite.preferences.sources[0].recursive)
    }

    /// **Already listed is not nothing to do.** Adding a folder again with
    /// different options used to discard them and report "nothing new", so there
    /// was no way to ask for recursion on a folder already there and no sign it
    /// had been ignored.
    @Test("Adding a listed source with different options applies them")
    func reAddingAppliesNewOptions() {
        let suite = Suite()
        suite.preferences.addSources([.folder("/tmp/a", recursive: false)])

        let added = suite.preferences.addSources([.folder("/tmp/a", recursive: true)])

        // Nothing was *added* — there is still one source — but what it was
        // asked to be is what it now is.
        #expect(added.isEmpty)
        #expect(suite.preferences.sources.count == 1)
        #expect(suite.preferences.sources[0].recursive)
    }

    // MARK: - The doorbell

    @Test("A posted notification reaches an observer")
    func notificationsAreDelivered() async throws {
        // A namespace of its own, so a real topic can be rung without any
        // agent on this Mac hearing it — which is the same isolation the
        // libraries themselves now get.
        let bells = DarwinNotification.Doorbells(namespace: "tests-\(UUID().uuidString.prefix(8))")
        let received = Mutex(0)

        let observation = try #require(
            bells.observe(.sourcesChanged, on: .global()) {
                received.withLock { $0 += 1 }
            }
        )
        defer { observation.cancel() }

        bells.post(.sourcesChanged)
        // Darwin notifications are asynchronous by nature; poll rather than
        // assuming an ordering the mechanism does not promise.
        for _ in 0..<50 where received.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(received.withLock { $0 } >= 1)
    }

    @Test("A cancelled observation stops hearing")
    func cancellingStopsDelivery() async throws {
        let bells = DarwinNotification.Doorbells(namespace: "tests-\(UUID().uuidString.prefix(8))")
        let received = Mutex(0)
        let observation = try #require(
            bells.observe(.sourcesChanged, on: .global()) { received.withLock { $0 += 1 } }
        )
        observation.cancel()
        // Cancelling twice is not an error.
        observation.cancel()

        bells.post(.sourcesChanged)
        try await Task.sleep(for: .milliseconds(200))
        #expect(received.withLock { $0 } == 0)
    }
}
