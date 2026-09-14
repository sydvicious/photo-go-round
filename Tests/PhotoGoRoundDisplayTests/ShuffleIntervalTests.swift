import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundDisplay

/// The *Shuffle All* choices, and the screensaver's preferences that hold one.
///
/// See `app/mac/FEATURES.md`, *Time between pictures*.
@Suite("Shuffle All")
@MainActor
struct ShuffleIntervalTests {

    // MARK: - The choices

    /// Syd, 2026-09-14: "english in camelCase". These are what a preference
    /// file holds, so a rename is a change to every stored choice.
    @Test("The tags, in the pop-up's order")
    func tags() {
        #expect(ShuffleInterval.allCases.map(\.rawValue) == [
            "tenSeconds", "thirtySeconds", "oneMinute", "fiveMinutes", "tenMinutes",
            "thirtyMinutes", "oneHour", "twoHours", "eightHours", "twelveHours", "oneDay",
        ])
    }

    @Test("Each tag is the seconds it names")
    func seconds() {
        #expect(ShuffleInterval.allCases.map(\.seconds) == [
            10, 30, 60, 300, 600, 1800, 3600, 7200, 28_800, 43_200, 86_400,
        ])
        #expect(ShuffleInterval.oneDay.duration == .seconds(86_400))
    }

    /// In System Settings' style, and with no "Continuously".
    @Test("The pop-up's words")
    func titles() {
        #expect(ShuffleInterval.allCases.map(\.title) == [
            "Every 10 Seconds", "Every 30 Seconds", "Every Minute", "Every 5 Minutes",
            "Every 10 Minutes", "Every 30 Minutes", "Every Hour", "Every 2 Hours",
            "Every 8 Hours", "Every 12 Hours", "Every Day",
        ])
    }

    @Test("A stored value is a tag, nothing, or something that is not a tag")
    func parsing() {
        #expect(IntervalReading.parse("oneHour", from: .suite) == .set(.oneHour, from: .suite))
        #expect(IntervalReading.parse(nil, from: .suite) == .unset)
        #expect(IntervalReading.parse(60, from: .file) == .unknown("60", from: .file))
        #expect(IntervalReading.parse("OneHour", from: .file) == .unknown("OneHour", from: .file))
        #expect(IntervalReading.unknown("60", from: .file).choice(default: .tenSeconds) == .tenSeconds)
    }

    // MARK: - The screensaver's preferences

    @Test("Each deployment has its own screensaver domain, beside the wallpaper's")
    func domains() {
        #expect(ScreensaverPreferences(deployment: .development).domain
            == "com.sydpolk.photogoround.screensaver.dev")
        #expect(ScreensaverPreferences(deployment: .production).domain
            == "com.sydpolk.photogoround.screensaver.prod")
    }

    /// "Screensaver will default to "10 seconds"."
    @Test("Nothing chosen is ten seconds")
    func screensaverDefault() {
        let name = scratchSuiteName("screensaver-default")
        defer { discardScratchSuite(name) }
        let preferences = ScreensaverPreferences(domain: name)

        #expect(preferences.read() == .unset)
        #expect(preferences.interval == .tenSeconds)
    }

    @Test("A choice is written as its tag and read back from the suite")
    func screensaverRoundTrip() {
        let name = scratchSuiteName("screensaver-round-trip")
        defer { discardScratchSuite(name) }
        let preferences = ScreensaverPreferences(domain: name)
        preferences.set(.fiveMinutes)

        #expect(UserDefaults(suiteName: name)!.string(forKey: "interval") == "fiveMinutes")
        #expect(preferences.read() == .set(.fiveMinutes, from: .suite))
        #expect(preferences.interval == .fiveMinutes)
    }

    /// The saver's case: the suite came back empty and the file has the answer.
    @Test("The file is read the way the port's is: a tag, nothing, junk, or not a tag")
    func screensaverFile() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-shuffle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func plist(_ name: String, _ contents: [String: Any]) throws -> URL {
            let url = directory.appending(path: "\(name).plist")
            try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0)
                .write(to: url)
            return url
        }

        #expect(ScreensaverPreferences.readFile(at: try plist("tag", ["interval": "oneMinute"]))
            == .set(.oneMinute, from: .file))
        #expect(ScreensaverPreferences.readFile(at: try plist("other", ["servicePort": 9000])) == .unset)
        #expect(ScreensaverPreferences.readFile(at: try plist("number", ["interval": 60]))
            == .unknown("60", from: .file))
        #expect(ScreensaverPreferences.readFile(at: directory.appending(path: "never.plist")) == .unset)

        let junk = directory.appending(path: "junk.plist")
        try Data("this is not a property list".utf8).write(to: junk)
        guard case .unreadable = ScreensaverPreferences.readFile(at: junk) else {
            Issue.record("a file of junk read as \(ScreensaverPreferences.readFile(at: junk))")
            return
        }
    }

    // MARK: - Who reads it when

    /// Syd, 2026-09-14: "the app window will read the current screensaver
    /// internal when it is created, and it will stay there with its own copy of
    /// the setting even if the screensaver interval is changed."
    @Test("A window's copy stays put when the screensaver's choice changes")
    func windowKeepsItsCopy() {
        let name = scratchSuiteName("screensaver-window")
        defer { discardScratchSuite(name) }
        let preferences = ScreensaverPreferences(domain: name)
        preferences.set(.oneMinute)

        let window = Shuffle(source: Nothing(), consumer: "app", dwell: preferences.interval.duration)
        preferences.set(.oneHour)

        #expect(window.currentDwell == .seconds(60))
        let next = Shuffle(source: Nothing(), consumer: "app", dwell: preferences.interval.duration)
        #expect(next.currentDwell == .seconds(3600))
    }

    /// The saver's host outlives a session, so its loop reads before every wait.
    @Test("A loop that reads its dwell sees a change without being remade")
    func saverReadsEachTime() {
        let name = scratchSuiteName("screensaver-saver")
        defer { discardScratchSuite(name) }
        let preferences = ScreensaverPreferences(domain: name)

        let saver = Shuffle(
            source: Nothing(), consumer: "screensaver",
            dwellFrom: { preferences.interval.duration })
        #expect(saver.currentDwell == .seconds(10))
        preferences.set(.thirtySeconds)
        #expect(saver.currentDwell == .seconds(30))
    }

    /// A source with nothing to give; these tests never start a loop.
    private final class Nothing: PictureSource, Sendable {
        func next(
            consumer: String, displayID: String?, fitting box: PixelSize?
        ) async throws -> ServedPicture? { nil }
    }
}
