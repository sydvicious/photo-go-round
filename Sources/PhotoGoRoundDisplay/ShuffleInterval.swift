import Foundation

/// How long a picture stays up: the choices behind every *Shuffle All* pop-up.
///
/// **Stored as the tag, not as seconds.** Syd, 2026-09-14: "the preference should
/// store enum tags for the values", spelled "english in camelCase". A tag becomes
/// seconds when it is read and a tag again when it is written, so the loops keep
/// working in seconds and a preference can only ever hold one of these. See
/// `app/mac/FEATURES.md`, *Time between pictures*.
public enum ShuffleInterval: String, CaseIterable, Identifiable, Sendable {
    case tenSeconds
    case thirtySeconds
    case oneMinute
    case fiveMinutes
    case tenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case eightHours
    case twelveHours
    case oneDay

    /// The key, in the screensaver's domain and the wallpaper's alike.
    public static let key = "interval"

    public var id: String { rawValue }

    public var seconds: Int {
        switch self {
        case .tenSeconds: 10
        case .thirtySeconds: 30
        case .oneMinute: 60
        case .fiveMinutes: 5 * 60
        case .tenMinutes: 10 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        case .eightHours: 8 * 60 * 60
        case .twelveHours: 12 * 60 * 60
        case .oneDay: 24 * 60 * 60
        }
    }

    public var duration: Duration { .seconds(seconds) }

    /// What the pop-up says, in System Settings' own style: "Every Day" and
    /// "Every Hour", not "Every 1 Day".
    public var title: String {
        switch self {
        case .tenSeconds: "Every 10 Seconds"
        case .thirtySeconds: "Every 30 Seconds"
        case .oneMinute: "Every Minute"
        case .fiveMinutes: "Every 5 Minutes"
        case .tenMinutes: "Every 10 Minutes"
        case .thirtyMinutes: "Every 30 Minutes"
        case .oneHour: "Every Hour"
        case .twoHours: "Every 2 Hours"
        case .eightHours: "Every 8 Hours"
        case .twelveHours: "Every 12 Hours"
        case .oneDay: "Every Day"
        }
    }
}

/// What a preference domain says about the interval, which is four things and
/// not two — for the reason `ServicePort.Reading` is three.
public enum IntervalReading: Equatable, Sendable {
    /// A tag, and whether the suite or the file gave it.
    case set(ShuffleInterval, from: ServicePort.Origin)
    /// Nothing has chosen one.
    case unset
    /// Something is there and it is not a tag: a `defaults write` of a number,
    /// or a misspelling.
    case unknown(String, from: ServicePort.Origin)
    /// The file is there and would not parse.
    case unreadable(reason: String)

    /// The choice, or the surface's default for anything that is not one.
    public func choice(default fallback: ShuffleInterval) -> ShuffleInterval {
        if case .set(let choice, _) = self { return choice }
        return fallback
    }

    static func parse(_ raw: Any?, from origin: ServicePort.Origin) -> IntervalReading {
        guard let raw else { return .unset }
        guard let tag = raw as? String, let choice = ShuffleInterval(rawValue: tag) else {
            return .unknown(String(describing: raw), from: origin)
        }
        return .set(choice, from: origin)
    }
}
