import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd
@testable import PhotoGoRoundAgentAPI

@Suite("Command line")
struct OptionsTests {

    private func parse(_ arguments: [String], environment: [String: String] = [:]) throws -> Options {
        try Options.parse(arguments, environment: environment)
    }

    // MARK: - Running is the default

    @Test("No arguments runs the agent")
    func bareInvocationRuns() throws {
        // A program with one behaviour should not make you name the behaviour.
        let options = try parse([])
        guard case .run = options.command else {
            Issue.record("expected .run, got \(options.command)")
            return
        }
    }

    @Test("An unknown word is an error, not a silent start")
    func unknownWordFails() {
        // The failure that matters: a typo must never launch a server.
        #expect(throws: (any Error).self) { try parse(["stats"]) }
        #expect(throws: (any Error).self) { try parse(["--no-such-flag"]) }
    }

    @Test("`-h` asks for help rather than running")
    func helpIsNotARun() throws {
        for flag in ["-h", "--help"] {
            let options = try parse([flag])
            guard case .help = options.command else {
                Issue.record("\(flag) did not ask for help")
                return
            }
        }
    }

    // MARK: - Recursion belongs to the folder

    @Test("A plain folder is not walked")
    func addFolderIsNotRecursiveByDefault() throws {
        // Off by default because the surprising direction is the expensive one:
        // walking a home directory by accident costs minutes and thousands of
        // photos nobody meant to add.
        let options = try parse(["--add-folder", "/tmp/flat"])
        #expect(options.foldersToAdd.count == 1)
        #expect(options.foldersToAdd[0].recursive == false)
    }

    @Test("`--recursive` applies to the folder it precedes, and to no other")
    func recursionIsPerFolder() throws {
        let options = try parse([
            "--add-folder", "--recursive", "/tmp/tree",
            "--add-folder", "/tmp/flat",
            "--add-folder", "--recursive", "/tmp/other-tree",
        ])
        let byPath = Dictionary(
            uniqueKeysWithValues: options.foldersToAdd.map {
                ($0.url.lastPathComponent, $0.recursive)
            })
        #expect(byPath["tree"] == true)
        #expect(byPath["flat"] == false)
        #expect(byPath["other-tree"] == true)
        #expect(options.foldersToAdd.count == 3)
    }

    @Test("`-r` is the same modifier, spelled short")
    func shortRecursiveIsTheSame() throws {
        let long = try parse(["--add-folder", "--recursive", "/tmp/tree"])
        let short = try parse(["--add-folder", "-r", "/tmp/tree"])
        #expect(long.foldersToAdd.map(\.recursive) == short.foldersToAdd.map(\.recursive))
        #expect(short.foldersToAdd[0].recursive)
    }

    @Test("`--recursive` standing alone is refused rather than guessed at")
    func looseRecursiveIsAnError() {
        // It used to mean "every folder on this line", which is exactly the
        // ambiguity a per-folder modifier removes.
        #expect(throws: (any Error).self) { try parse(["-r"]) }
        #expect(throws: (any Error).self) { try parse(["--recursive", "--add-folder", "/tmp/a"]) }
        #expect(throws: (any Error).self) { try parse(["--add-folder", "/tmp/a", "-r"]) }
    }

    @Test("`--recursive` with no folder after it is an error, not a folder named --recursive")
    func recursiveNeedsAPath() {
        #expect(throws: (any Error).self) { try parse(["--add-folder", "--recursive"]) }
    }

    // MARK: - The environment forms

    @Test("PGR_FOLDERS is colon-separated, the way PATH is")
    func foldersFromEnvironment() throws {
        let options = try parse([], environment: ["PGR_FOLDERS": "/tmp/a:/tmp/b"])
        #expect(options.foldersToAdd.map(\.url.lastPathComponent) == ["a", "b"])
        #expect(options.foldersToAdd.allSatisfy { $0.recursive == false })
    }

    @Test("PGR_RECURSIVE applies to every PGR_FOLDERS entry")
    func recursiveEnvironmentApplies() throws {
        for truthy in ["1", "true", "TRUE"] {
            let options = try parse(
                [], environment: ["PGR_FOLDERS": "/tmp/a:/tmp/b", "PGR_RECURSIVE": truthy])
            #expect(options.foldersToAdd.allSatisfy { $0.recursive }, "PGR_RECURSIVE=\(truthy)")
        }
    }

