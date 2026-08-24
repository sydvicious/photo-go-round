import Console
import Foundation
import PhotoGoRoundKit

/// Hand-rolled argument parsing. A dozen flags is an afternoon and about two
/// hundred lines, which is cheaper than taking a dependency for it.
struct Options {
    /// Two cases, and one of them only prints. Inspecting and configuring a
    /// library is `pgr_ctl`'s job, which is what makes "the service does one
    /// thing" true of the binary rather than merely of its default.
    enum Command {
        case run
        case help
    }

    var command: Command = .run
    var interval: Duration = .seconds(2)
    var once = false
    var scanIntervalOverride: Duration?
    /// Which port to serve pictures on, or nil to take whatever the kernel
    /// gives.
    ///
    /// **Permanent, and for the same reason `--prod` and `--container` are**: a
    /// development agent has to be able to run beside a shipped one on the same
    /// machine, and two listeners cannot hold one port. It keeps earning its
    /// place now the default floats, because a pinned number is one you can
    /// `curl` without first reading the published one out of preferences.
    var servicePort: UInt16?
    var containerOverride: URL?
    var databaseOverride: URL?
    var cacheOverride: URL?
    /// Folders named at launch, each carrying its own recursion. Whether to
    /// walk subdirectories is a property of the folder, not of the run: one
    /// wallpaper directory is flat and the album tree beside it is not.
    var foldersToAdd: [(url: URL, recursive: Bool)] = []
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
        var index = arguments.startIndex

        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.endIndex else { throw OptionsError.missingValue(flag: flag) }
            return arguments[index]
        }

        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--prod":
                options.deployment = .production
            case "--add-folder":
                // `--recursive` is a modifier on the folder that follows it, not
                // a setting for the run — so a flat directory and a nested tree
                // can be named in one invocation and each keeps its own answer.
                var walk = false
                var path = try next(argument)
                if path == "--recursive" || path == "-r" {
                    walk = true
                    path = try next("--add-folder --recursive")
                }
                options.foldersToAdd.append((URL(filePath: path), walk))
            case "--recursive", "-r":
                // Only meaningful attached to a folder. Standing alone it used to
                // mean "all of them", which is the ambiguity this removes.
                throw OptionsError.misplacedRecursive
            case "--once":
                options.once = true
            case "--port":
                let raw = try next(argument)
                guard let value = UInt16(raw), value > 0 else {
                    throw OptionsError.badValue(flag: argument, value: raw)
                }
                options.servicePort = value
            case "--scan-interval":
                let raw = try next(argument)
                guard let seconds = Double(raw), seconds > 0, seconds.isFinite else {
                    throw OptionsError.badValue(flag: argument, value: raw)
                }
                options.scanIntervalOverride = .seconds(seconds)
            case "--cache-root":
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
            case "--help", "-h":
                options.command = .help
            default:
                throw OptionsError.unknownFlag(argument)
            }
            index += 1
        }

        return options
    }

    static let usage = """
        photogoroundd — the Photo-Go-Round library agent

        USAGE
          photogoroundd [options]

        It takes no subcommand, because there is nothing to choose between: it
        scans every source, keeps the queue full, and evicts and sweeps the
        cache, on the intervals in preferences. Photos on the boot volume are
        referenced in place and never copied; only removable, network, and iCloud
        files are cached.

        **The service is configured, not commanded.** Everything it needs to know
        arrives before it starts. Everything you might want to ask it — what it
        found, what it has queued, what it will show next, what the preferences
        are — is answered by `pgr_ctl`, which opens the same database and rings
        the doorbell when it changes something. Neither process has to be running
        for the other to work.

        One consequence worth stating: the agent has no consumers of its own, so
        it fills the queue and then waits. That is correct, and it looks like
        nothing happening. To watch it do something, `curl` the picture endpoint
        from another terminal — the address is printed at startup.

        OPTIONS
              --add-folder [--recursive] <path>
                                  Register a folder source if it is not already
                                  there. Repeatable, and `--recursive` applies
                                  only to the folder it precedes
              --prod              Use the real library: ~/Library/Containers,
                                  ~/Library/Caches, and the real preference
                                  domain. Without it everything lives under
                                  .build, so a plain run cannot disturb anything.
              --cache-root <dir>  Cache root
              --once              Do one pass and exit, rather than looping
              --scan-interval <s> How often to rescan sources. Default: the
                                  scanIntervalSeconds preference (300)
          -d, --database <path>   Database file. Default: <container>/\(Deployment.databaseFilename)
              --container <dir>   Storage root
          -i, --interval <secs>   How often the loop wakes. Default: 2
              --port <n>          Pin the port. Without it the kernel assigns one
                                  and the agent publishes it to preferences and
                                  prints it at startup
          -h, --help              This

        ENVIRONMENT
          PGR_CONTAINER    Storage root. Same as --container; the flag wins.
          PGR_DATABASE     Database file. Same as --database; the flag wins.
          PGR_CACHE        Cache root. Same as --cache-root; the flag wins.
          PGR_FOLDERS      Colon-separated folders to ensure as sources at launch,
                           the way PATH is written. Adding one twice is a no-op,
                           so it is safe to leave set across restarts.
          PGR_RECURSIVE    Set to 1 to walk subdirectories of every PGR_FOLDERS entry.
          PGR_FOLDERS_RECURSIVE
                           Folders that are always walked, whatever PGR_RECURSIVE
                           says. Independent of PGR_FOLDERS; both may be set.

          Setting PGR_CONTAINER once per shell is the usual way to work, since
          `pgr_ctl` has to agree with the running agent about where the library is.

        EXAMPLES
          export PGR_CONTAINER="$HOME/Library/Application Support/Photo-Go-Round"
          photogoroundd --add-folder --recursive ~/Pictures/Albums \\
                        --add-folder ~/Pictures/Wallpaper

          PGR_FOLDERS=~/Pictures/A:~/Pictures/B PGR_RECURSIVE=1 photogoroundd

        SEE ALSO
          pgr_ctl(1), Documentation/photogoroundd.md
        """
}

enum OptionsError: Error, CustomStringConvertible {
    case unknownFlag(String)
    case misplacedRecursive
    case missingValue(flag: String)
    case badValue(flag: String, value: String)

    var description: String {
        switch self {
        case .unknownFlag(let flag): "unknown option \(flag)"
        case .misplacedRecursive: "--recursive belongs between --add-folder and its path"
        case .missingValue(let flag): "\(flag) needs a value"
        case .badValue(let flag, let value): "\(flag) does not accept \(value)"
        }
    }
}
