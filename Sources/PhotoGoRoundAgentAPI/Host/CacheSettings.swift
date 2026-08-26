import Foundation

/// How much the cache holds, how fast it fills, and when it stops.
///
/// Every number here is empirical rather than principled, which is why they are
/// all configurable and why the shipping defaults get set by the Phase 2
/// measurements rather than by guess.
public struct CacheSettings: Sendable, Equatable {

    /// Enough to keep a provider's latency covered without turning a warm-up
    /// into a thundering herd against one disk. Four is the number every package
    /// manager settled on, for the same reason: fetching is nearly all latency.
    ///
    /// **It is one number across every source, not one per source.** That is
    /// fine for folders, where it is a throughput knob against your own disk. It
    /// will not be once the Photos and Google providers exist, where it is a
    /// politeness limit against somebody else's service.
    public static let defaultConcurrency = 4


    /// The bound, and the only one.
    ///
    /// A photograph count stopped meaning anything once one photograph became an
    /// original plus several renderings, and it was always a poor proxy for the
    /// thing being protected: a thousand photographs is somewhere between 2 GB
    /// and 100 GB depending on whether they are phone JPEGs or ProRAW. Referenced
    /// photographs cost nothing here — they were never copied.
    ///
    /// 50 GB is a starting point to be replaced by measurement.
    public var byteCeiling: Int64

    /// Below this much free space, stop materializing and say why. Running out
    /// of disk should degrade into "the deck stops growing" rather than into a
    /// full volume, which on macOS is a genuinely bad day for everything else
    /// running.
    public var minimumFreeBytes: Int64

    /// Below this much, evict ahead of the ceiling until it recovers.
    public var criticalFreeBytes: Int64

    public static let gigabyte: Int64 = 1_000_000_000

    public init(
        byteCeiling: Int64 = 50 * CacheSettings.gigabyte,
        minimumFreeBytes: Int64 = 5 * CacheSettings.gigabyte,
        criticalFreeBytes: Int64 = 2 * CacheSettings.gigabyte
    ) {
        // Every one of these can arrive from `defaults write`, which accepts
        // anything, so each is a parse with a default and a clamp.
        self.byteCeiling = max(0, byteCeiling)
        self.minimumFreeBytes = max(0, minimumFreeBytes)
        self.criticalFreeBytes = max(0, min(criticalFreeBytes, minimumFreeBytes))
    }

    public static let `default` = CacheSettings()

    /// iOS carries a far smaller cache and fills it opportunistically rather
    /// than continuously. Same policy, smaller numbers.
    public static let phone = CacheSettings(
        byteCeiling: 2 * CacheSettings.gigabyte,
        minimumFreeBytes: CacheSettings.gigabyte,
        criticalFreeBytes: 500_000_000
    )
}
