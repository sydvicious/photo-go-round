import Darwin
import Foundation
import Synchronization

/// What this process is holding, asked of the kernel rather than of a person.
///
/// **Because resident size is the wrong number.** Measured 2026-09-18 after
/// seven hours and 1,777 fetches: `ps` reported the agent at **531 MB** while
/// `footprint` reported **299 MB**, of which 181 MB in `Malloc Large` was
/// *reclaimable* — pages the allocator had been given back and had not returned
/// to the kernel. The live figure was nearer 120 MB. Every sample in
/// `Plans/Track RAM Usage.md` before that date is an `rss` and overstates by
/// roughly double.
///
/// `phys_footprint` is what `footprint(1)` prints and what the kernel charges
/// against a memory limit, so it is the number that means something. It costs
/// one `task_info` call and no subprocess.
///
/// Syd, 2026-09-18: "what we should be doing is logging the RAM usage every five
/// minutes." `Plans/Track RAM Usage.md`, Phase 3 — a sample that is a property
/// of the agent rather than of somebody remembering to look.
public enum Footprint {

    public struct Reading: Sendable, Equatable {
        /// What the kernel charges this process, as `footprint(1)` reports it.
        public let footprint: Int64
        /// Resident size, the `ps` figure, kept for comparison with the samples
        /// taken by hand before this existed.
        public let resident: Int64

        public init(footprint: Int64, resident: Int64) {
            self.footprint = footprint
            self.resident = resident
        }
    }

    /// How often each service says what it is holding. Syd, 2026-09-18: "what
    /// we should be doing is logging the RAM usage every five minutes", and
    /// "for all three of the permanent services".
    public static let interval = Duration.seconds(300)

    private static let started = Atomic(false)
    private static let highest = Atomic<Int64>(0)

    /// The largest footprint seen since launch, from every `now()` any caller
    /// has taken — the ticker's five-minutely ones and the dashboard's. A curve
    /// read once an hour would miss the spike that matters.
    public static var peak: Int64 { highest.load(ordering: .relaxed) }

    /// Starts this process's ticker, once. A second call does nothing, so a
    /// service that has several entry points — a wallpaper surface, a saver
    /// view — can call it from all of them.
    ///
    /// **Each service says it in its own voice**, because they log to different
    /// places: the agent to the console and the unified log, the extension and
    /// the saver to theirs. The line is the same either way, so one `grep
    /// MEMORY:` reads all three.
    public static func startLogging(_ say: @escaping @Sendable (String) -> Void) {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let clock = ContinuousClock()
        let from = clock.now
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if let reading = now() { say(line(reading, up: from.duration(to: clock.now))) }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    /// Nil when the kernel refuses, which nothing in this project has seen; a
    /// missing sample is not worth failing anything over.
    public static func now() -> Reading? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let outcome = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard outcome == KERN_SUCCESS else { return nil }
        let reading = Reading(
            footprint: Int64(info.phys_footprint), resident: Int64(info.resident_size))
        // Every reading updates the high-water mark, whoever took it.
        var seen = highest.load(ordering: .relaxed)
        while reading.footprint > seen {
            let (exchanged, current) = highest.compareExchange(
                expected: seen, desired: reading.footprint, ordering: .acquiringAndReleasing)
            if exchanged { break }
            seen = current
        }
        return reading
    }

    /// `MEMORY: footprint 299 MB · resident 531 MB · up 6h 59m`
    ///
    /// One line, prefixed like every other diagnostic here, so a night of them
    /// is `log show | grep MEMORY:` and a column of numbers.
    public static func line(_ reading: Reading, up uptime: Duration) -> String {
        "MEMORY: footprint \(bytes(reading.footprint)) · resident \(bytes(reading.resident))"
            + " · up \(spoken(uptime))"
    }

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .memory))
    }

    /// Hours and minutes, because a memory curve is read across hours and the
    /// seconds are noise.
    static func spoken(_ uptime: Duration) -> String {
        let minutes = Int(uptime.components.seconds / 60)
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
    }
}
