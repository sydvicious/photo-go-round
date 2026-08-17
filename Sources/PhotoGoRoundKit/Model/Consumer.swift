import Foundation

/// What kind of surface a consumer is.
///
/// Deliberately not an enum, and the schema deliberately carries no CHECK
/// constraint on the column: a new surface is meant to be a new consumer row
/// rather than a new code path in the deck. Adding tvOS in Phase 10 should not
/// be a migration, and it should not require recompiling the kit to name it.
///
/// A surface with several simultaneous instances discriminates them here rather
/// than in `displayID`, since identity is `(kind, displayID)` and a widget has
/// no display: `widget.small` and `widget.large` are two consumers.
public struct ConsumerKind: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let wallpaper = ConsumerKind("wallpaper")
    public static let screensaver = ConsumerKind("screensaver")
    public static let widget = ConsumerKind("widget")
    /// The Mac app's window, which is a consumer like any other.
    public static let app = ConsumerKind("app")
    /// `pgr`, so that exercising the deck from a terminal does not masquerade
    /// as a real surface.
    public static let commandLine = ConsumerKind("cli")
}

extension ConsumerKind: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}

extension ConsumerKind: CustomStringConvertible {
    public var description: String { rawValue }
}

/// A registered surface that deals from the shared deck.
public struct Consumer: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let kind: ConsumerKind
    /// `CGDisplayCreateUUIDFromDisplayID`, which survives reboots and port
    /// changes, so the same monitor resumes its own rotation after a sleep or a
    /// cable swap. The transient `CGDirectDisplayID` is not a suitable key.
    /// Nil for consumers that are not tied to a display.
    public let displayID: String?
    /// How many cards this consumer reserves at a time.
    public let handSize: Int
    /// Heartbeat. The reaper returns the unplayed cards of any consumer that
    /// has stopped checking in.
    public let seenAt: Date
    public let createdAt: Date

    init(row: Row) throws {
        id = try row.int64("id")
        kind = ConsumerKind(try row.string("kind"))
        displayID = try row.optionalString("display_id")
        handSize = try row.int("hand_size")
        seenAt = try row.date("seen_at")
        createdAt = try row.date("created_at")
    }
}

extension Consumer {
    /// How much playback a hand should cover.
    ///
    /// The number that matters is not the hand size but the interval between
    /// reservations: one write every twenty minutes is a dramatically easier
    /// thing to arrange from inside a sandbox than one every ten seconds, and it
    /// is what makes the screensaver's consumption-journal fallback comfortable
    /// rather than marginal.
    public static let handCoverage: Duration = .seconds(20 * 60)

    /// A hand of fewer than this is not worth the round trip, and it gives a
    /// slow consumer — a wallpaper at one photo per half hour — a couple of
    /// hours of cover rather than a single card.
    public static let minimumHandSize = 4

    /// A large hand reserves cards it will not show for days, keeping them out
    /// of every other consumer's reach and pinned in the cache. The cache cap
    /// has a hard floor at the sum of all hand sizes, so this bounds that too.
    public static let maximumHandSize = 200

    /// The default hand size for a consumer that shows a photo every `interval`.
    ///
    /// A screensaver at one every ten seconds gets 120 cards; a wallpaper at one
    /// every thirty minutes gets the floor of 4, which covers two hours.
    public static func handSize(
        forInterval interval: Duration,
        covering coverage: Duration = Consumer.handCoverage
    ) -> Int {
        guard interval > .zero else { return maximumHandSize }
        let cards = (coverage.totalSeconds / interval.totalSeconds).rounded(.up)
        guard cards.isFinite else { return maximumHandSize }
        return min(max(Int(cards), minimumHandSize), maximumHandSize)
    }
}

extension Duration {
    /// Fractional seconds. Convenient for arithmetic; not for anything that
    /// needs to be exact.
    ///
    /// Named `totalSeconds` rather than `seconds` so it cannot be confused with
    /// — or shadowed by — the `Duration.seconds(_:)` factory.
    public var totalSeconds: Double {
        let (whole, attoseconds) = components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}
