import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd

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

    @Test("`--add-folder-recursive` walks that folder and only that folder")
    func perFolderRecursion() throws {
        let options = try parse([
            "--add-folder", "/tmp/flat",
            "--add-folder-recursive", "/tmp/tree",
        ])
        let byPath = Dictionary(
            uniqueKeysWithValues: options.foldersToAdd.map {
                ($0.url.lastPathComponent, $0.recursive)
            })
        #expect(byPath["flat"] == false)
        #expect(byPath["tree"] == true)
    }

    @Test("`-r` applies to every plain folder, wherever it appears")
    func recursiveFlagAppliesToPlainFolders() throws {
        // It may follow the paths it applies to, so the folders cannot be
        // resolved until every argument has been seen.
        let options = try parse(["--add-folder", "/tmp/a", "--add-folder", "/tmp/b", "-r"])
        #expect(options.foldersToAdd.count == 2)
        #expect(options.foldersToAdd.allSatisfy { $0.recursive })
    }

    @Test("`--add-folder-recursive` is recursive with or without `-r`")
    func explicitRecursionDoesNotDependOnOrdering() throws {
        let without = try parse(["--add-folder-recursive", "/tmp/tree"])
        #expect(without.foldersToAdd[0].recursive == true)

        let with = try parse(["--add-folder-recursive", "/tmp/tree", "-r"])
        #expect(with.foldersToAdd[0].recursive == true)
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
            "--container", "/tmp/c", "--cache", "/tmp/k", "--database", "/tmp/d/lib.sqlite",
        ])
        #expect(options.containerOverride?.path(percentEncoded: false) == "/tmp/c")
        #expect(options.cacheOverride?.path(percentEncoded: false) == "/tmp/k")
        #expect(options.databaseOverride?.path(percentEncoded: false) == "/tmp/d/lib.sqlite")
    }

    @Test("A flag that takes a value fails when the value is missing")
    func missingValuesAreErrors() {
        for flag in ["--add-folder", "--add-folder-recursive", "--container", "--cache"] {
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
        "--add-folder", "--add-folder-recursive", "-r", "--recursive",
        "--prod", "--container", "--cache", "--database", "-d",
        "--once", "-i", "--interval", "--scan-interval", "-h", "--help",
    ]

    static let frozenEnvironment = [
        "PGR_FOLDERS", "PGR_FOLDERS_RECURSIVE", "PGR_RECURSIVE",
        "PGR_CONTAINER", "PGR_CACHE", "PGR_DATABASE", "PGR_PREFS_SUITE",
    ]

    @Test("Every frozen flag is still accepted", arguments: OptionsTests.frozenFlags)
    func frozenFlagsStillParse(flag: String) throws {
        // Flags taking a value get a plausible one; the rest stand alone.
        let needsValue = [
            "--add-folder", "--add-folder-recursive", "--container", "--cache",
            "--database", "-d", "-i", "--interval", "--scan-interval",
        ]
        let arguments = needsValue.contains(flag) ? [flag, valueFor(flag)] : [flag]
        _ = try parse(arguments)
    }

    private func valueFor(_ flag: String) -> String {
        switch flag {
        case "-i", "--interval", "--scan-interval": "10"
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
        #expect(environment.databaseURL.path(percentEncoded: false) == "/tmp/c/library.sqlite")
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
        #expect(environment.databaseURL.path(percentEncoded: false) == "/tmp/flag/library.sqlite")
        #expect(environment.origin == .explicitOverride)
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
