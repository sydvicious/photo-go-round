import Foundation

/// How much the cache holds, how fast it fills, and when it stops.
///
/// Every number here is empirical rather than principled, which is why they are
/// all configurable and why the shipping defaults get set by the Phase 2
/// measurements rather than by guess.
public struct CacheSettings: Sendable, Equatable {

    /// How long a materialize may take before its lane is taken back.
    ///
    /// **Two numbers because the providers differ by an order of magnitude.** A
    /// file on the boot volume has no excuse for taking a minute; one on an
    /// iCloud Drive folder that is not downloaded locally hands off to `bird`
    /// and, measured on 2026-08-25, does not return at all. Sixty seconds is
    /// generous for a read and short enough that a stuck one is a blip.
    public static let fileFetchLimit = Duration.seconds(60)

    /// The same bound for a photo library. **The same number, since
    /// 2026-09-05.**
    ///
    /// It was fifteen minutes, from a measurement in the Photos spike where
    /// three of five downloads paid a fixed 300-second stall before
    /// transferring normally. That measurement was taken on a day when
    /// everything touching iCloud on the machine was wedged, which was not
    /// known until later — it described the machine, not the provider. A stall
    /// is a stall, and a card at the head of the queue cannot wait a quarter of
    /// an hour for one.
    public static let libraryFetchLimit = Duration.seconds(60)


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
    /// A photograph count was always a poor proxy for the thing being protected:
    /// a thousand photographs is somewhere between 2 GB and 100 GB depending on
    /// whether they are phone JPEGs or ProRAW. Referenced photographs cost
    /// nothing here — they were never copied.
    ///
    /// **1 GB, from the queue rather than from a guess. Set 2026-09-06.** The
    /// cache is somewhere to put downloads long enough to serve the queue, which
    /// is what it had become in practice; twice the queue's own working set is
    /// the whole requirement. At a queue of 20 and a measured mean original of
    /// 2.95 MB across 2905 cached photographs, `2 × 20 × 2.95 MB` is 118 MB,
    /// rounded up to the nearest gigabyte.
    ///
    /// It was 10 GB, back when the cache was also a prediction about what would
    /// be wanted soon and held a resize per `(photo, display box)` on top of
    /// every original. **The point of a smaller number is the disk**, and
    /// particularly a laptop set to Optimize Mac Storage, where a photograph is
    /// on the volume twice: Photos downloads the original as purgeable space and
    /// we materialize our own copy beside it. This bounds our half. It does
    /// nothing about theirs.
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
        byteCeiling: Int64 = CacheSettings.gigabyte,
        minimumFreeBytes: Int64 = 5 * CacheSettings.gigabyte,
        criticalFreeBytes: Int64 = 2 * CacheSettings.gigabyte
    ) {
        // Every one of these can arrive from `defaults write`, which accepts
        // anything, so each is a parse with a default and a clamp.
        self.byteCeiling = max(0, byteCeiling)
        self.minimumFreeBytes = max(0, minimumFreeBytes)
        self.criticalFreeBytes = max(0, min(criticalFreeBytes, minimumFreeBytes))
    }

    /// **One set of numbers, for every platform. Decided 2026-09-06.** There was
    /// a `phone` preset beside this — a 2 GB ceiling, on the reasoning that iOS
    /// carries a smaller cache and fills it opportunistically. It went when the
    /// Mac ceiling came down to 1 GB and made the phone's the larger of the two.
    /// The ceiling follows the queue rather than the device, and the queue is
    /// the same everywhere; a device that genuinely needs a different number can
    /// be told one through the preference, which is why it is a preference.
    public static let `default` = CacheSettings()
}
