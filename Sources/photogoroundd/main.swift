import Console
import Foundation
import PhotoGoRoundKit

// The headless agent. It owns the library and does all the work; every other
// surface is a consumer that reads the deck and displays cards.
//
// **Running is the whole program, so it takes no command word.** A service that
// also answers questions is a service with two jobs, and the second one grows:
// first a status verb, then a way to add a source, then a way to change a
// preference, and the thing that is supposed to run unattended for a week has an
// interactive surface nobody is watching. Everything it needs to know arrives
// before it starts; everything anybody wants to ask is answered by `pgr_ctl`,
// which opens the same database and rings the doorbell when it changes
// something.
//
// An unrecognised word is still an error rather than a silent start, so a typo
// cannot launch a server by accident.

// Line buffering, not block buffering. stdout is fully buffered whenever it is
// not a terminal, so a watcher piped to a file or captured by launchd would
// otherwise emit nothing until the buffer filled — and lose it entirely on
// SIGTERM, which is exactly how this process ends.
setvbuf(stdout, nil, _IOLBF, 0)

do {
    let options = try Options.parse(
        Array(CommandLine.arguments.dropFirst()),
        environment: ProcessInfo.processInfo.environment
    )

    switch options.command {
    case .help:
        print(Options.usage)

    case .run:
        Log.sources.notice("photogoroundd starting")
        try await RunCommand(
            environment: MacHostEnvironment(
                deployment: options.deployment,
                containerOverride: options.containerOverride,
                databaseOverride: options.databaseOverride,
                cacheOverride: options.cacheOverride
            ),
            foldersToAdd: options.foldersToAdd,
            recursive: options.recursive,
            tick: options.interval,
            once: options.once,
            scanIntervalOverride: options.scanIntervalOverride,
            servicePort: options.servicePort
        ).run()
    }
} catch {
    Console.failure(String(describing: error))
    exit(1)
}
