import Foundation
import Synchronization

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
        // One log line rather than five blank-separated ones: a banner is one
        // fact spread over a shape that only means anything on a terminal.
        send(text.split(separator: "\n").map(String.init).joined(separator: " · "))
    }

    /// Untimestamped, for the banner and for anything printed before the loop
    /// starts.
    public static func note(_ text: String) {
        print("  " + paint(text, .grey))
        send(text)
    }

    /// Timestamped, for anything happening inside the loop — otherwise it sorts
    /// oddly against the events around it when you are reading back a session.
    ///
    /// **`mirrored` is false for the queue's own lines**, which
    /// `QueueEvent.report` already logs at a level chosen per case. Mirroring
    /// them as well would log each one twice, and the second copy at the wrong
    /// level.
    public static func event(_ text: String, mirrored: Bool = true) {
        print("\(timestamp)  \(paint(text, .grey))")
        if mirrored { send(text) }
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
    ///
    /// **`mirrored` is false for the served `▸` line.** `PictureEndpoint` logs
    /// the same request as `served status=…`, which is the structured record;
    /// mirroring this one as well put the same picture in the log twice.
    /// `Plans/Logging.md`, Phase 5.
    public static func change(
        _ mark: String, _ name: String, _ colour: Colour, suffix: String? = nil,
        whole: Bool = false, mirrored: Bool = true
    ) {
        let tail = suffix.map { "  " + paint($0, .grey) } ?? ""
        let body = whole ? paint(name, colour) : name
        print("\(timestamp)  \(paint(mark, colour)) \(body)\(tail)")
        // The mark travels, for the callers that do mirror: it is the whole
        // identity of the line.
        if mirrored { send("\(mark) \(name)" + (suffix.map { "  \($0)" } ?? "")) }
    }

    /// How loud a mirrored line is. Two shades, because every Console call the
    /// agent makes outside the queue is either something that happened or
    /// something that went wrong.
    ///
    /// **Console's own names rather than the log's.** `Console` knows about
    /// terminals and colours and does not import `OSLog`; which unified-log
    /// level a shade becomes is the sink's decision, and the agent is the only
    /// process that makes it.
    public enum Level: Sendable, Equatable {
        case notice
        case error
    }

    /// Where every printed line also goes, when something has asked for it.
    ///
    /// **Only the agent asks, and this is why it exists.** Under launchd the
    /// agent's standard output goes nowhere, so a `Console` call there is a line
    /// that is simply lost — which is what removing the log file would have made
    /// true of all fifty-seven of them, the served `▸` line included. The mirror
    /// is additive: a run started from a terminal or from Xcode prints exactly
    /// what it always printed, and the mirror is a second destination rather
    /// than a replacement. `pgr_ctl` installs nothing.
    ///
    /// `Plans/Logging.md`, Phase 1.
    private static let mirrorSink = Mutex<(@Sendable (String, Level) -> Void)?>(nil)

    /// Sends every printed line to `sink` as well as to standard output, or
    /// stops, given nil.
    public static func mirror(to sink: (@Sendable (_ text: String, _ level: Level) -> Void)?) {
        mirrorSink.withLock { $0 = sink }
    }

    /// The mirrored copy: untimestamped and uncoloured, because whatever reads
    /// it stamps its own lines and has no terminal.
    private static func send(_ text: String, _ level: Level = .notice) {
        guard let sink = mirrorSink.withLock({ $0 }) else { return }
        sink(text, level)
    }

    /// Whether a red line is kept in the agent's record of its errors, and
    /// under what.
    public enum Recording: Sendable, Equatable {
        /// Under its exact text. What an alert nobody has classified gets, so a
        /// new red line is never silently left out.
        case byText
        /// Under a kind that stays the same while the line's details — a
        /// photograph's name, a queue depth, a latency — change, so the same
        /// trouble collapses into one row with a count.
        case kind(String)
        /// Not at all, because something at the same site already records this
        /// event and a second record would count it twice.
        case unrecorded
    }

    /// Where recorded alerts go. Nil records nothing, which is every process
    /// but the agent: `pgr_ctl` prints red lines too, and keeps no record.
    private static let alertRecorder = Mutex<(@Sendable (String, String?) -> Void)?>(nil)

    /// Sends every recorded alert's text and kind to `recorder` — the kind nil
    /// for one recorded by its text — or stops, given nil.
    public static func recordAlerts(to recorder: (@Sendable (_ text: String, _ kind: String?) -> Void)?) {
        alertRecorder.withLock { $0 = recorder }
    }

    /// `mirrored` is false for the queue's own lines. See `event`.
    public static func alert(
        _ text: String, recording: Recording = .byText, mirrored: Bool = true
    ) {
        print("\(timestamp)  \(paint("!", .red)) \(paint(text, .red))")
        if mirrored { send(text, .error) }
        guard let recorder = alertRecorder.withLock({ $0 }) else { return }
        switch recording {
        case .byText: recorder(text, nil)
        case .kind(let kind): recorder(text, kind)
        case .unrecorded: break
        }
    }

    public static func recovered(_ text: String) {
        print("\(timestamp)  \(paint("✓", .green)) \(text)")
        send(text)
    }

    public static func summary(_ text: String) {
        print("\(timestamp)  \(paint(text, .grey))")
        send(text)
    }

    /// Where `failure` writes, when something has redirected it.
    ///
    /// **Only tests redirect it.** A command that refuses by design still has
    /// to say why, and a test exercising that refusal would otherwise print
    /// `error:` into the output of a run where nothing went wrong — which
    /// teaches whoever reads that output to skim past the word. Redirecting
    /// also lets the test assert the wording, which is the part that matters
    /// and was previously checked by nobody.
    private static let redirect = Mutex<(@Sendable (String) -> Void)?>(nil)

    /// Sends failures to `sink` instead of standard error, or back to standard
    /// error when given nil.
    public static func redirectFailures(to sink: (@Sendable (String) -> Void)?) {
        redirect.withLock { $0 = sink }
    }

    public static func failure(_ text: String) {
        if let sink = redirect.withLock({ $0 }) {
            sink(text)
            return
        }
        FileHandle.standardError.write(Data((paint("error: ", .red) + text + "\n").utf8))
        send(text, .error)
    }
}
