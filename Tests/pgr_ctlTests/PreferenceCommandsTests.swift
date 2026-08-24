import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import pgr_ctl

@Suite("pgr_ctl preferences")
struct PreferenceCommandsTests {

    /// A throwaway defaults suite, so a test never writes into the preferences
    /// of whoever is running it. Torn down all three ways, because emptying the
    /// domain alone leaves a plist behind in `~/Library/Preferences`.
    private final class Scratch {
        let name = "com.sydpolk.photogoround.tests.\(UUID().uuidString)"
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        var preferences: Preferences { Preferences(defaults: defaults) }

        deinit {
            let defaults = UserDefaults(suiteName: name)
            defaults?.removePersistentDomain(forName: name)
            defaults?.removeSuite(named: name)
            let file = URL.homeDirectory.appending(path: "Library/Preferences/\(name).plist")
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func value(
        _ key: Preferences.Key, _ scratch: Scratch, showDefaults: Bool
    ) -> String {
        PreferenceCommands.value(
            of: key, in: scratch.preferences, stored: scratch.preferences.all(),
            showDefaults: showDefaults)
    }

    @Test("By default an unset preference reports the value the agent would use")
    func unsetReportsTheDefault() {
        let scratch = Scratch()
        #expect(value(.queueSize, scratch, showDefaults: true) == "250")
        #expect(value(.downloadConcurrency, scratch, showDefaults: true) == "4")
        #expect(value(.repeatWindowFraction, scratch, showDefaults: true) == "0.5")
    }

    @Test("`--no-default-values` reports what is stored, and blank when nothing is")
    func unsetReportsBlank() {
        let scratch = Scratch()
        #expect(value(.queueSize, scratch, showDefaults: false) == "")
        #expect(value(.downloadConcurrency, scratch, showDefaults: false) == "")
    }

    @Test("A stored value is reported either way, and identically")
    func storedValueIsReportedBothWays() {
        let scratch = Scratch()
        scratch.defaults.set(250, forKey: Preferences.Key.queueSize.rawValue)
        #expect(value(.queueSize, scratch, showDefaults: true) == "250")
        #expect(value(.queueSize, scratch, showDefaults: false) == "250")
    }

    @Test("The default form reports the clamp, not what was typed")
    func outOfRangeIsReportedClamped() {
        // `defaults write` accepts anything, so what is stored and what the agent
        // will use are not always the same number. The default form answers for
        // the agent; `--no-default-values` answers for the store.
        let scratch = Scratch()
        scratch.defaults.set(999, forKey: Preferences.Key.downloadConcurrency.rawValue)
        #expect(value(.downloadConcurrency, scratch, showDefaults: true) == "32")
        #expect(value(.downloadConcurrency, scratch, showDefaults: false) == "999")
    }

    @Test("Nothing a script reads carries a marker it would have to strip")
    func outputIsBare() {
        let scratch = Scratch()
        for key in Preferences.allKeys {
            let printed = value(key, scratch, showDefaults: true)
            #expect(!printed.contains("("), "\(key.rawValue) printed \(printed)")
            #expect(printed == printed.trimmingCharacters(in: .whitespaces))
        }
    }
}

@Suite("pgr_ctl doorbells")
struct NotifyCommandTests {

    @Test("Every topic the man page offers maps to a real notification")
    func topicsAreComplete() {
        let names = NotifyCommand.topics.map(\.name)
        #expect(names == ["prefs", "deck", "sources", "cache"])
        // Distinct topics, so no two words ring the same bell.
        #expect(Set(NotifyCommand.topics.map(\.topic)).count == names.count)
    }

    @Test("Topics carry the identifier the agent observes")
    func topicsAreTheAgentsOwn() {
        let byName = Dictionary(
            uniqueKeysWithValues: NotifyCommand.topics.map { ($0.name, $0.topic) })
        #expect(byName["prefs"] == .preferencesChanged)
        #expect(byName["deck"] == .deckAdvanced)
        #expect(byName["sources"] == .sourcesChanged)
        #expect(byName["cache"] == .cacheChanged)
        #expect(byName["sources"]?.rawValue == "com.sydpolk.photogoround.sources")
    }

    @Test("An unknown topic is refused rather than posted")
    func unknownTopicIsAnError() {
        #expect(throws: (any Error).self) { try NotifyCommand.run(topic: "wallpaper") }
        #expect(throws: (any Error).self) { try NotifyCommand.run(topic: "") }
    }
}

@Suite("pgr_ctl log")
struct LogCommandTests {

    @Test("Only this project's log records are asked for")
    func predicateIsScopedToUs() {
        // A predicate that let anything else through would bury the agent's own
        // output in the system's.
        #expect(LogCommand.predicate == "subsystem == \"com.sydpolk.photogoround\"")
    }

    @Test("Following streams; not following shows a window ending now")
    func followChoosesTheVerb() {
        let streaming = LogCommand.arguments(follow: true, last: "1h")
        #expect(streaming.first == "stream")
        #expect(streaming.contains(LogCommand.predicate))
        // A stream has no history to bound, so `--last` would be meaningless.
        #expect(!streaming.contains("--last"))

        let showing = LogCommand.arguments(follow: false, last: "30m")
        #expect(showing.first == "show")
        #expect(showing.contains(LogCommand.predicate))
        #expect(showing.contains("--last"))
        #expect(showing.contains("30m"))
    }

    @Test("Info-level records are included, since notices alone are not enough")
    func infoIsIncluded() {
        // State transitions are logged at `.notice` and the detail around them at
        // `.info`; asking only for notices would drop the half that explains.
        #expect(LogCommand.arguments(follow: true, last: "1h").contains("info"))
        #expect(LogCommand.arguments(follow: false, last: "1h").contains("--info"))
    }
}
