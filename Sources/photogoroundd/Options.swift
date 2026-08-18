import Foundation
import PhotoGoRoundKit

/// Hand-rolled argument parsing. A dozen flags is an afternoon and about two
/// hundred lines, which is cheaper than taking a dependency for it.
struct Options {
    enum Command {
        case run
        case serve
        case source(InspectCommands.SourceAction)
        case status
        case queuePeek
        case queueFill
        case getPreferences
        case setPreference(key: String, value: String)
        case service(ServiceCommand.Action)
        case help
    }

    /// Running is what this program does. The other cases are inspect
    /// commands waiting to move into `pgr_ctl`, and once they have, this
    /// default is the only case left.
    var command: Command = .run
    var interval: Duration = .seconds(2)
    var recursive = false
    var once = false
    var scanIntervalOverride: Duration?
    var repeatWindowFraction = DeckSettingsDefaults.repeatWindowFraction
    var containerOverride: URL?
    var databaseOverride: URL?
    var cacheOverride: URL?
    /// Folders named at launch, each carrying its own recursion. Whether to
    /// walk subdirectories is a property of the folder, not of the run: one
    /// wallpaper directory is flat and the album tree beside it is not.
    var foldersToAdd: [(url: URL, recursive: Bool)] = []
    var count = 10
    var consumerName = "cli"
    var quiet = false
    var sourceIsFile = false
    var deployment: Deployment = .development

    /// Flags beat environment beats default. A launchd plist sets environment
    /// variables far more naturally than it sets argv, so the production roots
    /// can be pinned there without the agent caring which it was given.
    static func parse(_ arguments: [String], environment: [String: String]) throws -> Options {
        var options = Options()

        // Folders to make sure exist as sources at launch, colon-separated the
        // way PATH is. A service started by something other than a person needs
        // to be told what to look at without anybody typing a subcommand, and an
        // environment variable is the one thing every launcher can set.
        //
        // Adding the same folder twice is a no-op, so this is safe to leave set
        // across restarts — it describes what should be true, not what to do.
        //
        // `PGR_RECURSIVE` applies to every entry in `PGR_FOLDERS`, which is the
        // common case and the one a launchd plist can express without ceremony.
        // A mixed set uses `PGR_FOLDERS_RECURSIVE` for the other half; the two
        // lists are independent and both may be set.
        let recursiveByDefault =
            (environment["PGR_RECURSIVE"]).map { $0 == "1" || $0.lowercased() == "true" } ?? false
        if let folders = environment["PGR_FOLDERS"], !folders.isEmpty {
            options.foldersToAdd += folders.split(separator: ":")
                .map { (URL(filePath: String($0)), recursiveByDefault) }
        }
        if let folders = environment["PGR_FOLDERS_RECURSIVE"], !folders.isEmpty {
            options.foldersToAdd += folders.split(separator: ":")
                .map { (URL(filePath: String($0)), true) }
        }
        options.recursive = recursiveByDefault

        var pendingSourceAdd: String?
        // Held aside because `-r` may appear after the path it applies to.
        var plainFolders: [URL] = []
        var index = arguments.startIndex

        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.endIndex else { throw OptionsError.missingValue(flag: flag) }
            return arguments[index]
        }

