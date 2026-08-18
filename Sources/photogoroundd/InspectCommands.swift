import Foundation
import PhotoGoRoundKit

/// Commands that drive a running agent from another terminal.
///
/// None of them talk to the agent. They open the same database, change what they
/// came to change, and ring the doorbell — which is the whole point of the
/// database being the transport: the agent does not have to be running for these
/// to work, and when it is running it notices within a tick.
struct InspectCommands {

    // MARK: - Sources

    enum SourceAction {
        case add(path: String, recursive: Bool, isFile: Bool)
        case list
        case remove(id: Int64)
        case enable(id: Int64)
        case disable(id: Int64)
        case refresh(id: Int64?)
    }

    static func source(_ action: SourceAction, environment: MacHostEnvironment) async throws {
        let database = try open(environment)
        let store = SourceStore(database: database)

        switch action {
        case .add(let path, let recursive, let isFile):
            let url = URL(filePath: path).standardizedFileURL
            let resolved = url.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: resolved) else {
                Console.failure("not found: \(resolved)")
                throw ExitCode(1)
            }
            if try store.all().contains(where: { $0.locator == resolved }) {
                Console.note("already a source: \(resolved)")
                return
            }
            let source = try store.add(
                kind: isFile ? .file : .folder, locator: resolved,
                recursive: isFile ? nil : recursive
            )
            Console.recovered("added source #\(source.id): \(resolved)")
            // Refresh it now rather than making the caller wait for the agent's
            // next scan — adding a source is the one moment somebody is
            // watching.
            let result = await store.refresh(source)
            Console.note("  \(result.added) photos found")
            environment.announce(.sourcesChanged)

        case .list:
            try list(store)

        case .remove(let id):
            guard let source = try store.source(id: id) else {
                Console.failure("no source #\(id)")
                throw ExitCode(1)
            }
            try store.remove(id: id)
            Console.recovered("removed source #\(id): \(source.locator)")
            environment.announce(.sourcesChanged)

        case .enable(let id), .disable(let id):
            let on: Bool = if case .enable = action { true } else { false }
            try store.setEnabled(on, for: id)
            Console.recovered("source #\(id) \(on ? "enabled" : "disabled")")
            environment.announce(.sourcesChanged)

        case .refresh(let id):
            let due = try id.map { [try store.source(id: $0)].compactMap(\.self) } ?? store.enabled()
            for source in due {
                let result = await source.enabled ? store.refresh(source) : nil
                guard let result else { continue }
                if result.sourceUnavailable {
                    Console.alert("#\(source.id) unavailable: \(result.reason ?? "unknown")")
                } else {
                    Console.note(
                        "#\(source.id)  +\(result.added)  -\(result.removed)  =\(result.unchanged)")
                }
            }
            environment.announce(.sourcesChanged)
        }
    }

    private static func list(_ store: SourceStore) throws {
        let sources = try store.all()
        guard !sources.isEmpty else {
            Console.note("no sources. add one with:  source add <folder>")
            return
        }
        for source in sources {
            let count =
                try store.database.scalarInt(
                    "SELECT COUNT(*) FROM photo WHERE source_id = :id;", ["id": .int(source.id)]
                ) ?? 0
            let state =
                !source.enabled
                ? "disabled"
                : source.available ? "ok" : "UNAVAILABLE: \(source.unavailableReason ?? "unknown")"
            let recursive = source.recursive == true ? " -r" : ""
            Console.note(
                "#\(source.id)  \(source.kind)\(recursive)  \(count) photos  [\(state)]\n"
                    + "     \(source.locator)")
        }
    }

    // MARK: - Status

    static func status(environment: MacHostEnvironment) throws {
        let database = try open(environment)
        let store = SourceStore(database: database)
        let deck = Deck(database: database)
        let preferences = environment.preferences
        let cache = PhotoCache(
            database: database, root: environment.cacheRoot,
            settings: preferences.cacheSettings, sources: store,
            queueSize: preferences.queueSize
        )

        let stats = try deck.stats(settings: preferences.deckSettings)
        let cacheStatus = try cache.status()
        let sources = try store.all()

        Console.banner(
            """
            database   \(environment.databaseURL.path(percentEncoded: false))
            cache      \(environment.cacheRoot.path(percentEncoded: false))
            roots from \(environment.origin.rawValue)
            """
        )
        Console.note("sources    \(sources.count) (\(sources.count { $0.enabled }) enabled, "
            + "\(sources.count { !$0.available }) unavailable)")
        Console.note("pool       \(stats.totalPhotos) photos, \(stats.dealablePhotos) dealable")
        Console.note(
            "queue      \(cacheStatus.queued)/\(preferences.queueSize) ready to serve")
        Console.note(
            "cache      \(cacheStatus.residentCount)/\(cacheStatus.cap) cached, "
                + "\(cacheStatus.referencedCount) referenced, \(bytes(cacheStatus.bytesOnDisk)) on disk")
        Console.note(
            "shuffle    pass began at \(stats.passStartSeq), \(stats.unusedInCurrentPass) left in it, "
                + "\(stats.currentDealSeq) shown all time")
        Console.note(
            "showings   min \(stats.timesShownMin), max \(stats.timesShownMax), "
                + "\(stats.neverDealt) never shown")
        print()
        Console.note("window \(preferences.deckSettings.repeatWindowFraction)  ·  "
            + "scan every \(Int(preferences.scanInterval.totalSeconds))s  ·  "
            + "top up every \(Int(preferences.queueRefreshInterval.totalSeconds))s  ·  "
            + "\(preferences.downloadConcurrency) fetches per source")

        let events = try deck.recentEvents(limit: 5)
        if !events.isEmpty {
            print()
            for event in events {
                Console.note("  \(event.kind): \(event.detail ?? "")")
            }
        }
    }

    // MARK: - Queue

    static func queuePeek(count: Int, environment: MacHostEnvironment) throws {
        let database = try open(environment)
        let queue = PhotoQueue(
            database: database, nominalSize: environment.preferences.queueSize)
        let ready = try queue.peek(count)
        guard !ready.isEmpty else {
            Console.note("queue is empty — nothing has been produced yet")
            return
        }
        for (index, card) in ready.enumerated() {
            Console.note("\(index + 1). \(card.externalID)  [source \(card.sourceID), \(card.storage)]")
        }
        Console.note("\(try queue.size()) queued in total")
    }

    /// Asks every enabled source for a picture, synchronously, and says what
    /// each one produced. The agent does this on a timer; this is for watching
    /// it happen.
    static func queueFill(rounds: Int, environment: MacHostEnvironment) async throws {
        let database = try open(environment)
        let store = SourceStore(database: database)
        let preferences = environment.preferences
        let cache = PhotoCache(
            database: database, root: environment.cacheRoot,
            settings: preferences.cacheSettings, sources: store,
            queueSize: preferences.queueSize
        )
        try cache.prepare()

        for round in 1...max(1, rounds) {
            var produced = 0
            for source in try store.enabled() {
                if try await cache.produce(forSource: source.id, settings: preferences.deckSettings) {
                    produced += 1
                }
            }
            Console.note("round \(round): \(produced) produced, \(try cache.queue.size()) queued")
            if produced == 0 { break }
        }
        environment.announce(.cacheChanged)
    }

    // MARK: - Preferences

    static func get(environment: MacHostEnvironment) {
        let values = environment.preferences.all()
        for key in Preferences.allKeys {
            let value = values[key.rawValue] ?? "(default)"
            Console.note("\(key.rawValue.padding(toLength: 28, withPad: " ", startingAt: 0)) \(value)")
        }
    }

    static func set(key: String, value: String, environment: MacHostEnvironment) throws {
        guard let match = Preferences.allKeys.first(where: { $0.rawValue == key }) else {
            Console.failure("unknown preference \(key). `get` lists them.")
            throw ExitCode(1)
        }
        guard let number = Double(value) else {
            Console.failure("\(key) takes a number")
            throw ExitCode(1)
        }
        // `pgr` owns preference writes because it knows the right domain, and it
        // rings the doorbell afterwards so a running agent re-reads at once.
        if number == number.rounded(), abs(number) < 1e15 {
            environment.preferences.set(match, to: Int(number))
        } else {
            environment.preferences.set(match, to: number)
        }
        Console.recovered("\(key) = \(value)")
    }

    // MARK: -

    private static func open(_ environment: MacHostEnvironment) throws -> Database {
        let path = environment.databaseURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            Console.failure(
                """
                no library at \(path)

                Either the agent has not run yet, or it is using a different container.
                Point this at the same one:

                    export PGR_CONTAINER=<dir>        # once per shell, or
                    … --container <dir>              # per command
                """)
            throw ExitCode(1)
        }
        let database = try Database(path: path)
        try Migrator.migrate(database)
        return database
    }

    static func bytes(_ count: Int64) -> String {
        count == 0 ? "0 bytes" : count.formatted(.byteCount(style: .file))
    }
}
