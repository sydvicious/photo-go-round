import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit
@testable import photogoroundd

/// Which bound fires first, and why it has to be that one.
///
/// **The measured fault, 2026-09-07.** Against a photo library that had stopped
/// answering, the agent replied at 10.0–10.7 seconds and the Mac app gave up at
/// exactly 10.0 — every time, for twenty minutes of log. So the agent's own
/// sentence, *the photo library did not answer collections*, never reached
/// anybody; the panel said *the agent is not answering* about an agent that was
/// answering perfectly and naming the real culprit.
///
/// **Two bounds that equal each other are a race the outer one always loses**,
/// because it starts first and pays the request's overhead as well. These pin
/// the ordering so a later edit to any one number cannot quietly close the gap
/// again — nothing else in the system would notice, and the symptom is a
/// sentence blaming the wrong machine.
@Suite("Which bound fires first")
struct BoundOrderingTests {

    /// The agent stops asking its library before the library's own per-call
    /// bound, so a reply is always written rather than waited for.
    @Test("The agent's per-response budget is under the library's per-call bound")
    func theAgentGivesUpBeforeItsLibraryDoes() {
        #expect(RequestBudget.default < BoundedPhotoLibrary.metadataLimit)
    }

    /// **The invariant the failure was.** The client must still be listening
    /// when the agent answers, or the agent's reason — the one naming the photo
    /// library — is replaced by the client's guess about the agent.
    ///
    /// Assertable at all only because both numbers now live in `ServiceTiming`.
    /// While they sat in modules that cannot see each other, nothing could have
    /// caught them being equal.
    @Test("The client is still listening when the agent answers")
    func theClientOutwaitsTheAgent() {
        #expect(ServiceTiming.clientReadLimit > ServiceTiming.responseBudget * 2)
    }

    /// One budget for the whole response, however many sources it describes.
    /// This is what stops a list of twenty albums costing twenty bounds.
    @Test("A budget spent once stays spent")
    func aBudgetIsSharedNotRepeated() async {
        let budget = RequestBudget(.milliseconds(50))
        let slow: Int? = await budget.attempt {
            try? await Task.sleep(for: .seconds(60))
            return 1
        }
        #expect(slow == nil)
        #expect(budget.isSpent)

        // The next question does not start another clock.
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await budget.attempt { 7 } == nil)
        #expect(clock.now - started < .milliseconds(50))
    }

    /// Nothing is taken away while the library is answering: a question asked
    /// inside the budget is answered, not refused.
    @Test("A budget with time left answers normally")
    func aBudgetWithTimeLeftAnswers() async {
        let budget = RequestBudget(.seconds(30))
        #expect(await budget.attempt { 7 } == 7)
        #expect(!budget.isSpent)
    }

    /// A question a reply cannot be written without says which one went
    /// unanswered, in the same words the library itself would have used.
    @Test("A required question names itself when the budget runs out")
    func aRequiredQuestionNamesItself() async {
        let budget = RequestBudget(.milliseconds(50))
        do {
            _ = try await budget.require("collections") {
                try await Task.sleep(for: .seconds(60))
            }
            Issue.record("expected a failure")
        } catch let error as PhotoLibraryError {
            guard case .noAnswer(let what, _) = error else {
                Issue.record("expected noAnswer, got \(error)")
                return
            }
            #expect(what == "collections")
        } catch {
            Issue.record("expected PhotoLibraryError, got \(error)")
        }
    }
}
