import Console
import Foundation
import PhotoGoRoundKit
import PhotoGoRoundAgentAPI

/// Reading and writing preferences, in the domain the agent actually reads.
///
/// Raw `defaults write` stays usable by anyone who knows the domain — the agent
/// re-reads on a poll precisely so that it works with no cooperation. This
/// exists so that nobody *has* to know it: `--prod` and the development default
/// pick different domains, and getting that wrong writes a setting nothing ever
/// reads.
enum PreferenceCommands {

    /// Reads preferences.
    ///
    /// **What is printed is the value the agent would use**, so an unset
    /// preference reports its default rather than nothing. That is almost always
    /// the question being asked, and it keeps the output free of anything a
    /// caller would have to strip: a bare value, never a value with a marker
    /// glued to it.
    ///
    /// `--no-default-values` asks the other question — what is actually stored —
    /// and answers it with a blank for anything that is not. The two questions
    /// are genuinely different and neither answer can express the other, which is
    /// why this is a flag rather than a formatting choice.
    static func get(
        key: String?, showDefaults: Bool, environment: MacHostEnvironment
    ) throws {
        let preferences = environment.preferences
        let stored = preferences.all()

        func value(_ preference: Preferences.Key) -> String {
            Self.value(of: preference, in: preferences, stored: stored, showDefaults: showDefaults)
        }

        if let key {
            guard let match = Preferences.allKeys.first(where: { $0.rawValue == key }) else {
                Console.failure("unknown preference \(key). `pgr_ctl get` lists them.")
                throw ExitCode(1)
            }
            // Bare, so it can be read by a script without any parsing.
            print(value(match))
            return
        }

        for preference in Preferences.allKeys {
            Console.note(
                "\(preference.rawValue.padding(toLength: 28, withPad: " ", startingAt: 0)) "
                    + value(preference))
        }
    }

    /// What `get` prints for one preference, which is the whole of its policy.
    ///
    /// Separated from the printing so it can be asserted directly: the two
    /// questions this answers differ only in what an *unset* preference reports,
    /// and that is exactly the case a test needs to pin.
    static func value(
        of key: Preferences.Key,
        in preferences: Preferences,
        stored: [String: String],
        showDefaults: Bool
    ) -> String {
        guard showDefaults else { return stored[key.rawValue] ?? "" }
        return preferences.effectiveValue(for: key) ?? stored[key.rawValue] ?? ""
    }

    static func set(key: String, value: String, environment: MacHostEnvironment) throws {
        guard let match = Preferences.allKeys.first(where: { $0.rawValue == key }) else {
            Console.failure("unknown preference \(key). `pgr_ctl get` lists them.")
            throw ExitCode(1)
        }
        guard let number = Double(value), number.isFinite else {
            Console.failure("\(key) takes a number")
            throw ExitCode(1)
        }

        // Whole numbers are written as integers so `defaults read` shows what
        // you typed rather than `5` coming back as `5.0`.
        if number == number.rounded(), abs(number) < 1e15 {
            environment.preferences.set(match, to: Int(number))
        } else {
            environment.preferences.set(match, to: number)
        }
        // Setting posts the doorbell, so a running agent re-reads at once rather
        // than at its next thirty-second poll.
        Console.recovered("\(key) = \(value)")
    }
}

/// Ringing a doorbell by hand.
///
/// Every topic is one word. The value is diagnostic: when something does not
/// update, posting the topic yourself separates "the notification never fired"
/// from "the listener ignored it", which are the two halves of every doorbell
/// bug and look identical from the outside.
enum NotifyCommand {

    static func run(topic name: String, environment: MacHostEnvironment) throws {
        guard let topic = DarwinNotification.Topic(rawValue: name) else {
            let known = DarwinNotification.Topic.allCases.map(\.rawValue).joined(separator: ", ")
            Console.failure("unknown topic \(name). One of: \(known)")
            throw ExitCode(1)
        }
        // **The scoped name, not the topic.** Doorbells are keyed on the
        // database, so the whole point of ringing one by hand is knowing which
        // library's bell just rang — and whether it is the one the agent you are
        // watching is listening to.
        environment.doorbells.post(topic)
        Console.recovered("posted \(environment.doorbells.name(topic))")
    }
}

/// What every process has been logging.
///
/// A thin wrapper over `log show`, because nobody should have to remember
/// predicate syntax to see what the agent is doing — and because the logs are
/// the one diagnostic that crosses every sandbox we will ever run inside, so
/// reaching them has to be one word.
enum LogCommand {

    static let predicate = "subsystem == \"com.sydpolk.photogoround\""

    /// What `log` asks `/usr/bin/log` for. The whole of this command's decision;
    /// running the process is plumbing around it.
    static func arguments(follow: Bool, last: String) -> [String] {
        follow
            ? ["stream", "--predicate", predicate, "--level", "info"]
            : ["show", "--predicate", predicate, "--last", last, "--info", "--style", "compact"]
    }

    static func run(follow: Bool, last: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/log")
        process.arguments = arguments(follow: follow, last: last)

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExitCode(process.terminationStatus) }
    }
}
