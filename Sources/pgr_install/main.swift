import Console
import Foundation
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

OPTIONS
  --from <path>   The built bundle. Defaults to $BUILT_PRODUCTS_DIR's copy,
                  which is what an Install scheme passes.
  --dry-run       Print what would happen and change nothing.
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
func defaultSaver() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    guard let products = environment["BUILT_PRODUCTS_DIR"], !products.isEmpty else { return nil }
    let suffix = environment["SAVER_NAME_SUFFIX"] ?? ""
    return URL(filePath: products).appending(path: "Photo-Go-Round Screensaver\(suffix).saver")
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
        Console.note("Photos access is granted in the app, not here")

    case let other:
        throw Fault("unknown command \(other)")
    }
} catch {
    Console.failure(String(describing: error))
    exit(1)
}
