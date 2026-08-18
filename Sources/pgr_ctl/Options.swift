import Foundation
import PhotoGoRoundKit

/// Hand-rolled argument parsing. A dozen subcommands is an afternoon and about
/// two hundred lines, which is cheaper than taking a dependency for it —
/// `swift-argument-parser` is Apple's, but the no-dependencies rule does not
/// have an Apple exception.
///
/// **Positionals are collected first and interpreted last.** Flags may appear
/// anywhere, including before the command word and between a verb and its
/// argument, so `source add --folder /a -r` and `-r source add --folder /a` mean
/// the same thing. That falls out of separating "what was typed" from "what it
/// means" rather than from a rule about ordering.
struct Options {
    enum Command: Equatable {
        case status
        case source(SourceAction)
        case refresh(sourceID: Int64?)
        case poolStats
        case queuePeek
        case queueFill
        case serve
        case deckStats
        case cache(CacheAction)
        case shuffleTest
        case getPreferences(key: String?)
        case setPreference(key: String, value: String)
        case notify(topic: String)
        case log
        case service(ServiceAction)
        case help
    }

    enum SourceAction: Equatable {
        case add(path: String, kind: SourceKind, recursive: Bool)
        case list
        case remove(id: Int64)
        case enable(id: Int64)
        case disable(id: Int64)
    }

    enum CacheAction: Equatable {
        case status
        case evict
        case clear(scope: ClearScope, confirmed: Bool)
    }

    enum ClearScope: Equatable {
        case everything
        case source(Int64)
        case unavailable
    }

    enum ServiceAction: Equatable {
        case register
        case unregister
        case status
    }

    var command: Command = .help

    // Where the library is. Identical to the agent's, because a subcommand that
    // disagreed with the agent about the container would be reading a different
    // library and saying nothing about it.
    var deployment: Deployment = .development
    var containerOverride: URL?
    var databaseOverride: URL?
    var cacheOverride: URL?

    var count = 10
    var consumerName = "cli"
    var quiet = false
    var recursive = false
    var repeatWindowFraction = DeckSettings.defaultRepeatWindowFraction
    var deals = 50_000
    var photos = 4_000
    var follow = false
    var lastInterval = "1h"

    /// Takes no environment. Where the library lives is resolved by
    /// `MacHostEnvironment`, which reads `PGR_CONTAINER` and its siblings for
    /// every host alike — so a parser that also read them would be a second
    /// place for the two to disagree.
    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()

        var positional: [String] = []
        var sourcePath: String?
        var sourceKind: SourceKind = .folder
        var scopeSourceID: Int64?
        var refreshSourceID: Int64?
        var clearUnavailable = false
        var confirmed = false
        var askedForHelp = false

