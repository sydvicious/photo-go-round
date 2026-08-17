import Foundation

/// User-settable configuration.
///
/// **The database holds state; `UserDefaults` holds preferences.** Sources, the
/// deck, hands, and the cache are state — what the system knows. Fits, timings,
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
        public static let cacheChunkSize = Key("cacheChunkSize")
        public static let cacheBurstSize = Key("cacheBurstSize")
        public static let cacheMinimumFreeBytes = Key("cacheMinimumFreeBytes")
        public static let cacheCriticalFreeBytes = Key("cacheCriticalFreeBytes")
        public static let scanIntervalSeconds = Key("scanIntervalSeconds")
        public static let maintenanceIntervalSeconds = Key("maintenanceIntervalSeconds")
        public static let abandonedHandTimeoutSeconds = Key("abandonedHandTimeoutSeconds")
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
    /// applied by letting the next prefetch fill to it. Chunk size takes effect
    /// at the next chunk boundary, which is one of the reasons chunks exist.
    public var cacheSettings: CacheSettings {
        let defaultSettings = CacheSettings.default
        return CacheSettings(
            photoCap: integer(.cachePhotoCap, default: defaultSettings.photoCap, in: 0...1_000_000),
            byteCeiling: bytes(
                .cacheByteCeiling, default: defaultSettings.byteCeiling, in: 0...Int64.max
            ),
            chunkSize: integer(.cacheChunkSize, default: defaultSettings.chunkSize, in: 1...1000),
            burstSize: integer(.cacheBurstSize, default: defaultSettings.burstSize, in: 1...1000),
            minimumFreeBytes: bytes(
                .cacheMinimumFreeBytes, default: defaultSettings.minimumFreeBytes, in: 0...Int64.max
            ),
            criticalFreeBytes: bytes(
                .cacheCriticalFreeBytes, default: defaultSettings.criticalFreeBytes, in: 0...Int64.max
            )
        )
    }

    /// How often the agent rescans sources as a backstop. FSEvents makes the
    /// common case near-immediate; this catches what happened while the agent
    /// was not running.
    public var scanInterval: Duration {
        .seconds(number(.scanIntervalSeconds, default: 300, in: 1...86_400))
    }

    /// How often the agent prefetches, evicts, and reaps.
    public var maintenanceInterval: Duration {
        .seconds(number(.maintenanceIntervalSeconds, default: 30, in: 1...3600))
    }

    /// How long a consumer may go without checking in before its unplayed cards
    /// are returned to the deck.
    public var abandonedHandTimeout: Duration {
        .seconds(number(.abandonedHandTimeoutSeconds, default: 1800, in: 60...86_400))
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
        .repeatWindowFraction, .cachePhotoCap, .cacheByteCeiling, .cacheChunkSize,
        .cacheBurstSize, .cacheMinimumFreeBytes, .cacheCriticalFreeBytes,
        .scanIntervalSeconds, .maintenanceIntervalSeconds, .abandonedHandTimeoutSeconds,
    ]
}
