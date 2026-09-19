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
