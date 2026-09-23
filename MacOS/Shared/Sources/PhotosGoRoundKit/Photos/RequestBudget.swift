import Foundation
import PhotosGoRoundAgentAPI

/// One budget for all the library work a single response needs.
///
/// **Because a per-call bound is not a bound on an answer.** `BoundedPhotoLibrary`
/// gives each question ten seconds, which is right for the scan — it asks one
/// thing at a time and has all day. A response asks several: `/v2/photos/albums`
/// wants authorization and then a listing, and `/v2/sources` wants a title for
/// every Photos source it lists. Ten seconds each, added up, is a reply whose
/// length depends on how many albums somebody happens to have.
///
/// **Measured 2026-09-07, and it is why this exists.** Against a library that
/// had stopped answering, `GET /v2/photos/albums` came back at 10.0–10.7 s while
/// the app gave up at exactly 10.0 — so the agent's own sentence, *the photo
/// library did not answer collections*, never reached anybody, and the panel
/// said *the agent is not answering* about an agent that was answering. Two
/// bounds that equal each other are a race the outer one always loses, because
/// it starts first.
///
/// So the whole response shares one budget, and the client's bound sits well
/// above it. The agent always answers, and always in time to be heard.
///
/// **In the kit since 2026-09-16, so serving can spend one too.** It lived in
/// the agent's service while only endpoints used it. `PhotoCache.serve` asks a
/// source whether the picture going out is still there, and against a silent
/// Photos library that question took twenty seconds of a five-second client
/// bound. See `ServiceTiming.serveCheckBudget`.
public struct RequestBudget {

    /// **Held in `ServiceTiming` beside the client's bound**, because the two
    /// numbers only mean anything relative to each other and the bug was that
    /// they lived apart and drifted into equality. See that file.
    public static let `default` = ServiceTiming.responseBudget

    private let deadline: ContinuousClock.Instant
    /// What this budget was given, as opposed to what is left of it.
    ///
    /// **Reported instead of the remainder.** A failure raised from what was
    /// left printed as *within 7.999945958 seconds* — the arithmetic of a
    /// budget leaking into a sentence, and a different number every run, which
    /// makes a log impossible to compare against yesterday's.
    private let limit: Duration

    public init(_ limit: Duration = RequestBudget.default) {
        self.limit = limit
        deadline = .now + limit
    }

    /// What is left, never negative.
    public var remaining: Duration {
        let left = deadline - .now
        return left > .zero ? left : .zero
    }

    public var isSpent: Bool { remaining == .zero }

    /// Runs `work` against what is left, and answers nil when the budget is
    /// gone or the work would not answer inside it.
    ///
    /// For the questions a reply is *better* for having answered and does not
    /// need — a title, whether an album has a successor. Nil means fall back to
    /// what the store already knows.
    public func attempt<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T? {
        guard !isSpent else { return nil }
        return try? await Deadline.run(within: remaining, work)
    }

    /// Runs `work` against what is left, and throws when the budget is gone.
    ///
    /// For the questions a reply cannot be written without. The error is the
    /// same one the library itself raises, so a route reports one sentence
    /// whether the library ran out of patience or this did.
    public func require<T: Sendable>(
        _ what: String, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard !isSpent else {
            throw PhotoLibraryError.noAnswer(what: what, within: limit)
        }
        do {
            return try await Deadline.run(within: remaining, work)
        } catch is Deadline.Expired {
            throw PhotoLibraryError.noAnswer(what: what, within: limit)
        }
    }
}
