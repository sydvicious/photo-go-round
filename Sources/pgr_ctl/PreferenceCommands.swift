import Console
import Foundation
import PhotoGoRoundKit

/// Reading and writing preferences, in the domain the agent actually reads.
///
/// Raw `defaults write` stays usable by anyone who knows the domain — the agent
/// re-reads on a poll precisely so that it works with no cooperation. This
/// exists so that nobody *has* to know it: `--prod` and the development default
/// pick different domains, and getting that wrong writes a setting nothing ever
/// reads.
enum PreferenceCommands {

    static func get(key: String?, environment: MacHostEnvironment) throws {
        let values = environment.preferences.all()

        if let key {
            guard Preferences.allKeys.contains(where: { $0.rawValue == key }) else {
                Console.failure("unknown preference \(key). `pgr_ctl get` lists them.")
                throw ExitCode(1)
            }
            // Bare, so it can be read by a script without any parsing.
            print(values[key] ?? "")
            return
        }

        for preference in Preferences.allKeys {
            let value = values[preference.rawValue] ?? "(default)"
            Console.note(
                "\(preference.rawValue.padding(toLength: 28, withPad: " ", startingAt: 0)) \(value)")
        }
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

    static let topics: [(name: String, topic: DarwinNotification.Topic)] = [
        ("prefs", .preferencesChanged),
        ("deck", .deckAdvanced),
        ("sources", .sourcesChanged),
        ("cache", .cacheChanged),
    ]

    static func run(topic name: String) throws {
        guard let match = topics.first(where: { $0.name == name }) else {
            Console.failure(
                "unknown topic \(name). One of: \(topics.map(\.name).joined(separator: ", "))")
            throw ExitCode(1)
        }
        DarwinNotification.post(match.topic)
        Console.recovered("posted \(match.topic.rawValue)")
    }
}

/// What every process has been logging.
///
/// A thin wrapper over `log show`, because nobody should have to remember
/// predicate syntax to see what the agent is doing — and because the logs are
/// the one diagnostic that crosses every sandbox we will ever run inside, so
/// reaching them has to be one word.
enum LogCommand {

    static func run(follow: Bool, last: String) throws {
        let predicate = "subsystem == \"com.sydpolk.photogoround\""
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/log")
        process.arguments =
            follow
            ? ["stream", "--predicate", predicate, "--level", "info"]
            : ["show", "--predicate", predicate, "--last", last, "--info", "--style", "compact"]

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExitCode(process.terminationStatus) }
    }
}
