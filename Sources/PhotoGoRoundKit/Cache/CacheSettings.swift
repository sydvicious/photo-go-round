import Foundation

/// How much the cache holds, how fast it fills, and when it stops.
///
/// Every number here is empirical rather than principled, which is why they are
/// all configurable and why the shipping defaults get set by the Phase 2
/// measurements rather than by guess.
public struct CacheSettings: Sendable, Equatable {

    /// The primary control: how many *materialized* photos to keep.
    ///
    /// Referenced photos do not count — they were never copied, so there is
    /// nothing to cap.
    ///
    /// A cap is big enough when the fastest consumer never outruns it, which is
    /// the one measurement that actually decides this number. 1000 is a
    /// starting point.
    public var photoCap: Int

    /// A safety valve, secondary to the count.
    ///
    /// A thousand photos is somewhere between 2 GB and 100 GB depending on
    /// whether they are phone JPEGs or ProRAW, so a count alone cannot bound
    /// disk use. This should normally never trigger; it exists purely so a
    /// library of enormous originals cannot fill the volume. It only ever
    /// evicts early, never late.
    public var byteCeiling: Int64

    /// Below this much free space, stop materializing and say why. Running out
    /// of disk should degrade into "the deck stops growing" rather than into a
    /// full volume, which on macOS is a genuinely bad day for everything else
    /// running.
    public var minimumFreeBytes: Int64

    /// Below this much, evict ahead of the cap until it recovers.
    public var criticalFreeBytes: Int64

    public static let gigabyte: Int64 = 1_000_000_000

    public init(
        photoCap: Int = 1000,
        byteCeiling: Int64 = 50 * CacheSettings.gigabyte,
        minimumFreeBytes: Int64 = 5 * CacheSettings.gigabyte,
        criticalFreeBytes: Int64 = 2 * CacheSettings.gigabyte
    ) {
        // Every one of these can arrive from `defaults write`, which accepts
        // anything, so each is a parse with a default and a clamp.
        self.photoCap = max(0, photoCap)
        self.byteCeiling = max(0, byteCeiling)
        self.minimumFreeBytes = max(0, minimumFreeBytes)
        self.criticalFreeBytes = max(0, min(criticalFreeBytes, minimumFreeBytes))
    }

    public static let `default` = CacheSettings()

    /// iOS carries a far smaller cache and fills it opportunistically rather
    /// than continuously. Same policy, smaller numbers.
    public static let phone = CacheSettings(
        photoCap: 200,
        byteCeiling: 2 * CacheSettings.gigabyte,
        minimumFreeBytes: CacheSettings.gigabyte,
        criticalFreeBytes: 500_000_000
    )
}
