import Console
import Foundation
import PhotoGoRoundKit

/// Hand-rolled argument parsing. A dozen flags is an afternoon and about two
/// hundred lines, which is cheaper than taking a dependency for it.
struct Options {
    /// Two cases, and one of them only prints. The inspect verbs that used to
    /// live here moved to `pgr_ctl` in Phase 2, which is what makes "the service
    /// does one thing" true of the binary and not merely of its default.
    enum Command {
        case run
        case help
    }

    var command: Command = .run
    var interval: Duration = .seconds(2)
    var recursive = false
    var once = false
    var scanIntervalOverride: Duration?
    /// Which port to serve pictures on.
    ///
    /// **Permanent, and for the same reason `--prod` and `--container` are**: a
    /// development agent has to be able to run beside a shipped one on the same
    /// machine, and two listeners cannot hold one port. It keeps earning its
    /// place once the default is a port the kernel assigns, because a pinned
    /// number is one you can `curl` without first reading the published one out
    /// of preferences.
    var servicePort: UInt16 = 9000
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
        options.recursive = recursiveByDefault

        // Held aside because `-r` may appear after the path it applies to.
        var plainFolders: [URL] = []
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
                plainFolders.append(URL(filePath: try next(argument)))
            case "--add-folder-recursive":
                options.foldersToAdd.append((URL(filePath: try next(argument)), true))
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

        return options
    }

    static let usage = """
        photogoroundd — the Photo-Go-Round library agent

        USAGE
          photogoroundd [options]

        It takes no command word, because there is nothing to choose between: it
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
        nothing happening. To watch it do something, run `pgr_ctl serve` in
        another terminal.

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
          -i, --interval <secs>   How often the loop wakes. Default: 2
              --port <n>          Port to serve pictures on. Default: 9000
          -r, --recursive         Walk subdirectories too
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
          `pgr_ctl` has to agree with the running agent about where the library is.

        EXAMPLES
          export PGR_CONTAINER="$HOME/Library/Application Support/Photo-Go-Round"
          photogoroundd --add-folder ~/Pictures/Wallpaper -r

          PGR_FOLDERS=~/Pictures/A:~/Pictures/B PGR_RECURSIVE=1 photogoroundd

        SEE ALSO
          pgr_ctl(1), Documentation/photogoroundd.md
        """
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
