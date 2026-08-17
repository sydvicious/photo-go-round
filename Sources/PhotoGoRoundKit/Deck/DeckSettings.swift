import Foundation

/// The one deck parameter a person can actually feel.
///
/// Lives in `UserDefaults` rather than in the database, because it is a
/// preference rather than state. Passed in explicitly here so the deck itself
/// has no opinion about where configuration comes from.
public struct DeckSettings: Sendable, Equatable {

    /// The fraction of the pool a photo must wait out before it can be dealt
    /// again *within* the current pass.
    ///
    /// At **1.0** the window is the whole pool, so nothing comes back early and
    /// the pass is the only rule: every photo exactly once per pass, in a fresh
    /// random order each time through. At **0.5** — the default — a photo can
    /// recur once about half the library has gone by, without waiting for the
    /// pass to finish. That matters most on large libraries, where strict
    /// fairness means a picture you loved is effectively never coming back.
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
    /// Clamped to the pool rather than to `pool - 1`: at fraction 1.0 the window
    /// is meant to be unsatisfiable so that the pass boundary is what releases a
    /// photo, not the window.
    public func repeatWindow(poolSize: Int) -> Int {
        guard poolSize > 0 else { return 0 }
        let raw = (repeatWindowFraction * Double(poolSize)).rounded()
        return max(0, min(Int(raw), poolSize))
    }
}

/// A concession the deck made in order to produce a card, reported rather than
/// swallowed — every path that produces a photo must always produce a photo,
/// and the user is owed an explanation when the library cannot support what was
/// asked of it.
///
/// Note that running out of cards *within a pass* is not on this list. That is
/// the end of the pass, which is ordinary business: the deck reshuffles and
/// carries on.
public enum DeckRelaxation: Sendable, Equatable {
    /// Not even a fresh pass produced a free card, so cards already spoken for
    /// by another consumer's outstanding hand were reused. A one-photo library
    /// and three displays means all three show that photo, which is the right
    /// answer — hands overlap rather than starve.
    case reservedCardsReused
    /// Fewer cards were available than were asked for. A short hand is a normal
    /// result, not an error; the consumer simply reserves again sooner.
    case handWasShort(asked: Int, got: Int)

    var eventKind: String {
        switch self {
        case .reservedCardsReused: "reserved_reused"
        case .handWasShort: "short_hand"
        }
    }

    var eventDetail: String {
        switch self {
        case .reservedCardsReused: "outstanding hands reused"
        case .handWasShort(let asked, let got): "asked \(asked), got \(got)"
        }
    }
}

extension DeckRelaxation: CustomStringConvertible {
    public var description: String {
        switch self {
        case .reservedCardsReused:
            "the deck had nothing free, so cards reserved by another consumer were reused"
        case .handWasShort(let asked, let got):
            "asked for \(asked) cards, got \(got)"
        }
    }
}