        var index = arguments.startIndex

        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.endIndex else { throw OptionsError.missingValue(flag: flag) }
            return arguments[index]
        }

        func nextInt(_ flag: String, minimum: Int = 1) throws -> Int {
            let raw = try next(flag)
            guard let value = Int(raw), value >= minimum else {
                throw OptionsError.badValue(flag: flag, value: raw)
            }
            return value
        }

        func nextID(_ flag: String) throws -> Int64 {
            let raw = try next(flag)
            guard let id = Int64(raw) else { throw OptionsError.badValue(flag: flag, value: raw) }
            return id
        }

        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--prod":
                options.deployment = .production
            case "--container":
                options.containerOverride = URL(filePath: try next(argument))
            case "--database", "-d":
                options.databaseOverride = URL(filePath: try next(argument))
            case "--cache":
                options.cacheOverride = URL(filePath: try next(argument))

            case "--folder":
                sourcePath = try next(argument)
                sourceKind = .folder
            case "--file":
                sourcePath = try next(argument)
                sourceKind = .file
            case "--recursive", "-r":
                options.recursive = true

            case "--source":
                let id = try nextID(argument)
                scopeSourceID = id
                refreshSourceID = id
            case "--unavailable":
                clearUnavailable = true
            case "--yes":
                confirmed = true

            case "--count", "-n":
                options.count = try nextInt(argument)
            case "--consumer":
                options.consumerName = try next(argument)
            case "--quiet", "-q":
                options.quiet = true
            case "--window", "-w":
                let raw = try next(argument)
                guard let fraction = Double(raw), (0...1).contains(fraction) else {
                    throw OptionsError.badValue(flag: argument, value: raw)
                }
                options.repeatWindowFraction = fraction

            case "--deals":
                options.deals = try nextInt(argument)
            case "--photos":
                options.photos = try nextInt(argument)

            case "--follow", "-f":
                options.follow = true
            case "--last":
                options.lastInterval = try next(argument)

            case "--help", "-h":
                askedForHelp = true

            default:
                guard !argument.hasPrefix("-") else { throw OptionsError.unknownFlag(argument) }
                positional.append(argument)
            }
            index += 1
        }

        if askedForHelp || positional.isEmpty {
            options.command = .help
            return options
        }

        options.command = try Self.command(
            from: positional,
            sourcePath: sourcePath,
            sourceKind: sourceKind,
            recursive: options.recursive,
            refreshSourceID: refreshSourceID,
            scopeSourceID: scopeSourceID,
            clearUnavailable: clearUnavailable,
            confirmed: confirmed
        )
        return options
    }

    /// What the positional words meant, resolved once every flag has been seen.
    private static func command(
        from words: [String],
        sourcePath: String?,
        sourceKind: SourceKind,
        recursive: Bool,
        refreshSourceID: Int64?,
        scopeSourceID: Int64?,
        clearUnavailable: Bool,
        confirmed: Bool
    ) throws -> Command {
        func verb(_ position: Int) -> String? {
            position < words.count ? words[position] : nil
        }
        func requireID(_ context: String) throws -> Int64 {
            guard let raw = verb(2), let id = Int64(raw) else {
                throw OptionsError.missingValue(flag: context)
            }
            return id
        }

        switch words[0] {
        case "help":
            return .help

        case "status":
            return .status

        case "source":
            switch verb(1) {
            case "add":
                guard let sourcePath else {
                    throw OptionsError.missingValue(flag: "source add --folder|--file")
                }
                return .source(.add(path: sourcePath, kind: sourceKind, recursive: recursive))
            case "list", nil:
                return .source(.list)
            case "remove":
                return .source(.remove(id: try requireID("source remove <id>")))
            case "enable":
                return .source(.enable(id: try requireID("source enable <id>")))
            case "disable":
                return .source(.disable(id: try requireID("source disable <id>")))
            case let other:
                throw OptionsError.unknownVerb("source \(other ?? "")")
            }

        case "refresh":
            return .refresh(sourceID: refreshSourceID)

        case "pool":
            switch verb(1) {
            case "stats", nil: return .poolStats
            case let other: throw OptionsError.unknownVerb("pool \(other ?? "")")
            }

        case "queue":
            switch verb(1) {
            case "peek", nil: return .queuePeek
            case "fill": return .queueFill
            case let other: throw OptionsError.unknownVerb("queue \(other ?? "")")
            }

        case "serve":
            return .serve

        case "deck":
            switch verb(1) {
            case "stats", nil: return .deckStats
            case let other: throw OptionsError.unknownVerb("deck \(other ?? "")")
            }

        case "cache":
            switch verb(1) {
            case "status", nil:
                return .cache(.status)
            case "evict":
                return .cache(.evict)
            case "clear":
                // Scope, most specific first. Clearing everything is the
                // default because it is what "clear the cache" means, and it is
                // also the expensive one — hence `--yes`.
                let scope: ClearScope =
                    if let scopeSourceID { .source(scopeSourceID) }
                    else if clearUnavailable { .unavailable }
                    else { .everything }
                return .cache(.clear(scope: scope, confirmed: confirmed))
            case let other:
                throw OptionsError.unknownVerb("cache \(other ?? "")")
            }

        case "shuffle-test":
            return .shuffleTest

        case "get":
            return .getPreferences(key: verb(1))

        case "set":
            guard let key = verb(1), let value = verb(2) else {
                throw OptionsError.missingValue(flag: "set <key> <value>")
            }
            return .setPreference(key: key, value: value)

        case "notify":
            guard let topic = verb(1) else {
                throw OptionsError.missingValue(flag: "notify <topic>")
            }
            return .notify(topic: topic)

        case "log":
            return .log

        case "register":
            return .service(.register)
        case "unregister":
            return .service(.unregister)
        case "service-status":
            return .service(.status)

        case let other:
            throw OptionsError.unknownVerb(other)
        }
    }

    static let usage = """
        pgr_ctl — drives the Photo-Go-Round library from a terminal

        USAGE
          pgr_ctl <command> [options]

        It never talks to the agent. Every command opens the same database, does
        what it came to do, and rings the doorbell, so the agent does not have to
        be running — and when it is, it notices within a tick.

        COMMANDS
          status                    Sources, pool, queue, cache, shuffle position
          source add --folder <p> [-r]
          source add --file <p>     Add a source. Written to preferences, which
                                    are the truth; the source table is a projection
          source list               Sources with their photo counts and state
          source remove <id>
          source enable <id> | disable <id>
          refresh [--source <id>]   Re-enumerate sources into the pool
          pool stats                Rows per source, storage, cache residency
          queue peek [-n <n>]       What is ready to serve, in order
          queue fill [-n <rounds>]  Ask every source for a picture, synchronously
          serve [-n <n>]            Take pictures off the head, with timing
          deck stats                Showing counts, pass position, recent events
          cache status              Resident, referenced, bytes, free space
          cache evict               Run an eviction pass now
          cache clear [--source <id>] [--unavailable] [--yes]
                                    Discard bytes. Never shuffle state
          shuffle-test [--deals <n>] [--photos <n>] [-w <f>]
                                    The statistical assertions, against a
                                    throwaway library. Never touches yours
          get [<key>] | set <key> <value>
                                    Preferences, in the domain the agent reads
          notify <topic>            Ring a doorbell by hand: prefs, deck,
                                    sources, cache
          log [-f] [--last <time>]  What every process has been logging
          register | unregister | service-status
                                    The login item. Needs a built bundle — see
                                    ./Scripts/make-agent-bundle.sh

        OPTIONS
              --prod              Use the real library: ~/Library/Containers,
                                  ~/Library/Caches, and the real preference
                                  domain. Without it everything lives under
                                  .build, so a plain run cannot disturb anything
              --container <dir>   Storage root
          -d, --database <path>   Database file
              --cache <dir>       Cache root
          -n, --count <n>         How many to serve, peek at, or fill. Default: 10
              --consumer <name>   Consumer identity for `serve`. Default: cli
          -q, --quiet             Only print the summary
          -r, --recursive         Walk subdirectories of an added folder
              --source <id>       Scope `refresh` or `cache clear` to one source
              --unavailable       Scope `cache clear` to sources that are gone
              --yes               Do not ask before clearing
          -w, --window <0-1>      Repeat window fraction. Default: 0.5
              --deals <n>         Cards to deal in shuffle-test. Default: 50000
              --photos <n>        Library size for shuffle-test. Default: 4000
          -f, --follow            Stream the log rather than printing it
              --last <time>       How far back to read. Default: 1h
          -h, --help              This

        ENVIRONMENT
          PGR_CONTAINER    Storage root. Same as --container; the flag wins.
          PGR_DATABASE     Database file. Same as --database; the flag wins.
          PGR_CACHE        Cache root. Same as --cache; the flag wins.

          Setting PGR_CONTAINER once per shell is the usual way to work, since
          every command has to agree with the running agent about where the
          library is.

        EXAMPLES
          export PGR_CONTAINER="$HOME/Library/Application Support/Photo-Go-Round"
          pgr_ctl source add --folder ~/Pictures/Wallpaper -r
          pgr_ctl status
          pgr_ctl serve -n 100 --consumer screensaver
          pgr_ctl shuffle-test --deals 50000 --photos 4000
        """
}

enum OptionsError: Error, CustomStringConvertible {
    case unknownFlag(String)
    case unknownVerb(String)
    case missingValue(flag: String)
    case badValue(flag: String, value: String)

    var description: String {
        switch self {
        case .unknownFlag(let flag): "unknown option \(flag)"
        case .unknownVerb(let verb): "unknown command \(verb). `pgr_ctl --help` lists them."
        case .missingValue(let flag): "\(flag) needs a value"
        case .badValue(let flag, let value): "\(flag) does not accept \(value)"
        }
    }
}
