import Foundation

/// How long each step of one picture request took.
///
/// **Added 2026-09-16, to find twenty seconds nobody could place.** While the
/// agent re-read an 8,547-photograph album, `/v1/next` took 10 to 50 seconds
/// against 150–700 ms either side of it, and neither the `SERVE:` lines nor a
/// test with the same two connections could say where the time went. This is
/// the `TIMING:` line that can.
///
/// **A value the request carries, not a clock anybody shares.** One request
/// makes one of these and hands it down by `inout`, so there is no lock and
/// nothing to be `Sendable` about: the stages are the request's own, in the
/// order it met them.
public struct StageTimes: Sendable, Equatable {

    /// One named step, and all the time spent in it.
    public struct Stage: Sendable, Equatable {
        public let name: String
        public fileprivate(set) var took: Duration
    }

    /// In the order each was first met. A stage met twice — a request that
    /// checks two cards — is one entry holding both.
    public private(set) var stages: [Stage] = []
    private var mark: ContinuousClock.Instant

    public init(from start: ContinuousClock.Instant = .now) {
        mark = start
    }

    /// Charges everything since the last lap to `stage`, and starts the next.
    public mutating func lap(_ stage: String, now: ContinuousClock.Instant = .now) {
        let took = now - mark
        mark = now
        if let index = stages.firstIndex(where: { $0.name == stage }) {
            stages[index].took += took
        } else {
            stages.append(Stage(name: stage, took: took))
        }
    }

    /// `waited 0ms · open 2ms · check 1003ms`, one stage to a field.
    public var summary: String {
        stages.map { "\($0.name) \(Self.milliseconds($0.took))" }.joined(separator: " · ")
    }

    /// Whole milliseconds. A stage worth reading about is never a fraction of one.
    public static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return "\(seconds * 1000 + attoseconds / 1_000_000_000_000_000)ms"
    }
}
