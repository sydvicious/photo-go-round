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
