import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundDisplay

/// The wallpaper's *Shuffle All* preference, which the app and `pgr_ctl` write
/// and the wallpaper extension reads.
@Suite("The wallpaper's preferences")
struct WallpaperPreferencesTests {

    @Test("Each deployment has its own wallpaper domain, beside the screensaver's")
    func domainFollowsDeployment() {
        // Spelled from the storage identifier so this holds in every build
        // configuration; `BuildVariantTests` pins the suffixes themselves.
        #expect(
            WallpaperPreferences(deployment: .development).domain
                == "\(Deployment.storageIdentifier()).wallpaper.dev")
        #expect(
            WallpaperPreferences(deployment: .production).domain
                == "\(Deployment.storageIdentifier()).wallpaper.prod")
        #expect(
            WallpaperPreferences(deployment: .development).domain
                != ScreensaverPreferences(deployment: .development).domain)
    }

    /// Syd, 2026-09-14: "wallpaper will default to "1 hour"."
    @Test("Nothing chosen is an hour")
    func nothingChosenIsAnHour() {
        let name = scratchSuiteName("wallpaper-preferences")
        defer { discardScratchSuite(name) }
        let preferences = WallpaperPreferences(domain: name)
        #expect(preferences.read() == .unset)
        #expect(preferences.interval == .oneHour)
    }

    /// Syd, 2026-09-14: "the preference should store enum tags for the values."
    @Test("A choice is written as its tag and read back from the suite")
    func choiceIsWrittenAsTheTag() {
        let name = scratchSuiteName("wallpaper-preferences")
        defer { discardScratchSuite(name) }
        let preferences = WallpaperPreferences(domain: name)
        preferences.set(.twoHours)

        #expect(UserDefaults(suiteName: name)?.string(forKey: "interval") == "twoHours")
        #expect(preferences.read() == .set(.twoHours, from: .suite))
        #expect(preferences.interval == .twoHours)
    }

    @Test("Anything that is not a tag is the default, never a guess")
    func intervalIsValidated() {
        let name = scratchSuiteName("wallpaper-preferences")
        defer { discardScratchSuite(name) }
        let defaults = UserDefaults(suiteName: name)!
        let preferences = WallpaperPreferences(domain: name)

        defaults.set("soon", forKey: "interval")
        #expect(preferences.interval == .oneHour)
        defaults.set(60, forKey: "interval")
        #expect(preferences.interval == .oneHour)
        defaults.set("OneMinute", forKey: "interval")
        #expect(preferences.interval == .oneHour)
        // The key this replaced is not read at all.
        defaults.removeObject(forKey: "interval")
        defaults.set(60, forKey: "intervalSeconds")
        #expect(preferences.read() == .unset)
    }
}
