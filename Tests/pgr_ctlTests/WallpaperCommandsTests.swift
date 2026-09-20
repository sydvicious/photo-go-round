import Foundation
import PhotoGoRoundAgentAPI
import PhotoGoRoundDisplay
import Testing

@testable import pgr_ctl

@Suite("pgr_ctl wallpaper preferences")
struct WallpaperCommandsTests {

    /// A throwaway defaults suite, so a test never writes the wallpaper
    /// preferences of whoever is running it. Same shape as the agent's
    /// preference tests, and torn down the same way.
    private final class Scratch {
        let name = scratchSuiteName("wallpaper-commands")
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }

        deinit { discardScratchSuite(name) }
    }

    /// `Documentation/pgr_ctl.md`, `wallpaper get`: "The domain carries the
    /// build configuration as the library does."
    ///
    /// **It did not, until 2026-09-19.** Both call sites took the running
    /// build's variant, so `--debug` from a Claude-built `pgr_ctl` wrote
    /// `com.sydpolk.photogoround.claude.wallpaper.dev` and the Debug extension
    /// never saw the change. Nothing said so: the write succeeded.
    @Test(
        "The domain carries both the deployment and the build configuration",
        arguments: [
            (BuildVariant.release, "com.sydpolk.photogoround.wallpaper"),
            (.debug, "com.sydpolk.photogoround.debug.wallpaper"),
            (.claude, "com.sydpolk.photogoround.claude.wallpaper"),
        ])
    func domainCarriesBothAxes(_ pair: (BuildVariant, String)) {
        let (variant, stem) = pair
        #expect(WallpaperCommands.domain(deployment: .development, variant: variant) == "\(stem).dev")
        #expect(WallpaperCommands.domain(deployment: .production, variant: variant) == "\(stem).prod")
    }

    @Test("An unset interval reports what the wallpaper would use")
    func unsetReportsTheDefault() {
        let scratch = Scratch()
        #expect(
            WallpaperCommands.value(of: .interval, in: scratch.defaults)
                == WallpaperPreferences.defaultInterval.rawValue)
    }

    @Test("What was set is what is read back, by this and by the wallpaper")
    func setThenGet() throws {
        let scratch = Scratch()
        try WallpaperCommands.set(key: "interval", value: "thirtyMinutes", domain: scratch.name)
        #expect(WallpaperCommands.value(of: .interval, in: scratch.defaults) == "thirtyMinutes")
        #expect(WallpaperPreferences(domain: scratch.name).interval == .thirtyMinutes)
    }

    /// The app writes the tag, not seconds, so anything else would be read back
    /// as the default by every surface and the setting would look ignored.
    @Test("An interval that is not a Shuffle All tag is refused")
    func intervalMustBeATag() {
        let scratch = Scratch()
        #expect(throws: (any Error).self) {
            try WallpaperCommands.set(key: "interval", value: "1800", domain: scratch.name)
        }
        #expect(scratch.defaults.object(forKey: "interval") == nil)
    }

    /// `enabled` and `displays` were keys until the app's own loop went,
    /// 2026-09-16; they are refused like any other unknown key.
    @Test("Unknown keys are refused, reading and writing")
    func refusals() {
        let scratch = Scratch()
        #expect(throws: (any Error).self) {
            try WallpaperCommands.set(key: "queueSize", value: "20", domain: scratch.name)
        }
        #expect(throws: (any Error).self) {
            try WallpaperCommands.set(key: "enabled", value: "true", domain: scratch.name)
        }
        #expect(throws: (any Error).self) { try WallpaperCommands.get(key: "displays", domain: scratch.name) }
    }

    /// The domain the app writes and the extension reads, spelled once.
    @Test("The domain follows the deployment")
    func domainFollowsDeployment() {
        // Spelled from the storage identifier so this holds in every build
        // configuration; `BuildVariantTests` pins the suffixes themselves.
        #expect(
            WallpaperPreferences(deployment: .development).domain
                == "\(Deployment.storageIdentifier()).wallpaper.dev")
        #expect(
            WallpaperPreferences(deployment: .production).domain
                == "\(Deployment.storageIdentifier()).wallpaper.prod")
    }
}
