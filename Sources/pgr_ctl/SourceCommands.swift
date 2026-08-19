import Console
import Foundation
import PhotoGoRoundKit

/// Managing sources from a terminal.
///
/// **Every change goes through preferences, not through the source table.** The
/// table is a projection of the durable list, and the agent reconciles the two
/// on a thirty-second poll — so a row written straight into the database is
/// deleted again within half a minute, and a row disabled there is re-enabled
/// just as fast. Writing to preferences and then reconciling in the same breath
/// is the only version of this that survives a running agent, and it is also the
/// version that works when no agent is running at all.
enum SourceCommands {

    static func run(_ action: Options.SourceAction, environment: MacHostEnvironment) async throws {
        switch action {
        case .add(let sources):
            try await add(sources, environment: environment)
        case .list:
            try list(environment: environment)
        case .remove(let id):
            try remove(id: id, environment: environment)
        case .enable(let id):
            try setEnabled(true, id: id, environment: environment)
        case .disable(let id):
            try setEnabled(false, id: id, environment: environment)
        }
    }

    // MARK: - Adding

    /// Adds every source named on the command line.
    ///
    /// **Nothing is added until all of them resolve.** A command naming three
    /// folders where the second is misspelled should add none of them, rather
    /// than leaving the library in a state that depends on argument order.
    private static func add(
        _ requested: [Options.NewSource], environment: MacHostEnvironment
    ) async throws {
        var specs: [SourceSpec] = []
        for source in requested {
            let resolved = URL(filePath: source.path).standardizedFileURL
                .path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: resolved) else {
                Console.failure("not found: \(resolved)")
                throw ExitCode(1)
            }
            specs.append(
                source.kind == .file
                    ? SourceSpec(kind: .file, locator: resolved)
                    : SourceSpec.folder(resolved, recursive: source.recursive))
        }

        let preferences = environment.preferences
        var added: [SourceSpec] = []
        for spec in specs {
            if preferences.addSource(spec) {
                added.append(spec)
            } else {
                Console.note("already a source: \(spec.locator)")
            }
        }
        guard !added.isEmpty else { return }

        // The database may not exist yet — this may be the first thing anyone
        // has ever done — so the sources are created rather than merely projected.
        let context = try Library.contextCreatingIfNeeded(environment)
        try context.sources.reconcile(with: preferences.sources)

        for spec in added {
            guard let source = try context.sources.all().first(where: { $0.locator == spec.locator })
            else {
                Console.failure("added to preferences but the source table did not take it")
                throw ExitCode(1)
            }
            Console.recovered("added source #\(source.id): \(spec.locator)")

            // Scan it now rather than making the caller wait for the agent's next
            // pass. Adding a source is the one moment somebody is watching.
            let result = await context.sources.refresh(source)
            if result.sourceUnavailable {
                Console.alert("unavailable: \(result.reason ?? "unknown")")
            } else {
                Console.note("  \(result.added) photos found")
            }
        }
        environment.announce(.sourcesChanged)
    }

    // MARK: - Listing

    private static func list(environment: MacHostEnvironment) throws {
        let context = try Library.context(environment)
        let sources = try context.sources.all()
        guard !sources.isEmpty else {
            Console.note("no sources. add one with:  pgr_ctl sources add --folder <path>")
            return
        }
        for source in sources {
            let count = try context.sources.pool.size(forSource: source.id)
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

    // MARK: - Removing and switching off

    private static func remove(id: Int64, environment: MacHostEnvironment) throws {
        let context = try Library.context(environment)
        guard let source = try context.sources.source(id: id) else {
            Console.failure("no source #\(id)")
            throw ExitCode(1)
        }
        environment.preferences.removeSource(locator: source.locator)
        try context.sources.reconcile(with: environment.preferences.sources)
        Console.recovered("removed source #\(id): \(source.locator)")
        environment.announce(.sourcesChanged)
    }

    private static func setEnabled(
        _ enabled: Bool, id: Int64, environment: MacHostEnvironment
    ) throws {
        let context = try Library.context(environment)
        guard let source = try context.sources.source(id: id) else {
            Console.failure("no source #\(id)")
            throw ExitCode(1)
        }
        // Preferences key on the locator rather than on the row id, because the
        // id belongs to a database that is disposable. The id is what a person
        // types; the locator is what is stored.
        guard environment.preferences.setSourceEnabled(enabled, locator: source.locator) else {
            Console.failure("#\(id) is in the database but not in preferences; remove and re-add it")
            throw ExitCode(1)
        }
        try context.sources.reconcile(with: environment.preferences.sources)
        Console.recovered("source #\(id) \(enabled ? "enabled" : "disabled")")
        environment.announce(.sourcesChanged)
    }

    // MARK: - Refreshing

    static func refresh(sourceID: Int64?, environment: MacHostEnvironment) async throws {
        let context = try Library.context(environment)
        let due: [Source]
        if let sourceID {
            guard let source = try context.sources.source(id: sourceID) else {
                Console.failure("no source #\(sourceID)")
                throw ExitCode(1)
            }
            due = [source]
        } else {
            due = try context.sources.enabled()
        }
        guard !due.isEmpty else {
            Console.note("nothing to refresh")
            return
        }

        for source in due {
            let result = await context.sources.refresh(source)
            if result.sourceUnavailable {
                Console.alert("#\(source.id) unavailable: \(result.reason ?? "unknown")")
            } else {
                Console.note(
                    "#\(source.id)  +\(result.added)  -\(result.removed)  =\(result.unchanged)  "
                        + "\(source.locator)")
            }
        }
        environment.announce(.sourcesChanged)
    }
}
