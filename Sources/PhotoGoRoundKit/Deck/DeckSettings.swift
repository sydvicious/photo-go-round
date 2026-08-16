import Foundation

/// The one deck parameter a person can actually feel.
///
/// Lives in `UserDefaults` rather than in the database, because it is a
/// preference rather than state. Passed in explicitly here so the deck itself
/// has no opinion about where configuration comes from.
public struct DeckSettings: Sendable, Equatable {

    /// The fraction of the eligible pool a photo must wait out before it can be
    /// dealt again.
    ///
    /// At **1.0** a photo cannot return until every other photo has been dealt:
    /// exactly one showing per pass, in random order within the pass, which is
    /// the classic shuffle. At **0.5** — the default — photos can recur once
    /// about half the library has gone by, which matters most on large
    /// libraries, where strict fairness means a picture you loved is
    /// effectively never coming back.
    ///
    /// The trade is fairness against liveliness. 1.0 gives exact fairness, zero
    /// variance. Lower fractions equalise only in expectation, so over any
    /// finite stretch some photos appear three times while others appear once.
    /// That variance is the feature being bought, which is why the number is
    /// exposed rather than chosen for the user.
    public var repeatWindowFraction: Double

    public static let defaultRepeatWindowFraction = 0.5

    public init(repeatWindowFraction: Double = DeckSettings.defaultRepeatWindowFraction) {
        // `defaults write` accepts anything, so every preference read is a
        // parse with a default and a clamp.
        self.repeatWindowFraction = repeatWindowFraction.isFinite
            ? min(max(repeatWindowFraction, 0), 1)
            : Self.defaultRepeatWindowFraction
    }

    public static let `default` = DeckSettings()

    /// The repeat window in cards, for a pool of the given size.
    ///
    /// Clamped to `pool - 1`, which is what makes fraction 1.0 *exactly* the
    /// classic shuffle rather than a shuffle that relaxes its window at every
    /// pass boundary: with a window of `pool` there is a deal at which nothing
    /// at all is eligible, and the relaxation ladder would fire on every pass.
    public func repeatWindow(poolSize: Int) -> Int {
        guard poolSize > 1 else { return 0 }
        let raw = (repeatWindowFraction * Double(poolSize)).rounded()
        return max(0, min(Int(raw), poolSize - 1))
    }
}

/// A concession the deck made in order to produce a card, reported rather than
/// swallowed — every path that produces a photo must always produce a photo,
/// and the user is owed an explanation when the library cannot support what was
/// asked of it.
public enum DeckRelaxation: Sendable, Equatable {
    /// No photo satisfied the repeat window, so it was halved until one did.
    /// A library of thirty photos and a screensaver at one every ten seconds
    /// will exhaust its window in minutes; this is that, surfaced.
    case repeatWindowNarrowed(from: Int, to: Int)
    /// Not even a window of zero produced a free card, so cards already spoken
    /// for by another consumer's outstanding hand were reused. A one-photo
    /// library and three displays means all three show that photo, which is the
    /// right answer — hands overlap rather than starve.
    case reservedCardsReused
    /// Fewer cards were available than were asked for. A short hand is a normal
    /// result, not an error; the consumer simply reserves again sooner.
    case handWasShort(asked: Int, got: Int)

    var eventKind: String {
        switch self {
        case .repeatWindowNarrowed: "window_relaxed"
        case .reservedCardsReused: "reserved_reused"
        case .handWasShort: "short_hand"
        }
    }

    var eventDetail: String {
        switch self {
        case .repeatWindowNarrowed(let from, let to): "window \(from) -> \(to)"
        case .reservedCardsReused: "outstanding hands reused"
        case .handWasShort(let asked, let got): "asked \(asked), got \(got)"
        }
    }
}
