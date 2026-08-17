import Foundation

/// Hand-rolled argument parsing. A dozen flags is an afternoon and about two
/// hundred lines, which is cheaper than taking a dependency for it.
struct Options {
    enum Command {
        case watch(folder: URL)
        case run
        case help
    }

    var command: Command = .help
    var databasePath: String
    var interval: Duration = .seconds(2)
    var recursive = false
    var deal = false
    var once = false
    var repeatWindowFraction = DeckSettingsDefaults.repeatWindowFraction
    var containerOverride: URL?
    var databaseOverride: URL?
    var cacheOverride: URL?
    var foldersToAdd: [URL] = []

    /// Where the library lives when nothing says otherwise.
    ///
    /// The real storage root arrives with `HostEnvironment`, which resolves an
    /// App Group container first. Until then this is the shipping location, and
    /// `--database` or `--container` moves it for a development run — which is
    /// the point: the agent should never be tied to one path on one machine.
    static var defaultContainer: URL {
        URL.applicationSupportDirectory.appending(path: "Photo-Go-Round")
    }

    static func defaultDatabase(in container: URL) -> String {
        container.appending(path: "library.sqlite").path(percentEncoded: false)
    }

    /// Flags beat environment beats default. A launchd plist sets environment
    /// variables far more naturally than it sets argv, so the production roots
    /// can be pinned there without the agent caring which it was given.
    static func parse(_ arguments: [String], environment: [String: String]) throws -> Options {
        var container = Self.defaultContainer
        if let fromEnvironment = environment["PGR_CONTAINER"], !fromEnvironment.isEmpty {
            container = URL(filePath: fromEnvironment)
        }

        var options = Options(databasePath: Self.defaultDatabase(in: container))
        if let fromEnvironment = environment["PGR_DATABASE"], !fromEnvironment.isEmpty {
            options.databasePath = fromEnvironment
        }

        var explicitDatabase = false
        var index = arguments.startIndex

        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.endIndex else { throw OptionsError.missingValue(flag: flag) }
            return arguments[index]
        }

        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "watch":
                options.command = .watch(folder: URL(filePath: try next("watch")))
            case "run":
                options.command = .run
            case "--add-folder":
                options.foldersToAdd.append(URL(filePath: try next(argument)))
            case "--once":
                options.once = true
            case "--cache":
                options.cacheOverride = URL(filePath: try next(argument))
            case "--database", "-d":
                let path = try next(argument)
                options.databasePath = path
                options.databaseOverride = URL(filePath: path)
                explicitDatabase = true
            case "--container":
                container = URL(filePath: try next(argument))
                options.containerOverride = container
            case "--interval", "-i":
                let raw = try next(argument)
                guard let seconds = Double(raw), seconds > 0, seconds.isFinite else {
                    throw OptionsError.badValue(flag: argument, value: raw)
                }
                options.interval = .seconds(seconds)
            case "--recursive", "-r":
                options.recursive = true
            case "--deal":
                options.deal = true
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

        // A container given without an explicit database moves the database
        // with it, which is the whole reason to have both flags.
        if !explicitDatabase, environment["PGR_DATABASE"]?.isEmpty != false {
            options.databasePath = Self.defaultDatabase(in: container)
        }
        return options
    }

    static let usage = """
        PhotoGoRoundServer — the Photo-Go-Round library agent

        USAGE
          PhotoGoRoundServer watch <folder> [options]
          PhotoGoRoundServer run [options]

        watch   Narrates what the deck does about one folder: photos appearing,
                vanishing, coming back with their history. Copies no bytes
                anywhere — the only thing it writes is the database.

        run     The agent proper. Scans every source, fills and evicts the cache,
                and reclaims abandoned hands, on the intervals in preferences.
                Photos on the boot volume are still referenced in place and never
                copied; only removable, network, and iCloud files are cached.

        OPTIONS
              --add-folder <path> Register a folder source if it is not already there (run)
              --cache <dir>       Cache root. Default: <container>/cache
              --once              Do one pass and exit, rather than looping (run)
          -d, --database <path>   Database file. Default: <container>/library.sqlite
              --container <dir>   Storage root. Default: ~/Library/Application Support/Photo-Go-Round
          -i, --interval <secs>   How often to rescan. Default: 2
          -r, --recursive         Walk subdirectories too
              --deal              Also deal a card each tick, to watch the deck advance
          -w, --window <0-1>      Repeat window fraction. Default: 0.5
          -h, --help              This

        ENVIRONMENT
          PGR_CONTAINER, PGR_DATABASE — same as the flags. Flags win.

        EXAMPLES
          PhotoGoRoundServer watch ~/Pictures/Wallpaper --database /tmp/pgr.sqlite
          PhotoGoRoundServer watch ~/Pictures/Wallpaper -r --deal -i 5
          PhotoGoRoundServer run --container /tmp/pgr --add-folder ~/Pictures/Wallpaper -r
          PhotoGoRoundServer run --container /tmp/pgr --once
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
