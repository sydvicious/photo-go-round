import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd

/// The `STARTUP:` lines: how long each step of a launch took.
///
/// Measured 2026-09-17 after a restart: the agent's process started at
/// 13:49:52 and answered its first request at 13:50:31 — 39 seconds, of which
/// the cache index rebuild was about 33. Whether that is the walk or a disk
/// still busy after boot, the log could not say. `TODO.md`, *The agent takes
/// about two minutes from launch to listening after a restart*.
@Suite("Startup timing")
struct StartupTimesTests {

    @Test("Each step says what it was and how long it took, as it finishes")
    func stepWording() {
        var startup = StartupTimes()
        #expect(startup.lap("storage", took: .milliseconds(120)) == "STARTUP: storage 120ms")
        #expect(startup.lap("cache index", took: .seconds(33)) == "STARTUP: cache index 33000ms")
    }

    @Test("The summary names every step in order, and the total")
    func summaryWording() {
        var startup = StartupTimes()
        _ = startup.lap("storage", took: .milliseconds(120))
        _ = startup.lap("migrate", took: .milliseconds(30))
        _ = startup.lap("cache index", took: .seconds(33))

        #expect(
            startup.summary(as: "listening")
                == "STARTUP: listening after storage 120ms · migrate 30ms · cache index 33000ms · total 33150ms")
    }
}
