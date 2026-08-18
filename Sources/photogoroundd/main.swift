import Foundation
import PhotoGoRoundKit

// The headless agent. It owns the library and does all the work; every other
// surface is a consumer that reads the deck and displays cards.
//
// Running is the whole program, so it takes no command word: the agent is
// configured, not commanded. The inspect subcommands below exist only so it can
// be stood up and looked at from a terminal before `pgr_ctl` arrives in Phase 2,
// and they leave with it.

// Line buffering, not block buffering. stdout is fully buffered whenever it is
// not a terminal, so a watcher piped to a file or captured by launchd would
// otherwise emit nothing until the buffer filled — and lose it entirely on
// SIGTERM, which is exactly how this process ends.
setvbuf(stdout, nil, _IOLBF, 0)

func hostEnvironment(_ options: Options) -> MacHostEnvironment {
    MacHostEnvironment(
        deployment: options.deployment,
        containerOverride: options.containerOverride,
        databaseOverride: options.databaseOverride,
        cacheOverride: options.cacheOverride
    )
}

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
            environment: hostEnvironment(options),
            foldersToAdd: options.foldersToAdd,
            recursive: options.recursive,
            tick: options.interval,
            once: options.once,
            scanIntervalOverride: options.scanIntervalOverride
        ).run()

    case .serve:
        try await ServeCommand(
            environment: hostEnvironment(options),
            consumerName: options.consumerName,
            count: options.count,
            repeatWindowFraction: options.repeatWindowFraction,
            quiet: options.quiet
        ).run()

    case .source(let action):
        try await InspectCommands.source(action, environment: hostEnvironment(options))

    case .status:
        try InspectCommands.status(environment: hostEnvironment(options))

    case .queuePeek:
        try InspectCommands.queuePeek(count: options.count, environment: hostEnvironment(options))

    case .queueFill:
        try await InspectCommands.queueFill(rounds: options.count, environment: hostEnvironment(options))

    case .getPreferences:
        InspectCommands.get(environment: hostEnvironment(options))

    case .setPreference(let key, let value):
        try InspectCommands.set(key: key, value: value, environment: hostEnvironment(options))

    case .service(let action):
        try ServiceCommand(action: action).run()
    }
} catch let requested as ExitCode {
    exit(requested.code)
} catch {
    Console.failure(String(describing: error))
    exit(1)
}
