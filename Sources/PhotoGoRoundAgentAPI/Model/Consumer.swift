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

/// A registered surface that asks for pictures.
///
/// A registry and a heartbeat, and deliberately nothing more. Every surface
/// serves from the same queue; two displays get different pictures because
/// serving removes the entry.
public struct Consumer: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let kind: ConsumerKind
    /// `CGDisplayCreateUUIDFromDisplayID`, which survives reboots and port
    /// changes, so the same monitor resumes its own rotation after a sleep or a
    /// cable swap. The transient `CGDirectDisplayID` is not a suitable key.
    /// Nil for consumers that are not tied to a display.
    public let displayID: String?
    /// Heartbeat, so a surface that has stopped asking can be told apart from
    /// one that is simply between pictures.
    public let seenAt: Date
    public let createdAt: Date

    public init(
        id: Int64, kind: ConsumerKind, displayID: String?, seenAt: Date, createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.displayID = displayID
        self.seenAt = seenAt
        self.createdAt = createdAt
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
