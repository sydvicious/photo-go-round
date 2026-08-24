import Foundation

/// Terminal output for the development modes.
///
/// Deliberately separate from `Log`. Unified logging is the shipping mechanism
/// and works from inside every sandbox we will ever be in; this is for a person
/// with a terminal open watching a folder, where `log stream` would be a poor
/// substitute for a line appearing the moment a file lands.
public enum Console {
    public enum Colour: String {
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

    public static func banner(_ text: String) {
        print()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            print("  " + paint(String(line), .grey))
        }
        print()
    }

    /// Untimestamped, for the banner and for anything printed before the loop
    /// starts.
    public static func note(_ text: String) {
        print("  " + paint(text, .grey))
    }

    /// Timestamped, for anything happening inside the loop — otherwise it sorts
    /// oddly against the events around it when you are reading back a session.
    public static func event(_ text: String) {
        print("\(timestamp)  \(paint(text, .grey))")
    }

    /// A line about one named thing.
    ///
    /// **`whole` decides how loud it is, and the choice is about frequency.** A
    /// picture being served is the line a person watching this sees every ten
    /// seconds for hours; colouring it end to end would make a wall of it, so it
    /// gets a coloured mark and a plain name. A photograph appearing or leaving
    /// a source happens in occasional bursts and is worth looking up for, so it
    /// takes the colour across the name as well.
    ///
    /// Painting only the mark for both was the original, and it did not work: a
    /// single green glyph against a single yellow one, with the rest of each
    /// line identical, is not a difference you can see while scrolling.
    public static func change(
        _ mark: String, _ name: String, _ colour: Colour, suffix: String? = nil,
        whole: Bool = false
    ) {
        let tail = suffix.map { "  " + paint($0, .grey) } ?? ""
        let body = whole ? paint(name, colour) : name
        print("\(timestamp)  \(paint(mark, colour)) \(body)\(tail)")
    }

    public static func alert(_ text: String) {
        print("\(timestamp)  \(paint("!", .red)) \(paint(text, .red))")
    }

    public static func recovered(_ text: String) {
        print("\(timestamp)  \(paint("✓", .green)) \(text)")
    }

    public static func summary(_ text: String) {
        print("\(timestamp)  \(paint(text, .grey))")
    }

    public static func failure(_ text: String) {
        FileHandle.standardError.write(Data((paint("error: ", .red) + text + "\n").utf8))
    }
}
