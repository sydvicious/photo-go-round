import Foundation
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

    @Test("An unset preference reports what the wallpaper would use")
    func unsetReportsTheDefault() {
        let scratch = Scratch()
        #expect(WallpaperCommands.value(of: .enabled, in: scratch.defaults) == "false")
        #expect(WallpaperCommands.value(of: .interval, in: scratch.defaults) == Wallpaper.defaultInterval.rawValue)
        #expect(WallpaperCommands.value(of: .displays, in: scratch.defaults) == "none recorded")
    }

    @Test("What was set is what is read back")
    func setThenGet() throws {
        let scratch = Scratch()
        try WallpaperCommands.set(key: "interval", value: "thirtyMinutes", domain: scratch.name)
        try WallpaperCommands.set(key: "enabled", value: "true", domain: scratch.name)
        #expect(WallpaperCommands.value(of: .interval, in: scratch.defaults) == "thirtyMinutes")
        #expect(WallpaperCommands.value(of: .enabled, in: scratch.defaults) == "true")
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

    @Test("Unknown keys are refused, and the wallpaper's own record cannot be written")
    func refusals() {
        let scratch = Scratch()
        #expect(throws: (any Error).self) {
            try WallpaperCommands.set(key: "queueSize", value: "20", domain: scratch.name)
        }
        #expect(throws: (any Error).self) {
            try WallpaperCommands.set(key: "displays", value: "{}", domain: scratch.name)
        }
        #expect(throws: (any Error).self) { try WallpaperCommands.get(key: "queueSize", domain: scratch.name) }
    }

    /// The domain the app writes and every wallpaper reads, spelled once.
    @Test("The domain follows the deployment")
    func domainFollowsDeployment() {
        #expect(WallpaperHome(deployment: .development).domain == "com.sydpolk.photogoround.wallpaper.dev")
        #expect(WallpaperHome(deployment: .production).domain == "com.sydpolk.photogoround.wallpaper.prod")
    }

    @Test("A display the wallpaper recorded is listed")
    func displaysAreListed() {
        let scratch = Scratch()
        scratch.defaults.set(["37D8832A": ["changedAt": Date(), "file": "/tmp/a.heic"]], forKey: "displays")
        #expect(WallpaperCommands.value(of: .displays, in: scratch.defaults) == "37D8832A")
    }
}
