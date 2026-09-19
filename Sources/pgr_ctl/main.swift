import Console
import Foundation
import PhotoGoRoundKit
import PhotoGoRoundAgentAPI
import PhotoGoRoundDisplay

// The rig.
//
// A separate binary from the agent, because the service has exactly one job and
// answering questions is not it — and because the database is the transport, so
// nothing here needs the agent's cooperation or even its presence.
//
// It is internal and never ships: no signing pipeline, no man page beyond the
// one in Documentation, and no compatibility promise. Being unshipped is not the
// same as being a scratch script, though — `shuffle-test` holds the project's
// real correctness checks for the deck.

setvbuf(stdout, nil, _IOLBF, 0)

func hostEnvironment(_ options: Options) -> MacHostEnvironment {
    MacHostEnvironment(
        deployment: options.deployment,
        variant: options.variant,
        containerOverride: options.containerOverride,
        databaseOverride: options.databaseOverride,
        cacheOverride: options.cacheOverride
    )
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))

    switch options.command {
    case .help:
        print(Options.usage)

    case .status:
        try await InspectCommands.status(environment: hostEnvironment(options))

    case .source(let action):
        try await SourceCommands.run(action, environment: hostEnvironment(options))

    case .refresh(let sourceID):
        try await SourceCommands.refresh(sourceID: sourceID, environment: hostEnvironment(options))

    case .poolStats:
        try await InspectCommands.poolStats(environment: hostEnvironment(options))

    case .queuePeek:
        try await InspectCommands.queuePeek(
            count: options.count, all: !options.countWasGiven,
            environment: hostEnvironment(options))

    case .queueFill:
        try await InspectCommands.queueFill(
            rounds: options.count, environment: hostEnvironment(options))

    case .deckStats:
        try await InspectCommands.deckStats(environment: hostEnvironment(options))

    case .cache(.status):
        try await InspectCommands.cacheStatus(environment: hostEnvironment(options))

    case .cache(.evict):
        try await InspectCommands.cacheEvict(environment: hostEnvironment(options))

    case .cache(.clear(let scope, let confirmed)):
        try await InspectCommands.cacheClear(
            scope: scope, confirmed: confirmed, environment: hostEnvironment(options))

    case .shuffleTest:
        try await ShuffleTest.run(
            photos: options.photos, deals: options.deals,
            fraction: options.repeatWindowFraction)

    case .getPreferences(let key):
        try await PreferenceCommands.get(
            key: key, showDefaults: !options.noDefaultValues,
            environment: hostEnvironment(options))

    case .setPreference(let key, let value):
        try await PreferenceCommands.set(key: key, value: value, environment: hostEnvironment(options))

    case .wallpaper(.get(let key)):
        try WallpaperCommands.get(key: key, domain: WallpaperPreferences(deployment: options.deployment).domain)

    case .wallpaper(.set(let key, let value)):
        try WallpaperCommands.set(
            key: key, value: value, domain: WallpaperPreferences(deployment: options.deployment).domain)

    case .notify(let topic):
        try NotifyCommand.run(topic: topic, environment: hostEnvironment(options))

    case .log:
        try await LogCommand.run(follow: options.follow, last: options.lastInterval)

    case .service(let action):
        try ServiceCommand(action: action).run()
    }
} catch let requested as ExitCode {
    exit(requested.code)
} catch {
    Console.failure(String(describing: error))
    exit(1)
}
