import Foundation
import Testing

@testable import PhotoGoRoundDisplay

/// What a surface does when an ask finds no agent.
///
/// The case this was written for: a reboot. Measured 2026-09-18, the wallpaper
/// extension asked 5 and 51 seconds before the agent was listening, on two
/// reboots, and then waited its whole interval — ten minutes then, and up to
/// twelve hours if the interval were set there.
@Suite("Retry after silence")
struct RetryAfterSilenceTests {

    private let interval = Duration.seconds(600)

    @Test("While the agent answers, the wait is the rotation interval")
    func answeringIsTheOrdinaryWait() {
        var retry = RetryAfterSilence()
        #expect(retry.wait(interval: interval) == interval)
        #expect(retry.waiting == nil)
    }

    /// **The whole point.** A picture missed at boot comes back in ten seconds,
    /// not in ten minutes.
    @Test("The first silence is answered in ten seconds, not in an interval")
    func firstSilenceIsShort() {
        var retry = RetryAfterSilence()

        let said = retry.wentQuiet(cap: interval)
        #expect(said, "the first silence should say so")

        #expect(retry.wait(interval: interval) == .seconds(10))
    }

    @Test("A silence that goes on doubles, and stops at the interval")
    func silenceBacksOff() {
        var retry = RetryAfterSilence()
        var waits: [Duration] = []
        for _ in 0..<8 {
            retry.wentQuiet(cap: interval)
            waits.append(retry.wait(interval: interval))
        }

        #expect(
            waits == [
                .seconds(10), .seconds(20), .seconds(40), .seconds(80), .seconds(160),
                .seconds(320), .seconds(600), .seconds(600),
            ])
    }

    /// Never slower than the ordinary rotation: a ten-second interval with a
    /// long silence behind it must not wait longer than ten seconds.
    @Test("The backoff never outlasts the interval it is backing off from")
    func theCapIsTheInterval() {
        var retry = RetryAfterSilence()
        for _ in 0..<10 { retry.wentQuiet(cap: .seconds(10)) }

        #expect(retry.wait(interval: .seconds(10)) == .seconds(10))
    }

    @Test("An answer clears the backoff, and says it had been silent")
    func answeringClearsIt() {
        var retry = RetryAfterSilence()
        retry.wentQuiet(cap: interval)
        retry.wentQuiet(cap: interval)

        let wasSilent = retry.answered()
        #expect(wasSilent, "it had been silent, which is worth a line")

        #expect(retry.waiting == nil)
        #expect(retry.wait(interval: interval) == interval)
        let againSilent = retry.answered()
        #expect(!againSilent, "answering twice is not a transition")
    }

    /// Only the transitions are worth saying: a surface that cannot reach the
    /// agent for an hour should not write a line every ten seconds.
    @Test("Only the first silence reports itself")
    func onlyTransitionsReport() {
        var retry = RetryAfterSilence()

        let first = retry.wentQuiet(cap: interval)
        let second = retry.wentQuiet(cap: interval)
        let third = retry.wentQuiet(cap: interval)

        #expect(first)
        #expect(!second)
        #expect(!third)
    }
}
