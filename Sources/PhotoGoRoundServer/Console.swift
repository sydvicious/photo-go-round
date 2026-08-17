import Foundation

/// Terminal output for the development modes.
///
/// Deliberately separate from `Log`. Unified logging is the shipping mechanism
/// and works from inside every sandbox we will ever be in; this is for a person
/// with a terminal open watching a folder, where `log stream` would be a poor
/// substitute for a line appearing the moment a file lands.
enum Console {
    enum Colour: String {
        case red = "\u{001B}[31m"
        case green = "\u{001B}[32m"
        case yellow = "\u{001B}[33m"
        case cyan = "\u{001B}[36m"
        case grey = "\u{001B}[90m"
    }

    private static let reset = "\u{001B}[0m"

    /// Colour only when stdout is a terminal, so redirecting to a file gives
    /// plain text rather than escape sequences.
    private static let isTTY = isatty(STDOUT_FILENO) == 1

    private static func paint(_ text: String, _ colour: Colour) -> String {
        isTTY ? colour.rawValue + text + reset : text
    }

    private static var timestamp: String {
        let now = Date()
        let formatted = now.formatted(
            .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        )
        return paint(formatted, .grey)
    }

    static func banner(_ text: String) {
        print()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            print("  " + paint(String(line), .grey))
        }
        print()
    }

    /// Untimestamped, for the banner and for anything printed before the loop
    /// starts.
    static func note(_ text: String) {
        print("  " + paint(text, .grey))
    }

    /// Timestamped, for anything happening inside the loop — otherwise it sorts
    /// oddly against the events around it when you are reading back a session.
    static func event(_ text: String) {
        print("\(timestamp)  \(paint(text, .grey))")
    }

    static func change(_ mark: String, _ name: String, _ colour: Colour, suffix: String? = nil) {
        let tail = suffix.map { "  " + paint($0, .grey) } ?? ""
        print("\(timestamp)  \(paint(mark, colour)) \(name)\(tail)")
    }

    static func alert(_ text: String) {
        print("\(timestamp)  \(paint("!", .red)) \(paint(text, .red))")
    }

    static func recovered(_ text: String) {
        print("\(timestamp)  \(paint("✓", .green)) \(text)")
    }

    static func summary(_ text: String) {
        print("\(timestamp)  \(paint(text, .grey))")
    }

    static func failure(_ text: String) {
        FileHandle.standardError.write(Data((paint("error: ", .red) + text + "\n").utf8))
    }
}
