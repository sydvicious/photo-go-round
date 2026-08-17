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
        deinit { UserDefaults().removePersistentDomain(forName: name) }
    }

    // MARK: - Storage roots

    @Test("Roots resolve flags first, then environment, then the container")
    func rootResolutionPrecedence() {
        // A launchd plist sets environment variables far more naturally than it
        // sets argv, so both have to work — and a development flag has to be
        // able to beat the production environment.
        let fromFlag = MacHostEnvironment.resolveContainer(
            override: URL(filePath: "/tmp/flag"),
            appGroupIdentifier: nil,
            environment: ["PGR_CONTAINER": "/tmp/env"]
        )
        #expect(fromFlag.origin == .explicitOverride)
        #expect(fromFlag.container.path(percentEncoded: false) == "/tmp/flag")

        let fromEnvironment = MacHostEnvironment.resolveContainer(
            override: nil,
            appGroupIdentifier: nil,
            environment: ["PGR_CONTAINER": "/tmp/env"]
        )
        #expect(fromEnvironment.origin == .environment)
        #expect(fromEnvironment.container.path(percentEncoded: false) == "/tmp/env")

        // With no App Group entitlement — every unsigned development build —
        // this must still land somewhere usable rather than returning nil.
        let fallback = MacHostEnvironment.resolveContainer(
            override: nil, appGroupIdentifier: nil, environment: [:]
        )
        #expect(fallback.origin == .applicationSupport)
        #expect(fallback.container.lastPathComponent == "Photo-Go-Round")
    }

    @Test("An empty environment variable is not a value")
    func emptyEnvironmentIsIgnored() {
        let resolved = MacHostEnvironment.resolveContainer(
            override: nil, appGroupIdentifier: nil, environment: ["PGR_CONTAINER": ""]
        )
        #expect(resolved.origin == .applicationSupport)
    }

    @Test("Database and cache follow the container unless named separately")
    func databaseAndCacheFollowTheContainer() {
        let environment = MacHostEnvironment(
            containerOverride: URL(filePath: "/tmp/pgr-root"),
            appGroupIdentifier: nil,
            environment: [:]
        )
        #expect(environment.databaseURL.path(percentEncoded: false) == "/tmp/pgr-root/library.sqlite")
        #expect(environment.cacheRoot.path(percentEncoded: false) == "/tmp/pgr-root/cache")

        let split = MacHostEnvironment(
            containerOverride: URL(filePath: "/tmp/pgr-root"),
            databaseOverride: URL(filePath: "/tmp/elsewhere/db.sqlite"),
            cacheOverride: URL(filePath: "/tmp/scratch/cache"),
            appGroupIdentifier: nil,
            environment: [:]
        )
        #expect(split.databaseURL.path(percentEncoded: false) == "/tmp/elsewhere/db.sqlite")
        #expect(split.cacheRoot.path(percentEncoded: false) == "/tmp/scratch/cache")
    }

    @Test("The macOS app group is team-ID prefixed, not group-prefixed")
    func appGroupIsTeamPrefixed() {
        // `group.` is the iOS convention. On macOS it produces a nil container
        // URL rather than an error, which is a classic afternoon lost.
        #expect(!MacHostEnvironment.appGroupIdentifier.hasPrefix("group."))
        #expect(MacHostEnvironment.appGroupIdentifier.hasSuffix(".com.sydpolk.photogoround"))
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

        suite.defaults.set(0, forKey: Preferences.Key.cacheChunkSize.rawValue)
        #expect(suite.preferences.cacheSettings.chunkSize == 1)

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