    @Test("The two folder lists are independent and may both be set")
    func mixedEnvironmentLists() throws {
        // How a mixed set is expressed without inventing ordering rules.
        let options = try parse(
            [],
            environment: [
                "PGR_FOLDERS": "/tmp/flat",
                "PGR_FOLDERS_RECURSIVE": "/tmp/tree",
            ])
        let byPath = Dictionary(
            uniqueKeysWithValues: options.foldersToAdd.map {
                ($0.url.lastPathComponent, $0.recursive)
            })
        #expect(byPath["flat"] == false)
        #expect(byPath["tree"] == true)
    }

    @Test("An empty environment variable names no folders")
    func emptyEnvironmentIsNotAFolder() throws {
        let options = try parse([], environment: ["PGR_FOLDERS": "", "PGR_FOLDERS_RECURSIVE": ""])
        #expect(options.foldersToAdd.isEmpty)
    }

    // MARK: - Storage, and the flag that moves all three

    @Test("Development is the default, so a plain run cannot reach a real library")
    func developmentIsTheDefault() throws {
        #expect(try parse([]).deployment == .development)
        #expect(try parse(["--prod"]).deployment == .production)
    }

    @Test("Explicit roots are taken as given")
    func explicitRoots() throws {
        let options = try parse([
            "--container", "/tmp/c", "--cache-root", "/tmp/k", "--database", "/tmp/d/lib.sqlite",
        ])
        #expect(options.containerOverride?.path(percentEncoded: false) == "/tmp/c")
        #expect(options.cacheOverride?.path(percentEncoded: false) == "/tmp/k")
        #expect(options.databaseOverride?.path(percentEncoded: false) == "/tmp/d/lib.sqlite")
    }

