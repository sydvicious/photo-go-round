import Foundation
import PhotoGoRoundKit

// The headless agent. It owns the library and does all the work; every other
// surface is a consumer that reads the deck and displays cards.
//
// The continuous loop, preference watching, prefetching and eviction arrive in
// the last slice of Phase 1. What is here now is `watch`, which exists to make
// the library observable with a real folder before there is a command-line tool
// or a window.

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

    case .watch(let folder):
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory
            ), isDirectory.boolValue
        else {
            Console.failure("not a folder: \(folder.path(percentEncoded: false))")
            exit(1)
        }

        try FileManager.default.createDirectory(
            at: URL(filePath: options.databasePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        Log.sources.notice("PhotoGoRoundServer starting in watch mode")
        try await WatchCommand(
            folder: folder,
            databasePath: options.databasePath,
            interval: options.interval,
            recursive: options.recursive,
            deal: options.deal,
            repeatWindowFraction: options.repeatWindowFraction
        ).run()

    case .run:
        Log.sources.notice("PhotoGoRoundServer starting")
        try await RunCommand(
            environment: MacHostEnvironment(
                containerOverride: options.containerOverride,
                databaseOverride: options.databaseOverride,
                cacheOverride: options.cacheOverride
            ),
            foldersToAdd: options.foldersToAdd,
            recursive: options.recursive,
            tick: options.interval,
            once: options.once
        ).run()
    }
} catch {
    Console.failure(String(describing: error))
    exit(1)
}
