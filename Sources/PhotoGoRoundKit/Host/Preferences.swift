import Foundation

/// User-settable configuration.
///
/// **The database holds state; `UserDefaults` holds preferences.** Sources, the
/// pool, the queue, and the cache are state — what the system knows. Fits, timings,
/// caps, and the repeat window are preferences — what you told it.
///
/// Two rules follow from `defaults write` being a first-class interface:
///
/// **Every read is a parse with a default and a clamp.** `defaults write`
/// accepts anything — a string where a number belongs, a negative cache cap, a
/// dwell of zero. An invalid value is logged and ignored rather than accepted.
/// This is not defensive programming for its own sake; it is the direct
/// consequence of exposing a typed configuration surface to an untyped command.
///
/// **Nothing is read into a stored property at initialization.** Values are
/// read through accessors that reflect current state, so there is no cached copy
/// to go stale and no init-order dependency to reason about.
public struct Preferences: @unchecked Sendable {
    private let defaults: UserDefaults

    /// Where a person would guess, and be wrong: shared settings live in the
    /// App Group suite, not here. The server watches this domain anyway and
    /// says so loudly when it finds anything, because the guess is reasonable.
    public static let bundleDomain = "com.sydpolk.photogoround"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The App Group suite, which is the authoritative one. Falls back to
    /// standard defaults when the suite cannot be opened — which happens
    /// whenever the App Group entitlement is absent, i.e. every unsigned
    /// development build.
    public init(suiteName: String?) {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
        } else {
            if suiteName != nil {
                Log.prefs.notice(
                    "app group suite unavailable; using standard defaults for this run"
                )
            }
            self.defaults = .standard
        }
    }

    public struct Key: RawRepresentable, Sendable, Hashable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }

        public static let repeatWindowFraction = Key("repeatWindowFraction")
        public static let cachePhotoCap = Key("cachePhotoCap")
        public static let cacheByteCeiling = Key("cacheByteCeiling")
        public static let cacheMinimumFreeBytes = Key("cacheMinimumFreeBytes")
        public static let cacheCriticalFreeBytes = Key("cacheCriticalFreeBytes")
        public static let scanIntervalSeconds = Key("scanIntervalSeconds")
        public static let maintenanceIntervalSeconds = Key("maintenanceIntervalSeconds")
        public static let downloadConcurrency = Key("downloadConcurrency")
        public static let queueSize = Key("queueSize")
        public static let queueRefreshIntervalSeconds = Key("queueRefreshIntervalSeconds")
        public static let consumerIdleTimeoutSeconds = Key("consumerIdleTimeoutSeconds")
        public static let sources = Key("sources")
    }

    // MARK: - Reading, with a default and a clamp

    /// Returns the stored value when it is present, numeric, and in range.
    /// Anything else is logged once and ignored.
    func number<T: BinaryFloatingPoint>(
        _ key: Key, default fallback: T, in range: ClosedRange<T>
    ) -> T {
        guard defaults.object(forKey: key.rawValue) != nil else { return fallback }
        let raw = T(defaults.double(forKey: key.rawValue))
        guard raw.isFinite else {
            Log.prefs.error("\(key.rawValue, privacy: .public) is not a number; using the default")
            return fallback
        }
        guard range.contains(raw) else {
            let clamped = min(max(raw, range.lowerBound), range.upperBound)
            Log.prefs.error(
                "\(key.rawValue, privacy: .public) out of range; clamped to \(Double(clamped), privacy: .public)"
            )
            return clamped
        }
        return raw
    }

    func integer(_ key: Key, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        guard defaults.object(forKey: key.rawValue) != nil else { return fallback }
        let raw = defaults.integer(forKey: key.rawValue)
        guard range.contains(raw) else {
            let clamped = min(max(raw, range.lowerBound), range.upperBound)
            Log.prefs.error(
                "\(key.rawValue, privacy: .public) out of range; clamped to \(clamped, privacy: .public)"
            )
            return clamped
        }
        return raw
    }

    func bytes(_ key: Key, default fallback: Int64, in range: ClosedRange<Int64>) -> Int64 {
        guard defaults.object(forKey: key.rawValue) != nil else { return fallback }
        let raw = Int64(defaults.integer(forKey: key.rawValue))
        guard range.contains(raw) else {
            let clamped = min(max(raw, range.lowerBound), range.upperBound)
            Log.prefs.error(
                "\(key.rawValue, privacy: .public) out of range; clamped to \(clamped, privacy: .public)"
            )
            return clamped
        }
        return raw
    }

    // MARK: - What the kit actually asks for

    /// Recomputed on every access, never stored. Applied at the next deal, with
    /// no state to rebuild.
    public var deckSettings: DeckSettings {
        DeckSettings(
            repeatWindowFraction: number(
                .repeatWindowFraction, default: DeckSettings.defaultRepeatWindowFraction, in: 0...1
            )
        )
    }

    /// A lowered cap is applied by running an eviction pass; a raised one is
    /// applied by letting the queue fill toward it.
    public var cacheSettings: CacheSettings {
        let defaultSettings = CacheSettings.default
        return CacheSettings(
            photoCap: integer(.cachePhotoCap, default: defaultSettings.photoCap, in: 0...1_000_000),
            byteCeiling: bytes(
                .cacheByteCeiling, default: defaultSettings.byteCeiling, in: 0...Int64.max
            ),
            minimumFreeBytes: bytes(
                .cacheMinimumFreeBytes, default: defaultSettings.minimumFreeBytes, in: 0...Int64.max
            ),
            criticalFreeBytes: bytes(
                .cacheCriticalFreeBytes, default: defaultSettings.criticalFreeBytes, in: 0...Int64.max
            )
        )
    }

    /// How often the agent rescans sources.
    ///
    /// This is the only change-detection mechanism today. Watching becomes a 1.0
    /// requirement for surfaces that render ahead of time, but nothing depends
    /// on it yet.
    public var scanInterval: Duration {
        .seconds(number(.scanIntervalSeconds, default: 300, in: 1...86_400))
    }

    /// How often the agent verifies residency, sweeps orphans, and evicts.
    public var maintenanceInterval: Duration {
        .seconds(number(.maintenanceIntervalSeconds, default: 30, in: 1...3600))
    }

    /// How long a consumer may go without asking before it is reported as
    /// having gone quiet. Nothing is reclaimed — there is nothing to reclaim —
    /// but a display that stopped asking is worth being able to see.
    public var consumerIdleTimeout: Duration {
        .seconds(number(.consumerIdleTimeoutSeconds, default: 900, in: 60...86_400))
    }

    /// How many pictures each source fetches at once.
    ///
    /// Fetching is nearly all latency, so one at a time leaves a provider idle
    /// for the duration of its own I/O. Per source rather than global, so a slow
    /// provider saturates its own connection without crowding out a fast one.
    public var downloadConcurrency: Int {
        integer(.downloadConcurrency, default: SourceWorker.defaultConcurrency, in: 1...32)
    }

    /// How many ready pictures to keep queued. A target, not a ceiling.
    ///
    /// Read afresh every time the queue is topped up, so changing it takes
    /// effect at the next refresh rather than at the next launch. Raising it
    /// lets the queue grow on its own; lowering it simply stops producers being
    /// asked until serving brings the queue back under the new number, since
    /// nothing is ever evicted from the queue to make it shorter.
    public var queueSize: Int {
        integer(.queueSize, default: 1000, in: 1...100_000)
    }

    /// How often the queue is topped up.
    ///
    /// Separate from the maintenance interval, because they answer to different
    /// pressures: topping up should be frequent enough that a queue drained by a
    /// fast consumer refills promptly, while sweeping and evicting can be lazy.
    public var queueRefreshInterval: Duration {
        .seconds(number(.queueRefreshIntervalSeconds, default: 5, in: 1...3600))
    }

    // MARK: - Sources

    /// The source list, which is the one piece of library state that is not
    /// derivable and therefore the one that lives here.
    ///
    /// Entries that cannot be parsed are dropped rather than failing the read —
    /// a hand-edited plist should cost you the bad entry, not the library.
    public var sources: [SourceSpec] {
        let stored = defaults.array(forKey: Key.sources.rawValue) ?? []
        return stored.compactMap { entry in
            guard let spec = SourceSpec(propertyList: entry) else {
                Log.prefs.error("ignoring an unreadable entry in the source list")
                return nil
            }
            return spec
        }
    }

    public func setSources(_ specs: [SourceSpec]) {
        defaults.set(specs.map(\.propertyList), forKey: Key.sources.rawValue)
        DarwinNotification.post(.sourcesChanged)
    }

    /// Adds a source if its locator is not already listed. Returns false when it
    /// was already there, which makes re-asserting the same list at every launch
    /// a no-op rather than a duplicate.
    @discardableResult
    public func addSource(_ spec: SourceSpec) -> Bool {
        var current = sources
        guard !current.contains(where: { $0.locator == spec.locator }) else { return false }
        current.append(spec)
        setSources(current)
        return true
    }

    @discardableResult
    public func removeSource(locator: String) -> Bool {
        let current = sources
        let remaining = current.filter { $0.locator != locator }
        guard remaining.count != current.count else { return false }
        setSources(remaining)
        return true
    }

    @discardableResult
    public func setSourceEnabled(_ enabled: Bool, locator: String) -> Bool {
        var current = sources
        guard let index = current.firstIndex(where: { $0.locator == locator }) else { return false }
        current[index].enabled = enabled
        setSources(current)
        return true
    }

    // MARK: - Writing

    /// `pgr` owns preference writes, because it knows the correct domain for
    /// each consumer and posts the change notification afterwards. Raw
    /// `defaults` remains usable by anyone who knows the right domain; nothing
    /// depends on them knowing it.
    public func set(_ key: Key, to value: Double) {
        defaults.set(value, forKey: key.rawValue)
        DarwinNotification.post(.preferencesChanged)
    }

    public func set(_ key: Key, to value: Int) {
        defaults.set(value, forKey: key.rawValue)
        DarwinNotification.post(.preferencesChanged)
    }

    public func remove(_ key: Key) {
        defaults.removeObject(forKey: key.rawValue)
        DarwinNotification.post(.preferencesChanged)
    }

    /// Forces a re-read of the backing store.
    ///
    /// `cfprefsd` caches aggressively, and a stale value in our process is the
    /// default outcome — so noticing a change and then faithfully reading the
    /// old number is the failure mode this exists to prevent.
    public func reload() {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    /// Everything currently set, for `pgr get` and for logging what a run
    /// started with.
    public func all() -> [String: String] {
        var values: [String: String] = [:]
        for key in Self.allKeys {
            if let object = defaults.object(forKey: key.rawValue) {
                values[key.rawValue] = String(describing: object)
            }
        }
        return values
    }

    public static let allKeys: [Key] = [
        .repeatWindowFraction, .cachePhotoCap, .cacheByteCeiling,
        .cacheMinimumFreeBytes, .cacheCriticalFreeBytes,
        .scanIntervalSeconds, .maintenanceIntervalSeconds, .downloadConcurrency, .queueSize,
        .queueRefreshIntervalSeconds, .consumerIdleTimeoutSeconds,
    ]
}