    @Test("A flag that takes a value fails when the value is missing")
    func missingValuesAreErrors() {
        for flag in ["--add-folder", "--container", "--cache-root"] {
            #expect(throws: (any Error).self, "\(flag) with no value") {
                try parse([flag])
            }
        }
    }

    // MARK: - Intervals

    // MARK: - The frozen surface
    //
    // Once a LaunchAgent plist names these, they are load-bearing in a file
    // nobody re-reads. Renaming or dropping one does not break a build, does
    // not break a test that only checks behaviour, and does not fail loudly at
    // launch — the agent just comes up configured differently from what the
    // plist meant. So the accepted spellings are frozen here deliberately, and
    // this list is the thing to update *on purpose* when the surface changes.

    static let frozenFlags = [
        "--add-folder", "-r", "--recursive",
        "--prod", "--container", "--cache-root", "--database", "-d",
        "--once", "-i", "--interval", "--scan-interval", "--port", "-h", "--help",
    ]

    static let frozenEnvironment = [
        "PGR_FOLDERS", "PGR_FOLDERS_RECURSIVE", "PGR_RECURSIVE",
        "PGR_CONTAINER", "PGR_CACHE", "PGR_DATABASE", "PGR_PREFS_SUITE",
    ]

    @Test("Every frozen flag is still accepted", arguments: OptionsTests.frozenFlags)
    func frozenFlagsStillParse(flag: String) throws {
        // Three shapes: a flag taking a value, a flag modifying the folder that
        // follows it, and a flag standing alone.
        let needsValue = [
            "--add-folder", "--container", "--cache-root",
            "--database", "-d", "-i", "--interval", "--scan-interval", "--port",
        ]
        let modifiesAFolder = ["-r", "--recursive"]

        let arguments =
            if modifiesAFolder.contains(flag) {
                ["--add-folder", flag, "/tmp/frozen"]
            } else if needsValue.contains(flag) {
                [flag, valueFor(flag)]
            } else {
                [flag]
            }
        _ = try parse(arguments)
    }

    private func valueFor(_ flag: String) -> String {
        switch flag {
        case "-i", "--interval", "--scan-interval": "10"
        case "--port": "9101"
        default: "/tmp/frozen"
        }
    }

    @Test("Every frozen flag is still documented in the usage text")
    func frozenFlagsAreDocumented() {
        // A flag a launchd plist can pass but `--help` never mentions is a flag
        // nobody will know to keep.
        for flag in Self.frozenFlags {
            #expect(Options.usage.contains(flag), "\(flag) is missing from the usage text")
        }
    }

    @Test("Every frozen environment variable is still read")
    func frozenEnvironmentIsStillRead() throws {
        // launchd sets environment variables far more naturally than argv, so
        // these are the spellings most likely to be baked into a plist.
        for name in Self.frozenEnvironment {
            #expect(
                Options.usage.contains(name) || name == "PGR_PREFS_SUITE",
                "\(name) is missing from the usage text")
        }

        // And the two that decide where everything lives must still take effect.
        let options = try parse(
            [], environment: ["PGR_CONTAINER": "/tmp/c", "PGR_CACHE": "/tmp/k"])
        let environment = MacHostEnvironment(
            deployment: options.deployment,
            containerOverride: options.containerOverride,
            cacheOverride: options.cacheOverride,
            environment: ["PGR_CONTAINER": "/tmp/c", "PGR_CACHE": "/tmp/k"]
        )
        #expect(environment.databaseURL.path(percentEncoded: false) == "/tmp/c/photogoround.sqlite")
        #expect(environment.cacheRoot.path(percentEncoded: false) == "/tmp/k")
        #expect(environment.origin == .environment)
    }

    @Test("A flag on the command line still beats the same setting in the environment")
    func flagsBeatEnvironment() throws {
        let environment = MacHostEnvironment(
            deployment: .development,
            containerOverride: URL(filePath: "/tmp/flag"),
            environment: ["PGR_CONTAINER": "/tmp/env"]
        )
        #expect(environment.databaseURL.path(percentEncoded: false) == "/tmp/flag/photogoround.sqlite")
        #expect(environment.origin == .explicitOverride)
    }

    // MARK: - The service port

    @Test("The port floats unless it is pinned")
    func portOverride() throws {
        // Nothing rather than a number: the kernel is asked at launch, so there
        // is no default here to be out of step with what actually gets bound.
        #expect(try parse([]).servicePort == nil)
        #expect(try parse(["--port", "9101"]).servicePort == 9101)
    }

    @Test("`--port` refuses what is not a port")
    func portRejectsNonsense() {
        for value in ["0", "-1", "70000", "nine", ""] {
            #expect(throws: (any Error).self, "--port \(value)") {
                try parse(["--port", value])
            }
        }
        #expect(throws: (any Error).self, "--port with no value") { try parse(["--port"]) }
    }

    @Test("Intervals parse, and `--once` means one pass")
    func intervalsAndOnce() throws {
        let options = try parse(["-i", "7", "--scan-interval", "45", "--once"])
        #expect(options.interval == .seconds(7))
        #expect(options.scanIntervalOverride == .seconds(45))
        #expect(options.once)
        #expect(try parse([]).once == false)
    }
}

/// `--add-folder` writes through to preferences, and `--container` does not move
/// them. That combination reads as an isolated run and edits the real source
/// list instead.
///
/// **Found in the App Group domain on 2026-08-26**, as a folder under a session
/// scratch directory that had not existed for months — outliving the run, the
/// directory it named, and any memory of how it got there.
@Suite("Adding a folder cannot edit a source list the run is not using")
struct AddFolderGuardTests {

    @Test("A run whose storage is where preferences say may configure them")
    func ordinaryRunsWriteThrough() {
        #expect(RunCommand.mayWriteFoldersThrough(origin: .production, prefsPinned: false))
        #expect(RunCommand.mayWriteFoldersThrough(origin: .development, prefsPinned: false))
    }

    @Test("A relocated container may not, because the preferences did not move with it")
    func relocatedStorageIsRefused() {
        #expect(!RunCommand.mayWriteFoldersThrough(origin: .explicitOverride, prefsPinned: false))
        #expect(!RunCommand.mayWriteFoldersThrough(origin: .environment, prefsPinned: false))
    }

    @Test("Moving the preferences as well makes it safe again")
    func pinningThePreferencesAllowsIt() {
        // `PGR_PREFS_SUITE` is the third thing `--container` does not move, and
        // naming it is what makes a scratch run genuinely isolated.
        #expect(RunCommand.mayWriteFoldersThrough(origin: .explicitOverride, prefsPinned: true))
        #expect(RunCommand.mayWriteFoldersThrough(origin: .environment, prefsPinned: true))
    }
}