        func nextID(_ flag: String) throws -> Int64 {
            let raw = try next(flag)
            guard let id = Int64(raw) else { throw OptionsError.badValue(flag: flag, value: raw) }
            return id
        }

        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "serve":
                options.command = .serve
            case "status":
                options.command = .status
            case "get":
                options.command = .getPreferences
            case "set":
                let key = try next("set")
                options.command = .setPreference(key: key, value: try next("set"))
            case "queue":
                switch try next("queue") {
                case "peek": options.command = .queuePeek
                case "fill": options.command = .queueFill
                case let other: throw OptionsError.unknownFlag("queue \(other)")
                }
            case "source":
                switch try next("source") {
                case "add": pendingSourceAdd = try next("source add")
                case "list": options.command = .source(.list)
                case "remove": options.command = .source(.remove(id: try nextID("source remove")))
                case "enable": options.command = .source(.enable(id: try nextID("source enable")))
                case "disable": options.command = .source(.disable(id: try nextID("source disable")))
                case "refresh": options.command = .source(.refresh(id: nil))
                case let other: throw OptionsError.unknownFlag("source \(other)")
                }
            case "--prod":
                options.deployment = .production
            case "--file":
                options.sourceIsFile = true
            case "--count", "-n":
                let raw = try next(argument)
                guard let value = Int(raw), value > 0 else {
                    throw OptionsError.badValue(flag: argument, value: raw)
                }
                options.count = value
            case "--consumer":
                options.consumerName = try next(argument)
            case "--quiet", "-q":
                options.quiet = true
            case "register":
                options.command = .service(.register)
            case "unregister":
                options.command = .service(.unregister)
            case "service-status":
                options.command = .service(.status)
            case "--add-folder":
                plainFolders.append(URL(filePath: try next(argument)))
            case "--add-folder-recursive":
                options.foldersToAdd.append((URL(filePath: try next(argument)), true))
            case "--once":
                options.once = true
            case "--scan-interval":
                let raw = try next(argument)
                guard let seconds = Double(raw), seconds > 0, seconds.isFinite else {
                    throw OptionsError.badValue(flag: argument, value: raw)
                }
                options.scanIntervalOverride = .seconds(seconds)
            case "--cache":
                options.cacheOverride = URL(filePath: try next(argument))
            case "--database", "-d":
                options.databaseOverride = URL(filePath: try next(argument))
            case "--container":
                options.containerOverride = URL(filePath: try next(argument))
            case "--interval", "-i":
                let raw = try next(argument)
                guard let seconds = Double(raw), seconds > 0, seconds.isFinite else {
                    throw OptionsError.badValue(flag: argument, value: raw)
                }
                options.interval = .seconds(seconds)
            case "--recursive", "-r":
                options.recursive = true
            case "--window", "-w":
                let raw = try next(argument)
                guard let fraction = Double(raw), (0...1).contains(fraction) else {
                    throw OptionsError.badValue(flag: argument, value: raw)
                }
                options.repeatWindowFraction = fraction
            case "--help", "-h":
                options.command = .help
            default:
                throw OptionsError.unknownFlag(argument)
            }
            index += 1
        }

        // `-r` may appear anywhere, so folders given with the plain flag are
        // resolved once every argument has been seen. `--add-folder-recursive`
        // needs none of this: it says so itself, which is the point of having it.
        options.foldersToAdd += plainFolders.map { ($0, options.recursive) }

        // `--recursive` and `--file` may appear after the path, so the add is
        // assembled once every argument has been seen.
        if let path = pendingSourceAdd {
            options.command = .source(
                .add(path: path, recursive: options.recursive, isFile: options.sourceIsFile))
        }

        return options
    }

    static let usage = """
        photogoroundd — the Photo-Go-Round library agent

        USAGE
          photogoroundd [options]
          photogoroundd serve [options]
          photogoroundd status
          photogoroundd source add <path> [-r] [--file] | list | remove <id>
                             source enable <id> | disable <id> | refresh
          photogoroundd queue peek | fill
          photogoroundd get | set <key> <value>
          photogoroundd register | unregister | service-status

        With no command it runs: scans every source, keeps the queue full, and
        evicts and sweeps the cache, on the intervals in preferences. Photos on
        the boot volume are referenced in place and never copied; only removable,
        network, and iCloud files are cached.

        serve   Takes pictures off the queue as a named consumer, reporting each
                one and the latency. This is what a display does.

        status  What the agent thinks is going on: sources, pool, queue, cache,
                shuffle position, and the preferences in force.

        source  Manage sources while the agent runs. Changes land in the shared
                database and ring the doorbell, so a running agent picks them up
                without a restart.

        queue   `peek` shows what is ready to serve; `fill` asks every source for
                a picture synchronously, which is the agent's job done by hand.

        get/set Preferences, written to the domain the agent actually reads.

        register / unregister / service-status
                Manage the login item, so the agent keeps running after you close
                the terminal. Only works from a built bundle — see
                ./Scripts/make-agent-bundle.sh

        OPTIONS
              --add-folder <path> Register a folder source if it is not already there.
                                  Repeatable; `-r` applies to all of them
              --add-folder-recursive <path>
                                  The same, but this one folder is walked whether
                                  or not `-r` was given. Recursion belongs to the
                                  folder, so a flat wallpaper directory and a
                                  nested album tree can be named in one command
              --prod              Use the real library: ~/Library/Containers,
                                  ~/Library/Caches, and the real preference
                                  domain. Without it everything lives under
                                  .build, so a plain run cannot disturb anything.
              --cache <dir>       Cache root
              --once              Do one pass and exit, rather than looping
              --scan-interval <s> How often to rescan sources. Default: the
                                  scanIntervalSeconds preference (300)
          -d, --database <path>   Database file. Default: <container>/library.sqlite
              --container <dir>   Storage root
          -i, --interval <secs>   How often to rescan. Default: 2
          -r, --recursive         Walk subdirectories too
          -n, --count <n>         How many to serve, peek at, or fill. Default: 10
              --consumer <name>   Consumer identity. Default: cli (serve)
          -q, --quiet             Only print the summary (serve)
          -w, --window <0-1>      Repeat window fraction. Default: 0.5
          -h, --help              This

        ENVIRONMENT
          PGR_CONTAINER    Storage root. Same as --container; the flag wins.
          PGR_DATABASE     Database file. Same as --database; the flag wins.
          PGR_CACHE        Cache root. Same as --cache; the flag wins.
          PGR_FOLDERS      Colon-separated folders to ensure as sources at launch,
                           the way PATH is written. Adding one twice is a no-op,
                           so it is safe to leave set across restarts.
          PGR_RECURSIVE    Set to 1 to walk subdirectories of every PGR_FOLDERS entry.
          PGR_FOLDERS_RECURSIVE
                           Folders that are always walked, whatever PGR_RECURSIVE
                           says. Independent of PGR_FOLDERS; both may be set.

          Setting PGR_CONTAINER once per shell is the usual way to work, since
          every subcommand has to agree with the running agent about where the
          library is.

        EXAMPLES
          export PGR_CONTAINER="$HOME/Library/Application Support/Photo-Go-Round"
          photogoroundd --add-folder ~/Pictures/Wallpaper -r
          photogoroundd source list
          photogoroundd serve -n 5

          PGR_FOLDERS=~/Pictures/A:~/Pictures/B PGR_RECURSIVE=1 photogoroundd
        """
}

/// Mirrors `DeckSettings.defaultRepeatWindowFraction` without making the option
/// parser reach into the kit for a literal.
enum DeckSettingsDefaults {
    static let repeatWindowFraction = 0.5
}

enum OptionsError: Error, CustomStringConvertible {
    case unknownFlag(String)
    case missingValue(flag: String)
    case badValue(flag: String, value: String)

    var description: String {
        switch self {
        case .unknownFlag(let flag): "unknown option \(flag)"
        case .missingValue(let flag): "\(flag) needs a value"
        case .badValue(let flag, let value): "\(flag) does not accept \(value)"
        }
    }
}
