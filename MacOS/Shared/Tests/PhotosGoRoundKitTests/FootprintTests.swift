import Foundation
import Testing

@testable import PhotosGoRoundAgentAPI

/// What a service says about the memory it is holding.
///
/// Syd, 2026-09-18: "what we should be doing is logging the RAM usage every five
/// minutes", and "for all three of the permanent services".
/// `Plans/Track RAM Usage.md`, Phase 3.
@Suite("Footprint")
struct FootprintTests {

    /// **The reading is the whole point**, so a kernel that would not answer is
    /// worth knowing about rather than a zero that reads like an empty process.
    @Test("The kernel answers, with a footprint no larger than resident size")
    func theReadingIsPlausible() throws {
        let reading = try #require(Footprint.now(), "the kernel refused TASK_VM_INFO")

        #expect(reading.footprint > 0)
        #expect(reading.resident > 0)
        // Footprint excludes what the allocator is holding to hand back, so it
        // is the smaller of the two — which is the reason it is the one
        // reported. Measured 2026-09-18: 299 MB against 531 MB resident.
        #expect(reading.footprint <= reading.resident)
    }

    @Test("Every reading raises the high-water mark, and nothing lowers it")
    func thePeakOnlyRises() {
        _ = Footprint.now()
        let peak = Footprint.peak

        #expect(peak > 0)
        _ = Footprint.now()
        #expect(Footprint.peak >= peak)
    }

    /// The line every service writes, so one `grep MEMORY:` reads all three.
    @Test("The line names both numbers and the uptime")
    func theLineReads() {
        let reading = Footprint.Reading(footprint: 299 * 1_048_576, resident: 531 * 1_048_576)

        let line = Footprint.line(reading, up: .seconds(6 * 3600 + 59 * 60))

        #expect(line.hasPrefix("MEMORY: footprint "))
        #expect(line.contains("resident "))
        #expect(line.hasSuffix("up 6h 59m"))
    }

    @Test("Under an hour is minutes alone")
    func shortUptimesAreMinutes() {
        #expect(Footprint.spoken(.seconds(59)) == "0m")
        #expect(Footprint.spoken(.seconds(300)) == "5m")
        #expect(Footprint.spoken(.seconds(3600)) == "1h 0m")
        #expect(Footprint.spoken(.seconds(3660)) == "1h 1m")
    }

    /// Five minutes, because that is what was asked for and because a curve
    /// read any coarser misses the shape.
    @Test("The interval is five minutes")
    func theIntervalIsFiveMinutes() {
        #expect(Footprint.interval == .seconds(300))
    }
}
