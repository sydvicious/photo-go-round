import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import pgr_ctl

@Suite("pgr_ctl command line")
struct OptionsTests {

    private func parse(_ arguments: [String]) throws -> Options {
        try Options.parse(arguments)
    }

    private func command(_ arguments: [String]) throws -> Options.Command {
        try parse(arguments).command
    }

    // MARK: - The shape of the grammar

    @Test("With no arguments it explains itself rather than doing something")
    func bareInvocationIsHelp() throws {
        // The inverse of the agent, and for the same reason: the agent has one
        // behaviour so it needs no word, and this has fifteen so it needs one.
        #expect(try command([]) == .help)
        #expect(try command(["-h"]) == .help)
        #expect(try command(["--help"]) == .help)
        #expect(try command(["help"]) == .help)
    }

    @Test("An unknown command is an error rather than a guess")
    func unknownCommandFails() {
        #expect(throws: (any Error).self) { try command(["stats"]) }
        #expect(throws: (any Error).self) { try command(["source", "rename"]) }
        #expect(throws: (any Error).self) { try command(["--no-such-flag"]) }
    }

    @Test("Flags may appear anywhere, including before the command")
    func flagsAreOrderIndependent() throws {
        // Positionals are collected first and interpreted last, so ordering is
        // not a rule anybody has to remember.
        let after = try command(["source", "add", "--folder", "/tmp/a", "-r"])
        let before = try command(["-r", "--folder", "/tmp/a", "source", "add"])
        #expect(after == before)
        #expect(after == .source(.add(path: "/tmp/a", kind: .folder, recursive: true)))
    }

    // MARK: - Sources

