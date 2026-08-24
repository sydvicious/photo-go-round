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
        // The database may not exist yet — this may be the first thing anyone
        // has ever done — so the sources are created rather than merely projected.
        let context = try Library.contextCreatingIfNeeded(environment)

        // Resolving, refusing the batch, the single preferences write, and the
        // reconcile are all `SourceStore.add`. The service calls the same one
        // for a client that asked over HTTP; what differs either side of it is
        // only who is told, and what happens next.
        let addition: SourceStore.Addition
        do {
            addition = try context.sources.add(
                requested.map {
                    SourceRequest(kind: $0.kind, path: $0.path, recursive: $0.recursive)
                },
                to: context.preferences)
        } catch SourceStore.EditFailure.pathsNotFound(let paths) {
            for path in paths {
                Console.failure("not found: \(path)")
            }
            throw ExitCode(1)
        } catch SourceStore.EditFailure.pathsNotOfKind(let paths) {
            for path in paths {
                Console.failure("not the requested kind: \(path)")
            }
            throw ExitCode(1)
        } catch SourceStore.EditFailure.optionNotAvailable(let option, let kind) {
            Console.failure("a \(kind) source has no \(option) option")
            throw ExitCode(1)
        } catch SourceStore.EditFailure.unsupportedKind(let kind) {
            Console.failure("\(kind) sources cannot be added")
            throw ExitCode(1)
        } catch SourceStore.EditFailure.notProjected(let locator) {
            Console.failure("added to preferences but the source table did not take it: \(locator)")
            throw ExitCode(1)
        }

        for locator in addition.alreadyListed {
            Console.note("already a source: \(locator)")
        }

        for source in addition.added {
            Console.recovered("added source #\(source.id): \(source.locator)")

            // Scan it now rather than making the caller wait for the agent's next
            // pass. Adding a source is the one moment somebody is watching — and
            // it is the one thing the service deliberately does *not* do here,
            // because a client is waiting on a status code rather than watching.
            let result = await context.sources.refresh(source)
            if result.sourceUnavailable {
                Console.alert("unavailable: \(result.reason ?? "unknown")")
            } else {
                Console.note("  \(result.added) photos found")
            }
        }
        // `setSources` posted `.sourcesChanged` already; announcing here as
        // well was a second doorbell for one change.
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
        let freed = try context.sources.remove(source, from: environment.preferences)
        Console.recovered(
            "removed source #\(id): \(source.locator)"
                + (freed > 0 ? "  (freed \(Library.bytes(freed)))" : ""))
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
        try context.sources.reconcile(with: environment.preferences)
        Console.recovered("source #\(id) \(enabled ? "enabled" : "disabled")")
        environment.announce(.sourcesChanged)
    }

    // MARK: - Refreshing

    /// Asks the agent to rescan. **It does not scan anything itself.**
    ///
    /// It used to, and that was wrong in three ways at once: the walk it did was
    /// the same walk the agent does, so a network share was enumerated twice;
    /// the terminal blocked for however long that took, with nothing to look at,
    /// because a refresh only prints what *changed*; and the account of the work
    /// ended up in the rig rather than in the process whose job it is. The agent
    /// now says what it is refreshing, and how long each source took.
    ///
    /// Every source, because the doorbell is a Darwin notification and those
    /// carry no payload — there is nowhere to put "just this one".
    static func refresh(sourceID: Int64?, environment: MacHostEnvironment) async throws {
        if let sourceID {
            Console.failure(
                """
                refresh asks the agent to rescan, and the doorbell it rings carries no payload —
                so there is no way to say "only #\(sourceID)". Drop --source to refresh every
                enabled source, which is what the agent does when it hears.
                """)
            throw ExitCode(1)
        }

        environment.announce(.sourcesChanged)

        // A doorbell nobody is listening for is not an error — configuring a
        // library never requires the agent — but it does mean nothing is going
        // to happen, and saying so beats watching for output that never comes.
        guard environment.preferences.servicePort != nil else {
            Console.alert("no agent is running, so nothing will act on this")
            return
        }
        Console.recovered("asked the agent to refresh its sources; it reports what it finds")
    }
}
