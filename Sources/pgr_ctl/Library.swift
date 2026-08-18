import Console
import Foundation
import PhotoGoRoundKit

/// Opening the library, and the two conveniences every subcommand wants.
///
/// **Nothing here talks to the agent.** Each command opens the same database,
/// changes what it came to change, and rings the doorbell — which is the whole
/// point of the database being the transport: the agent does not have to be
/// running for any of this to work, and when it is running it notices within a
/// tick.
enum Library {

    /// Opens the library the agent is using, or explains why it cannot.
    ///
    /// The failure worth being specific about is not "no such file" — it is
    /// *pointing at a different container from the agent*, which looks exactly
    /// like an empty library and is the single most common way to waste twenty
    /// minutes here.
    static func open(_ environment: MacHostEnvironment) throws -> Database {
        let path = environment.databaseURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            Console.failure(
                """
                no library at \(path)

                Either the agent has not run yet, or it is using a different container.
                Point this at the same one:

                    export PGR_CONTAINER=<dir>       # once per shell, or
                    … --container <dir>              # per command
                """)
            throw ExitCode(1)
        }
        let database = try Database(path: path)
        try Migrator.migrate(database)
        return database
    }

    /// The database, the source store, and a cache configured from preferences
    /// — which is what most subcommands need and all of them assemble the same
    /// way.
    static func context(_ environment: MacHostEnvironment) throws -> Context {
        let database = try open(environment)
        let sources = SourceStore(database: database)
        let preferences = environment.preferences
        return Context(
            environment: environment,
            database: database,
            sources: sources,
            deck: Deck(database: database),
            preferences: preferences,
            cache: PhotoCache(
                database: database,
                root: environment.cacheRoot,
                settings: preferences.cacheSettings,
                sources: sources,
                queueSize: preferences.queueSize
            )
        )
    }

    /// The same, but it creates the library rather than refusing when there is
    /// none.
    ///
    /// Only `source add` wants this: adding the first source may genuinely be
    /// the first thing anybody has ever done, and "run the agent once before you
    /// can configure it" is a chicken-and-egg nobody should have to solve. Every
    /// other command refuses, because an empty library is almost always the
    /// wrong container rather than a fresh install.
    static func contextCreatingIfNeeded(_ environment: MacHostEnvironment) throws -> Context {
        try environment.prepare()
        let database = try Database(path: environment.databaseURL.path(percentEncoded: false))
        try Migrator.migrate(database)
        let sources = SourceStore(database: database)
        let preferences = environment.preferences
        return Context(
            environment: environment,
            database: database,
            sources: sources,
            deck: Deck(database: database),
            preferences: preferences,
            cache: PhotoCache(
                database: database,
                root: environment.cacheRoot,
                settings: preferences.cacheSettings,
                sources: sources,
                queueSize: preferences.queueSize
            )
        )
    }

    struct Context {
        let environment: MacHostEnvironment
        let database: Database
        let sources: SourceStore
        let deck: Deck
        let preferences: Preferences
        let cache: PhotoCache
    }

    /// `.byteCount` renders zero as "Zero kB", which reads as a bug.
    static func bytes(_ count: Int64) -> String {
        count == 0 ? "0 bytes" : count.formatted(.byteCount(style: .file))
    }

    static func number(_ value: Double, places: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }
}

/// Lets a command exit non-zero without the error text being printed twice.
struct ExitCode: Error {
    let code: Int32
    init(_ code: Int32) { self.code = code }
}
