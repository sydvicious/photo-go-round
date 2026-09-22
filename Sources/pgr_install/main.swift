import Console
import Foundation
import PhotoGoRoundAgentAPI
import PhotoGoRoundInstall

// Installs what this project builds, for development.
//
// **It exists because an Install scheme's ⌘R needs something runnable.** An
// aggregate target produces no product, so Xcode cannot run one; the scheme
// builds the product and this binary, then launches this with the product's
// path. That is what moves installing off ⌘B, which until 2026-09-19 meant
// asking "does this compile?" changed the machine.
//
// **It ships in nothing and is expected to be replaced.** Syd, 2026-09-19: "the
// application which installs on first launch will eventually replace
// pgr_install." `PhotoGoRoundInstall` is the lasting half; this is the door the
// scheme knocks on until the app can do the job.
//
// `Plans/Xcode - Separate Build and Run.md`.

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
Installs a built Photo-Go-Round product for development.

USAGE
  pgr_install saver [--from <path>] [--dry-run]
  pgr_install agent [--from <path>] [--dry-run]
  pgr_install wallpaper [--from <path>] [--dry-run]
  pgr_install start [--variant <name>]
  pgr_install stop [--variant <name>]
  pgr_install uninstall [--agent] [--saver] [--wallpaper] [--variant <name>] [--dry-run]

OPTIONS
  --from <path>   The built bundle. Defaults to $BUILT_PRODUCTS_DIR's copy.
                  An Install scheme passes $BUILT_PRODUCTS_DIR through the
                  environment rather than as an argument, because Xcode expands
                  a launch argument and then re-splits it on whitespace — and
                  every product here has a space in its name.
  --dry-run       Print what would happen and change nothing.
  --agent         For uninstall: which parts to remove. With none of the
  --saver         three, it removes all of them.
  --wallpaper
  --variant <name>
                  release, debug or claude: whose agent start and stop act on,
                  and whose copies uninstall removes. start and stop default to
                  the configuration this pgr_install was built as; uninstall
                  defaults to every configuration's.
  -h, --help      This.

NOTES
  Nothing here asks for Photos access. A grant is asked for by something with a
  window — the app — and an installer has none. See Plans/Xcode - Separate Build
  and Run.md, *Nothing in this plan asks for access to anything*.
"""

struct Options {
    var command = "help"
    var from: URL?
    var dryRun = false
    var parts: Set<Uninstall.Part> = []
    var variant: BuildVariant?
}

func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = arguments.startIndex
    if let first = arguments.first, !first.hasPrefix("-") {
        options.command = first
        index += 1
    }
    while index < arguments.endIndex {
        switch arguments[index] {
        case "--from":
            index += 1
            guard index < arguments.endIndex else { throw Fault("--from needs a path") }
            options.from = URL(filePath: arguments[index])
        case "--dry-run":
            options.dryRun = true
        case "--variant":
            index += 1
            guard index < arguments.endIndex, let variant = BuildVariant(rawValue: arguments[index])
            else { throw Fault("--variant needs release, debug or claude") }
            options.variant = variant
        case "--agent":
            options.parts.insert(.agent)
        case "--saver":
            options.parts.insert(.saver)
        case "--wallpaper":
            options.parts.insert(.wallpaper)
        case "-h", "--help":
            options.command = "help"
        case let other:
            throw Fault("unknown option \(other)")
        }
        index += 1
    }
    return options
}

struct Fault: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The scheme's Run action passes `--from`; this is the fallback for a hand run
/// inside a build environment.
func builtProducts() -> URL? {
    let products = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] ?? ""
    return products.isEmpty ? nil : URL(filePath: products)
}

func defaultSaver() -> URL? {
    let suffix = ProcessInfo.processInfo.environment["SAVER_NAME_SUFFIX"] ?? ""
    return builtProducts()?.appending(path: "Photo-Go-Round Screensaver\(suffix).saver")
}

/// The agent's bundle name does not vary by configuration — only the label
/// inside it does, which the install reads from the bundle rather than guessing.
func defaultAgent() -> URL? {
    builtProducts()?.appending(path: "Photo-Go-Round Server.app")
}

/// The appex, inside the host that carries it. **An appex registers only from
/// inside a signed app bundle** — measured 2026-09-15 — which is the whole
/// reason the host target exists.
func defaultWallpaper() -> URL? {
    builtProducts()?.appending(
        path: "Photo-Go-Round Wallpaper Host.app/Contents/Extensions/Photo-Go-Round Wallpaper.appex")
}

do {
    let options = try parse(Array(CommandLine.arguments.dropFirst()))

    switch options.command {
    case "help":
        print(usage)

    case "saver":
        guard let source = options.from ?? defaultSaver() else {
            throw Fault("no bundle named; pass --from <path>")
        }
        let plan = try SaverInstall.plan(for: source)
        if options.dryRun {
            Console.banner("would install \(plan.name).saver")
            for step in plan.describedSteps { Console.note(step) }
            break
        }
        Console.banner("installing \(plan.name).saver")
        for line in try SaverInstall.apply(plan) { Console.note(line) }

    case "agent":
        guard let source = options.from ?? defaultAgent() else {
            throw Fault("no bundle named; pass --from <path>")
        }
        let plan = try AgentInstall.plan(for: source)
        if options.dryRun {
            Console.banner("would install \(plan.label)")
            for step in plan.describedSteps { Console.note(step) }
            break
        }
        Console.banner("installing \(plan.label)")
        for line in try AgentInstall.apply(plan) { Console.note(line) }

    case "wallpaper":
        guard let source = options.from ?? defaultWallpaper() else {
            throw Fault("no bundle named; pass --from <path>")
        }
        let plan = try WallpaperInstall.plan(for: source)
        if options.dryRun {
            Console.banner("would register \(plan.identifier)")
            for step in plan.describedSteps { Console.note(step) }
            break
        }
        Console.banner("registering \(plan.identifier)")
        for line in try WallpaperInstall.apply(plan, report: { Console.note($0) }) {
            Console.note(line)
        }

    case "uninstall":
        // Naming none of the three means all of them, which is what somebody
        // typing `uninstall` on its own means.
        let parts = options.parts.isEmpty ? Set(Uninstall.Part.allCases) : options.parts
        let plan = Uninstall.plan(
            removing: parts, variants: options.variant.map { [$0] } ?? BuildVariant.allCases)
        if options.dryRun {
            Console.banner("would remove: \(parts.map(\.rawValue).sorted().joined(separator: ", "))")
            for step in plan.describedSteps { Console.note(step) }
            break
        }
        Console.banner("removing: \(parts.map(\.rawValue).sorted().joined(separator: ", "))")
        for line in try Uninstall.apply(plan) { Console.note(line) }

    case "start":
        let variant = options.variant ?? .current
        Console.banner("starting \(variant.agentLabel)")
        for line in try AgentInstall.start(variant) { Console.note(line) }

    case "stop":
        let variant = options.variant ?? .current
        Console.banner("stopping \(variant.agentLabel)")
        for line in try AgentInstall.stop(variant) { Console.note(line) }

    case let other:
        throw Fault("unknown command \(other)")
    }
} catch {
    Console.failure(String(describing: error))
    exit(1)
}
