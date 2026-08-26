import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import pgr_ctl
@testable import PhotoGoRoundAgentAPI

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
        #expect(throws: (any Error).self) { try command(["sources", "rename"]) }
        #expect(throws: (any Error).self) { try command(["--no-such-flag"]) }
    }

    @Test("Flags may appear anywhere, including before the command")
    func flagsAreOrderIndependent() throws {
        // Positionals are collected first and interpreted last, so ordering is
        // not a rule anybody has to remember.
        let after = try command(["sources", "add", "--folder", "--recursive", "/tmp/a"])
        let before = try command(["--folder", "--recursive", "/tmp/a", "sources", "add"])
        #expect(after == before)
        #expect(
            after
                == .source(.add([.init(path: "/tmp/a", kind: .folder, recursive: true)])))
    }

    // MARK: - Sources

    @Test("A folder is not walked unless asked")
    func addIsNotRecursiveByDefault() throws {
        #expect(
            try command(["sources", "add", "--folder", "/tmp/a"])
                == .source(.add([.init(path: "/tmp/a", kind: .folder, recursive: false)])))
    }

    @Test("An album is added by identifier, and its slashes are not path separators")
    func addAnAlbum() throws {
        // `PHAssetCollection.localIdentifier` has the form `UUID/L0/040`. It
        // reaches the store as typed: no standardizing, no trailing slash, no
        // question about whether it is a directory.
        let identifier = "DAD90FB7-1F24-463E-8688-A8504D7283C7/L0/040"
        #expect(
            try command(["sources", "add", "--album", identifier])
                == .source(.add([.init(path: identifier, kind: .photosCollection, recursive: false)])))
    }

    @Test("A folder and an album can be named in one command")
    func albumsMixWithFolders() throws {
        #expect(
            try command(["sources", "add", "--folder", "/tmp/a", "--album", "ALBUM/L0/040"])
                == .source(
                    .add([
                        .init(path: "/tmp/a", kind: .folder, recursive: false),
                        .init(path: "ALBUM/L0/040", kind: .photosCollection, recursive: false),
                    ])))
    }

    @Test("`--file` pins one photo rather than a folder")
    func addAFile() throws {
        #expect(
            try command(["sources", "add", "--file", "/tmp/one.heic"])
                == .source(.add([.init(path: "/tmp/one.heic", kind: .file, recursive: false)])))
    }

    @Test("Several sources can be named in one command, each with its own answer")
    func addIsRepeatable() throws {
        let parsed = try command([
            "sources", "add",
            "--folder", "--recursive", "/tmp/tree",
            "--folder", "/tmp/flat",
            "--file", "/tmp/one.heic",
        ])
        #expect(
            parsed
                == .source(
                    .add([
                        .init(path: "/tmp/tree", kind: .folder, recursive: true),
                        .init(path: "/tmp/flat", kind: .folder, recursive: false),
                        .init(path: "/tmp/one.heic", kind: .file, recursive: false),
                    ])))
    }

    @Test("`--recursive` standing alone is refused rather than guessed at")
    func looseRecursiveIsAnError() {
        #expect(throws: (any Error).self) { try command(["sources", "add", "-r"]) }
        #expect(throws: (any Error).self) {
            try command(["sources", "add", "--folder", "/tmp/a", "-r"])
        }
    }

    @Test("`sources add` with no path says so rather than adding nothing")
    func addNeedsAPath() {
        #expect(throws: (any Error).self) { try command(["sources", "add"]) }
    }

    @Test("`sources` on its own lists, which is the harmless reading")
    func bareSourceLists() throws {
        #expect(try command(["sources"]) == .source(.list))
        #expect(try command(["sources", "list"]) == .source(.list))
    }

    @Test("The verbs that take an id demand one")
    func idVerbsNeedAnID() throws {
        #expect(try command(["sources", "remove", "3"]) == .source(.remove(id: 3)))
        #expect(try command(["sources", "enable", "3"]) == .source(.enable(id: 3)))
        #expect(try command(["sources", "disable", "3"]) == .source(.disable(id: 3)))
        for verb in ["remove", "enable", "disable"] {
            #expect(throws: (any Error).self, "sources \(verb)") {
                try command(["sources", verb])
            }
            #expect(throws: (any Error).self, "source \(verb) notanumber") {
                try command(["sources", verb, "wat"])
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
        #expect(try parse(["get"]).noDefaultValues == false)
        #expect(try parse(["get", "--no-default-values"]).noDefaultValues)
        #expect(try parse(["get", "queueSize", "--no-default-values"]).noDefaultValues)
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
        #expect(try parse(["queue", "peek", "-n", "100"]).count == 100)
        #expect(try parse(["queue", "peek", "--count", "100"]).count == 100)
        #expect(try parse(["shuffle-test", "-w", "1.0"]).repeatWindowFraction == 1.0)
        #expect(try parse(["shuffle-test", "--deals", "10", "--photos", "5"]).deals == 10)
        #expect(try parse(["shuffle-test", "--deals", "10", "--photos", "5"]).photos == 5)

        #expect(throws: (any Error).self) { try parse(["queue", "peek", "-n", "0"]) }
        #expect(throws: (any Error).self) { try parse(["queue", "peek", "-n", "wat"]) }
        #expect(throws: (any Error).self) { try parse(["shuffle-test", "-w", "2"]) }
        #expect(throws: (any Error).self) { try parse(["shuffle-test", "-w", "-1"]) }
    }

    @Test("Defaults are the plan's numbers")
    func defaults() throws {
        let options = try parse(["shuffle-test"])
        #expect(options.deals == 50_000)
        #expect(options.photos == 4_000)
        #expect(options.repeatWindowFraction == DeckSettings.defaultRepeatWindowFraction)
        #expect(try parse(["queue", "peek"]).count == 10)
    }

    @Test("A flag that takes a value fails when the value is missing")
    func missingValuesAreErrors() {
        for flag in [
            "--container", "--database", "--cache-root", "--folder", "--file", "--source",
            "--count", "--window", "--deals", "--photos", "--last",
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
            "status", "--container", "/tmp/c", "--cache-root", "/tmp/k", "-d", "/tmp/d/lib.sqlite",
        ])
        #expect(options.containerOverride?.path(percentEncoded: false) == "/tmp/c")
        #expect(options.cacheOverride?.path(percentEncoded: false) == "/tmp/k")
        #expect(options.databaseOverride?.path(percentEncoded: false) == "/tmp/d/lib.sqlite")
    }

    // MARK: - The Photos spike

    @Test("The spike takes a count and an album, and defaults to neither")
    func photosSpikeParses() throws {
        #expect(try command(["photos-spike"]) == .photosSpike)
        #expect(try parse(["photos-spike"]).albumIdentifier == nil)

        let aimed = try parse(["photos-spike", "-n", "20", "--album", "Favorites"])
        #expect(aimed.command == .photosSpike)
        #expect(aimed.count == 20)
        #expect(aimed.albumIdentifier == "Favorites")
    }

    @Test("The availability probe has its own sample size, separate from the pulls")
    func probeCountIsSeparate() throws {
        // They measure different things: `-n` fetches originals and costs
        // minutes, `--probe` only asks whether they are here and costs
        // milliseconds. One number for both would price the cheap one like the
        // expensive one.
        #expect(try parse(["photos-spike"]).probeCount == 200)
        #expect(try parse(["photos-spike"]).listAlbums == false)
        #expect(try parse(["photos-spike", "--albums"]).listAlbums)

        let both = try parse(["photos-spike", "-n", "6", "--probe", "500"])
        #expect(both.count == 6)
        #expect(both.probeCount == 500)
    }

    @Test("An album identifier survives the slashes PhotoKit puts in one")
    func albumIdentifiersAreOpaque() throws {
        // `PHAssetCollection.localIdentifier` has the form `UUID/L0/040`. It is
        // an opaque string here and nothing may treat it as a path.
        let identifier = "A1B2C3D4-0000-1111-2222-333344445555/L0/040"
        #expect(try parse(["photos-spike", "--album", identifier]).albumIdentifier == identifier)
    }

    @Test("`--album` without a value is an error rather than a silent default")
    func albumNeedsAValue() {
        #expect(throws: (any Error).self) { try parse(["photos-spike", "--album"]) }
    }

    // MARK: - Documentation

    @Test("Every command word appears in the usage text")
    func everyCommandIsDocumented() {
        // A subcommand `--help` never mentions is a subcommand nobody will find.
        let words = [
            "status", "sources add", "sources list", "sources remove", "sources enable",
            "refresh", "pool stats", "queue peek", "queue fill", "deck stats",
            "cache status", "cache evict", "cache clear", "shuffle-test", "photos-spike",
            "get", "set",
            "notify", "log", "register", "unregister", "service-status",
        ]
        for word in words {
            #expect(Options.usage.contains(word), "\(word) is missing from the usage text")
        }
    }

    @Test("Every flag the parser accepts appears in the usage text")
    func everyFlagIsDocumented() {
        let flags = [
            "--prod", "--container", "--database", "--cache-root", "--folder", "--file",
            "--recursive", "--source", "--unavailable", "--yes", "--count", "--no-default-values",
            "--window", "--deals", "--photos", "--album", "--albums", "--probe", "--follow",
            "--last",
            "--help",
        ]
        for flag in flags {
            #expect(Options.usage.contains(flag), "\(flag) is missing from the usage text")
        }
    }
}
