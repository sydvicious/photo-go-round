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
    /// The domain the values live in, remembered because forcing a re-read
    /// requires naming it — see `reload`.
    private let domain: String?
    /// Called after the source list is read and before it is written back, so a
    /// test can do what another process would: change the list in the window a
    /// read-modify-write leaves open.
    private let onReadingSources: (@Sendable () -> Void)?

    /// Which library's bells to ring when something here changes.
    ///
    /// **Nil rings nothing**, which is what a `Preferences` built by hand in a
    /// test wants: `notify_post` is machine-wide, so a test that announced a
    /// source change would be telling every agent on the Mac to go and rescan.
    /// `MacHostEnvironment` attaches the right ones.
    public var doorbells: DarwinNotification.Doorbells?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.domain = nil
        self.onReadingSources = nil
    }

    /// The App Group suite, which is the authoritative one. Falls back to
    /// standard defaults when the suite cannot be opened — which happens
    /// whenever the App Group entitlement is absent, i.e. every unsigned
    /// development build.
    public init(suiteName: String?, onReadingSources: (@Sendable () -> Void)? = nil) {
        self.onReadingSources = onReadingSources
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
            self.domain = suiteName
        } else {
            self.domain = nil
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
        public static let cacheByteCeiling = Key("cacheByteCeiling")
        public static let cacheMinimumFreeBytes = Key("cacheMinimumFreeBytes")
        public static let cacheCriticalFreeBytes = Key("cacheCriticalFreeBytes")
        public static let scanIntervalSeconds = Key("scanIntervalSeconds")
        public static let maintenanceIntervalSeconds = Key("maintenanceIntervalSeconds")
        public static let downloadConcurrency = Key("downloadConcurrency")
        public static let queueSize = Key("queueSize")
        public static let queueRefreshIntervalSeconds = Key("queueRefreshIntervalSeconds")
        public static let serveWaitSeconds = Key("serveWaitSeconds")
        public static let sources = Key("sources")
        /// Where the service is listening. Written by the agent, read by every
        /// local client.
        public static let servicePort = Key("servicePort")
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

    /// How many fetches run at once, across every source.
    ///
    /// Fetching is nearly all latency, so one at a time leaves the queue of
    /// pictures to cache idle for the duration of its own I/O. One number for
    /// the whole queue rather than one per source — fine while every source is
    /// a folder, and a politeness limit to revisit when the Photos and Google
    /// providers make it a request against somebody else's service.
    public var downloadConcurrency: Int {
        integer(.downloadConcurrency, default: CacheSettings.defaultConcurrency, in: 1...32)
    }

    /// How many cards to keep queued. A target, not a ceiling.
    ///
    /// **The meaning changed underneath the name.** It used to count *ready
    /// pictures* — photographs whose bytes were already fetched. The queue now
    /// holds cards, and serving walks it until it finds one it can show, asking
    /// for a fetch for each one it cannot. So the number bounds two things at
    /// once: how many cards a single request may skip, and how many fetches it
    /// may ask for on the way past.
    ///
    /// It also decides **how quickly the queue reflects a change in the
    /// library**, and that is what settles the number. A full queue only turns
    /// over as pictures are served, so cards dealt before a source arrived —
    /// or before a drive came back — persist for a whole queue's worth of
    /// pictures.
    ///
    /// **Twenty, measured rather than guessed (2026-08-24).** It was a thousand,
    /// then 250, then 100, on the reasoning that deeper is harmless because a
    /// skip is only an index lookup. Deeper is harmless; it is also useless, and
    /// the sweep that settled it is in `PLAN.md` under *The queue-size sweep*.
    /// Across 10, 20, 30 and 50, against a live library of 9,002 photographs,
    /// **nothing was ever skipped at any size** — so the number decides nothing
    /// about whether a picture is ready, only how long a newly dealt card waits
    /// and how faithfully the queue samples the library at any instant.
    ///
    /// Twenty is where two things meet: turning over quickly, and sampling the
    /// library faithfully at any instant. Below it a source holding a few per
    /// cent of the library is absent from the queue most of the time — at ten,
    /// a source with 7.9% of the photographs held none at all when sampled.
    ///
    /// **It is the lead a cold card gets.** A card is dealt whether or not its
    /// bytes are here and the queue's fetcher goes and gets them, so a card
    /// dealt onto the tail has this many pictures' worth of time before its
    /// turn. Twenty at ten seconds a picture is two hundred seconds, against a
    /// fetch deadline of sixty; a card that still has no bytes at the head is
    /// waited for, up to `serveWait`, and dropped.
    ///
    /// **What it does decide, beyond the sampling, is how far ahead the cache
    /// fetches.** The queue fetches its own cards, so this is the number of
    /// photographs that can be in flight or waiting for bytes at once, and
    /// raising it raises the burst a cold start pulls down.
    ///
    /// Read afresh every time the queue is topped up, so changing it takes
    /// effect at the next refresh rather than at the next launch. Raising it
    /// lets the queue grow on its own; lowering it simply stops producers being
    /// asked until serving brings the queue back under the new number, since
    /// nothing is ever evicted from the queue to make it shorter.
    public var queueSize: Int {
        integer(.queueSize, default: 20, in: 1...100_000)
    }

    /// How often the queue is topped up.
    ///
    /// Separate from the maintenance interval, because they answer to different
    /// pressures: topping up should be frequent enough that a queue drained by a
    /// fast consumer refills promptly, while sweeping and evicting can be lazy.
    public var queueRefreshInterval: Duration {
        .seconds(number(.queueRefreshIntervalSeconds, default: 5, in: 1...3600))
    }

    /// How long a request may wait for the head card's bytes to land before it
    /// gives up on that card.
    ///
    /// The card was dealt whether or not its bytes were here, and the queue's
    /// fetcher has been working on it since; by the time it reaches the head
    /// it has usually had twenty pictures' worth of time. This is the bound
    /// for when it has not. Spent once per request: when it runs out the cold
    /// card is dropped from the queue — next time it is dealt, maybe the bytes
    /// will be there — and the request takes the first card whose bytes are
    /// here without waiting again. Sixty seconds, decided 2026-09-05; zero
    /// means never wait.
    public var serveWait: Duration {
        .seconds(number(.serveWaitSeconds, default: 60, in: 0...3600))
    }

    // MARK: - Sources

    /// The source list, which is the one piece of library state that is not
    /// derivable and therefore the one that lives here.
    ///
    /// Entries that cannot be parsed are dropped rather than failing the read —
    /// a hand-edited plist should cost you the bad entry, not the library.
    public var sources: [SourceSpec] {
        readSources().specs
    }

    /// The list as specs, **and the entries that could not be read**.
    ///
    /// Both halves are needed by anything that writes: an entry this build
    /// cannot parse is somebody's source, and dropping it on the way past would
    /// delete it. It is carried through untouched and written back.
    private func readSources() -> (specs: [SourceSpec], unreadable: [Any]) {
        let stored = defaults.array(forKey: Key.sources.rawValue) ?? []
        var specs: [SourceSpec] = []
        var unreadable: [Any] = []
        for entry in stored {
            if let spec = SourceSpec(propertyList: entry) {
                specs.append(spec)
            } else {
                Log.prefs.error("keeping an unreadable entry in the source list, untouched")
                unreadable.append(entry)
            }
        }
        return (specs, unreadable)
    }

    public func setSources(_ specs: [SourceSpec]) {
        write(specs, keeping: readSources().unreadable)
    }

    private func write(_ specs: [SourceSpec], keeping unreadable: [Any]) {
        defaults.set(specs.map(\.propertyList) + unreadable, forKey: Key.sources.rawValue)
        doorbells?.post(.sourcesChanged)
    }

    /// Reads the list, lets `edit` change it, and writes it back — **checking
    /// that nothing else changed it in between**.
    ///
    /// `UserDefaults` has no compare-and-swap and the whole array is rewritten
    /// on every change, so two writers — the agent on a client's behalf and
    /// `pgr_ctl` — can each read the same list and write over each other. The
    /// loser's source simply never appears. This re-reads before writing and
    /// starts again when the list moved, which turns a silent loss into a retry.
    private func mutateSources(_ edit: (inout [SourceSpec]) -> Bool) -> Bool {
        for _ in 0..<Self.writeAttempts {
            let (before, _) = readSources()
            var edited = before
            guard edit(&edited) else { return false }

            onReadingSources?()

            let (now, unreadableNow) = readSources()
            guard now == before else {
                // Somebody wrote while we were deciding. Their list is the one
                // to edit, so go round again rather than overwriting it.
                continue
            }
            write(edited, keeping: unreadableNow)
            return true
        }
        Log.prefs.error("gave up rewriting the source list; something else keeps changing it")
        return false
    }

    /// How many times a change will start over when another writer beats it.
    /// Small: contention here is two people, not a thundering herd.
    static let writeAttempts = 5

    /// Adds a source if its locator is not already listed. Returns false when it
    /// was already there, which makes re-asserting the same list at every launch
    /// a no-op rather than a duplicate.
    @discardableResult
    public func addSource(_ spec: SourceSpec) -> Bool {
        !addSources([spec]).isEmpty
    }

    /// Adds several sources in one write, ringing the doorbell once.
    ///
    /// `addSource` posts `.sourcesChanged` on every call and **the agent
    /// observes that topic**, refreshing on each — so adding a two-hundred-file
    /// selection one at a time asks for two hundred refreshes. That was
    /// tolerable while only a person at a terminal could produce a batch; a
    /// multiple selection in a dialog is not a person typing.
    ///
    /// Returns the specs that were actually new, in the order given. A batch
    /// where every locator is already listed writes nothing and announces
    /// nothing, which keeps re-asserting a list at launch free.
    @discardableResult
    public func addSources(_ specs: [SourceSpec]) -> [SourceSpec] {
        var added: [SourceSpec] = []
        var changed = false
        _ = mutateSources { current in
            added = []
            changed = false
            for spec in specs {
                guard let existing = current.firstIndex(where: { $0.locator == spec.locator })
                else {
                    current.append(spec)
                    added.append(spec)
                    changed = true
                    continue
                }
                // **Already listed is not nothing to do.** Adding a folder again
                // with different options used to discard them silently and
                // report "nothing new" — so there was no way to ask for
                // recursion on a folder already there, and no sign it had been
                // ignored.
                if current[existing] != spec {
                    current[existing] = spec
                    changed = true
                }
            }
            return changed
        }
        return added
    }

    /// Removes a source by locator. Returns false when it was not listed,
    /// which makes removing something twice a no-op rather than an error.
    ///
    /// Removing it *here* is what removes it: the source table is a projection
    /// of this list, so a row deleted straight from the database comes back at
    /// the agent's next reconcile.
    @discardableResult
    public func removeSource(locator: String) -> Bool {
        mutateSources { current in
            let remaining = current.filter { $0.locator != locator }
            guard remaining.count != current.count else { return false }
            current = remaining
            return true
        }
    }

    /// Changes a folder source's recursion. Returns false when it is not
    /// listed, which is the same answer `setSourceEnabled` gives and for the
    /// same reason: the durable list is what a change has to land in, and a
    /// source missing from it is a repair rather than an edit.
    @discardableResult
    public func setSourceRecursive(_ recursive: Bool, locator: String) -> Bool {
        mutateSources { current in
            guard let index = current.firstIndex(where: { $0.locator == locator }) else {
                return false
            }
            current[index].recursive = recursive
            return true
        }
    }

    @discardableResult
    public func setSourceEnabled(_ enabled: Bool, locator: String) -> Bool {
        mutateSources { current in
            guard let index = current.firstIndex(where: { $0.locator == locator }) else {
                return false
            }
            current[index].enabled = enabled
            return true
        }
    }

    // MARK: - Where the service is

    /// The port the agent is listening on, or nil when none is running or it has
    /// not said yet.
    ///
    /// **This is state in a store meant for preferences, and the exception is
    /// deliberate.** Clients no longer open the database, so `UserDefaults` is
    /// the only place both ends can find without being told a path — a domain is
    /// a name rather than a location. The same argument that put the source list
    /// here puts this here.
    ///
    /// A stale value outlives a crash. A client finds nothing listening, which is
    /// the same answer it gets when the agent is simply stopped, and backs off.
    public var servicePort: UInt16? {
        guard defaults.object(forKey: Key.servicePort.rawValue) != nil else { return nil }
        let raw = defaults.integer(forKey: Key.servicePort.rawValue)
        guard raw > 0, raw <= Int(UInt16.max) else { return nil }
        return UInt16(raw)
    }

    /// Says where to find the service. The agent's to call, nobody else's.
    public func publishServicePort(_ port: UInt16) {
        defaults.set(Int(port), forKey: Key.servicePort.rawValue)
        doorbells?.post(.preferencesChanged)
    }

    /// Withdraws it on the way out, so nothing points at a service that has
    /// stopped.
    public func withdrawServicePort() {
        defaults.removeObject(forKey: Key.servicePort.rawValue)
        doorbells?.post(.preferencesChanged)
    }

    // MARK: - Writing

    /// `pgr` owns preference writes, because it knows the correct domain for
    /// each consumer and posts the change notification afterwards. Raw
    /// `defaults` remains usable by anyone who knows the right domain; nothing
    /// depends on them knowing it.
    public func set(_ key: Key, to value: Double) {
        defaults.set(value, forKey: key.rawValue)
        doorbells?.post(.preferencesChanged)
    }

    public func set(_ key: Key, to value: Int) {
        defaults.set(value, forKey: key.rawValue)
        doorbells?.post(.preferencesChanged)
    }

    public func remove(_ key: Key) {
        defaults.removeObject(forKey: key.rawValue)
        doorbells?.post(.preferencesChanged)
    }

    /// Forces a re-read of the backing store.
    ///
    /// `cfprefsd` caches aggressively, and a stale value in our process is the
    /// default outcome — so noticing a change and then faithfully reading the
    /// old number is the failure mode this exists to prevent.
    /// Which domain `reload` names.
    ///
    /// Exposed because getting it wrong is invisible: synchronising the wrong
    /// domain succeeds and does nothing, and the values keep coming back stale.
    public var synchronisedDomain: String {
        domain ?? (kCFPreferencesCurrentApplication as String)
    }

    public func reload() {
        CFPreferencesAppSynchronize(synchronisedDomain as CFString)
    }

    /// The value the agent would actually use for a key: whatever is stored,
    /// otherwise the default, in both cases after the clamp.
    ///
    /// It answers by calling the same accessors the agent calls rather than by
    /// consulting a table of defaults, so it cannot drift from them. Returns nil
    /// for a key that is not a scalar setting — the source list is the only one.
    public func effectiveValue(for key: Key) -> String? {
        switch key {
        case .repeatWindowFraction: String(deckSettings.repeatWindowFraction)
        case .cacheByteCeiling: String(cacheSettings.byteCeiling)
        case .cacheMinimumFreeBytes: String(cacheSettings.minimumFreeBytes)
        case .cacheCriticalFreeBytes: String(cacheSettings.criticalFreeBytes)
        case .scanIntervalSeconds: String(Int(scanInterval.totalSeconds))
        case .maintenanceIntervalSeconds: String(Int(maintenanceInterval.totalSeconds))
        case .downloadConcurrency: String(downloadConcurrency)
        case .queueSize: String(queueSize)
        case .queueRefreshIntervalSeconds: String(Int(queueRefreshInterval.totalSeconds))
        case .serveWaitSeconds: String(Int(serveWait.totalSeconds))
        default: nil
        }
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
        .repeatWindowFraction, .cacheByteCeiling,
        .cacheMinimumFreeBytes, .cacheCriticalFreeBytes,
        .scanIntervalSeconds, .maintenanceIntervalSeconds, .downloadConcurrency, .queueSize,
        .queueRefreshIntervalSeconds, .serveWaitSeconds,
    ]
}