    @Test("A folder is not walked unless asked")
    func addIsNotRecursiveByDefault() throws {
        #expect(
            try command(["source", "add", "--folder", "/tmp/a"])
                == .source(.add(path: "/tmp/a", kind: .folder, recursive: false)))
    }

    @Test("`--file` pins one photo rather than a folder")
    func addAFile() throws {
        #expect(
            try command(["source", "add", "--file", "/tmp/one.heic"])
                == .source(.add(path: "/tmp/one.heic", kind: .file, recursive: false)))
    }

    @Test("`source add` with no path says so rather than adding nothing")
    func addNeedsAPath() {
        #expect(throws: (any Error).self) { try command(["source", "add"]) }
    }

    @Test("`source` on its own lists, which is the harmless reading")
    func bareSourceLists() throws {
        #expect(try command(["source"]) == .source(.list))
        #expect(try command(["source", "list"]) == .source(.list))
    }

    @Test("The verbs that take an id demand one")
    func idVerbsNeedAnID() throws {
        #expect(try command(["source", "remove", "3"]) == .source(.remove(id: 3)))
        #expect(try command(["source", "enable", "3"]) == .source(.enable(id: 3)))
        #expect(try command(["source", "disable", "3"]) == .source(.disable(id: 3)))
        for verb in ["remove", "enable", "disable"] {
            #expect(throws: (any Error).self, "source \(verb)") {
                try command(["source", verb])
            }
            #expect(throws: (any Error).self, "source \(verb) notanumber") {
                try command(["source", verb, "wat"])
            }
        }
    }

    @Test("Refresh is everything, or one source")
    func refreshScope() throws {
        #expect(try command(["refresh"]) == .refresh(sourceID: nil))
        #expect(try command(["refresh", "--source", "7"]) == .refresh(sourceID: 7))
    }

    // MARK: - The rest of the surface

    @Test("Each family defaults to its harmless verb")
    func bareFamiliesAreTheReadOnlyOne() throws {
        #expect(try command(["pool"]) == .poolStats)
        #expect(try command(["queue"]) == .queuePeek)
        #expect(try command(["deck"]) == .deckStats)
        #expect(try command(["cache"]) == .cache(.status))
    }

    @Test("Queue has a filling verb as well as a looking one")
    func queueVerbs() throws {
        #expect(try command(["queue", "peek"]) == .queuePeek)
        #expect(try command(["queue", "fill"]) == .queueFill)
    }

    @Test("Clearing the cache is scoped, and everything is the default")
    func cacheClearScopes() throws {
        #expect(try command(["cache", "clear"]) == .cache(.clear(scope: .everything, confirmed: false)))
        #expect(
            try command(["cache", "clear", "--source", "4"])
                == .cache(.clear(scope: .source(4), confirmed: false)))
        #expect(
            try command(["cache", "clear", "--unavailable"])
                == .cache(.clear(scope: .unavailable, confirmed: false)))
        // The most specific scope wins, so naming a source is never widened
        // into a whole-cache clear by another flag.
        #expect(
            try command(["cache", "clear", "--source", "4", "--unavailable"])
                == .cache(.clear(scope: .source(4), confirmed: false)))
        #expect(
            try command(["cache", "clear", "--yes"])
                == .cache(.clear(scope: .everything, confirmed: true)))
    }

    @Test("Preferences read one key or all of them, and write one at a time")
    func preferenceVerbs() throws {
        #expect(try command(["get"]) == .getPreferences(key: nil))
        #expect(try command(["get", "queueSize"]) == .getPreferences(key: "queueSize"))
        #expect(try command(["set", "queueSize", "500"]) == .setPreference(key: "queueSize", value: "500"))
        #expect(throws: (any Error).self) { try command(["set", "queueSize"]) }
    }

    @Test("Doorbells are rung by name")
    func notifyTakesATopic() throws {
        #expect(try command(["notify", "sources"]) == .notify(topic: "sources"))
        #expect(throws: (any Error).self) { try command(["notify"]) }
    }

    @Test("The service verbs survived the move out of the agent")
    func serviceVerbs() throws {
        #expect(try command(["register"]) == .service(.register))
        #expect(try command(["unregister"]) == .service(.unregister))
        #expect(try command(["service-status"]) == .service(.status))
    }

    // MARK: - Values

    @Test("Counts, windows, and sizes are parsed and rejected on sight")
    func numericOptions() throws {
        #expect(try parse(["serve", "-n", "100"]).count == 100)
        #expect(try parse(["serve", "--count", "100"]).count == 100)
        #expect(try parse(["serve", "-w", "1.0"]).repeatWindowFraction == 1.0)
        #expect(try parse(["shuffle-test", "--deals", "10", "--photos", "5"]).deals == 10)
        #expect(try parse(["shuffle-test", "--deals", "10", "--photos", "5"]).photos == 5)

        #expect(throws: (any Error).self) { try parse(["serve", "-n", "0"]) }
        #expect(throws: (any Error).self) { try parse(["serve", "-n", "wat"]) }
        #expect(throws: (any Error).self) { try parse(["serve", "-w", "2"]) }
        #expect(throws: (any Error).self) { try parse(["serve", "-w", "-1"]) }
    }

    @Test("Defaults are the plan's numbers")
    func defaults() throws {
        let options = try parse(["shuffle-test"])
        #expect(options.deals == 50_000)
        #expect(options.photos == 4_000)
        #expect(options.repeatWindowFraction == DeckSettings.defaultRepeatWindowFraction)
        #expect(try parse(["serve"]).consumerName == "cli")
        #expect(try parse(["serve"]).count == 10)
    }

    @Test("A flag that takes a value fails when the value is missing")
    func missingValuesAreErrors() {
        for flag in [
            "--container", "--database", "--cache", "--folder", "--file", "--source",
            "--count", "--consumer", "--window", "--deals", "--photos", "--last",
        ] {
            #expect(throws: (any Error).self, "\(flag) with no value") { try parse([flag]) }
        }
    }

    // MARK: - Storage

    @Test("Development is the default here too, so a plain run cannot reach a real library")
    func developmentIsTheDefault() throws {
        #expect(try parse(["status"]).deployment == .development)
        #expect(try parse(["status", "--prod"]).deployment == .production)
    }

    @Test("Explicit roots are taken as given")
    func explicitRoots() throws {
        let options = try parse([
            "status", "--container", "/tmp/c", "--cache", "/tmp/k", "-d", "/tmp/d/lib.sqlite",
        ])
        #expect(options.containerOverride?.path(percentEncoded: false) == "/tmp/c")
        #expect(options.cacheOverride?.path(percentEncoded: false) == "/tmp/k")
        #expect(options.databaseOverride?.path(percentEncoded: false) == "/tmp/d/lib.sqlite")
    }

    // MARK: - Documentation

    @Test("Every command word appears in the usage text")
    func everyCommandIsDocumented() {
        // A subcommand `--help` never mentions is a subcommand nobody will find.
        let words = [
            "status", "source add", "source list", "source remove", "source enable",
            "refresh", "pool stats", "queue peek", "queue fill", "serve", "deck stats",
            "cache status", "cache evict", "cache clear", "shuffle-test", "get", "set",
            "notify", "log", "register", "unregister", "service-status",
        ]
        for word in words {
            #expect(Options.usage.contains(word), "\(word) is missing from the usage text")
        }
    }

    @Test("Every flag the parser accepts appears in the usage text")
    func everyFlagIsDocumented() {
        let flags = [
            "--prod", "--container", "--database", "--cache", "--folder", "--file",
            "--recursive", "--source", "--unavailable", "--yes", "--count", "--consumer",
            "--quiet", "--window", "--deals", "--photos", "--follow", "--last", "--help",
        ]
        for flag in flags {
            #expect(Options.usage.contains(flag), "\(flag) is missing from the usage text")
        }
    }
}
