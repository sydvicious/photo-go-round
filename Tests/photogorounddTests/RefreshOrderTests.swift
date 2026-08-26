import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd

/// Which sources get walked first on the pass after launch.
///
/// On 2026-08-25 this library held one local folder — `~/Pictures/Desktop
/// Pictures/`, 8,287 photographs, every one readable in place — and ten network
/// folders on `/Volumes/home` holding about 10,700 between them. The local one
/// had the highest id, so in the order sources were added it was walked *last*,
/// behind minutes of network traffic. The one source that could have put a
/// picture on screen in milliseconds was the last one the agent looked at.
@Suite("Refresh order")
struct RefreshOrderTests {

    private func library() throws -> (URL, SourceStore) {
        let directory = URL.temporaryDirectory.appending(path: "pgr-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "photogoround.sqlite").path(percentEncoded: false)
        let database = try Database(path: path)
        try Migrator.migrate(database)
        return (directory, SourceStore(database: database))
    }

    @Test("The local folder is walked first, however late it was added")
    func localSourceGoesFirst() async throws {
        let (directory, store) = try library()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Network folders added first, exactly as this library had them, and the
        // local one added last so it has the highest id.
        for name in ["Negatives", "Prints", "Slides"] {
            try await store.add(kind: .folder, locator: "/Volumes/home/Archive/Pictures/\(name)/")
        }
        let local = directory.appending(path: "Desktop Pictures")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let localSource = try await store.add(
            kind: .folder, locator: local.path(percentEncoded: false) + "/")

        let ordered = RunCommand.localFirst(try store.all())
        #expect(
            ordered.first?.id == localSource.id,
            "the local folder was not walked first: \(ordered.map(\.locator))"
        )
    }

    /// The network sources keep the order they were added in, so the walk stays
    /// predictable and two runs agree.
    @Test("Ordering is stable within each group")
    func orderIsStableWithinGroups() async throws {
        let (directory, store) = try library()
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["A", "B", "C"] {
            try await store.add(kind: .folder, locator: "/Volumes/home/\(name)/")
        }
        let ordered = RunCommand.localFirst(try store.all())
        #expect(ordered.map(\.locator) == ["/Volumes/home/A/", "/Volumes/home/B/", "/Volumes/home/C/"])
    }

    @Test("A folder that is only network keeps every source, none dropped")
    func nothingIsLost() async throws {
        let (directory, store) = try library()
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["A", "B"] {
            try await store.add(kind: .folder, locator: "/Volumes/home/\(name)/")
        }
        let local = directory.appending(path: "here")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try await store.add(kind: .folder, locator: local.path(percentEncoded: false) + "/")

        let all = try store.all()
        let ordered = RunCommand.localFirst(all)
        #expect(Set(ordered.map(\.id)) == Set(all.map(\.id)))
        #expect(ordered.count == all.count)
    }

    /// A path that is not there at all must not be guessed as local. An
    /// unmounted share resolves to nothing, and treating it as fast would put
    /// the slowest possible source at the front of the pass.
    @Test("An unreachable path is not treated as local")
    func unreachablePathIsNotLocal() async throws {
        let (directory, store) = try library()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.add(kind: .folder, locator: "/Volumes/not-mounted-\(UUID().uuidString)/")
        let source = try #require(try store.all().first)
        #expect(!RunCommand.isOnBootVolume(source))
    }

    @Test("A real local directory is recognised")
    func localDirectoryIsRecognised() async throws {
        let (directory, store) = try library()
        defer { try? FileManager.default.removeItem(at: directory) }

        let local = directory.appending(path: "pictures")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try await store.add(kind: .folder, locator: local.path(percentEncoded: false) + "/")
        let source = try #require(try store.all().first)
        #expect(RunCommand.isOnBootVolume(source))
    }
}

/// A source that scans cleanly and holds nothing.
///
/// `+0 -0 =0` is what an empty folder looks like, and also what four and a half
/// thousand photographs look like when they are one directory below a source
/// that is not recursive. The second is silent for ever — enabled, available,
/// freshly scanned, contributing nothing — which is how it went unnoticed on a
/// real library until somebody asked why no pictures were appearing from it.
@Suite("Noticing a source that found nothing")
struct EmptySourceTests {

    private func result(
        added: Int, removed: Int, unchanged: Int, unavailable: Bool = false
    ) -> ScanResult {
        ScanResult(
            sourceID: 13, added: added, removed: removed, unchanged: unchanged,
            sourceUnavailable: unavailable, reason: unavailable ? "not mounted" : nil,
            bytesFreed: 0)
    }

    @Test("A walk that saw no photographs is empty")
    func nothingSeenIsEmpty() {
        #expect(Reporter.scannedEmpty(result(added: 0, removed: 0, unchanged: 0)))
    }

    @Test("A source whose last photograph just went is empty too")
    func emptiedIsEmpty() {
        // The interesting transition, and the one a count of `added` alone
        // would miss.
        #expect(Reporter.scannedEmpty(result(added: 0, removed: 12, unchanged: 0)))
    }

    @Test("A source with photographs is not, however little changed")
    func populatedIsNot() {
        #expect(!Reporter.scannedEmpty(result(added: 0, removed: 0, unchanged: 4517)))
        #expect(!Reporter.scannedEmpty(result(added: 1, removed: 0, unchanged: 0)))
    }

    @Test("An unreachable source is not called empty")
    func unavailableIsADifferentFact() {
        // It reports zero because nothing could be counted, not because there
        // is nothing there — and unavailability is already reported on its own.
        #expect(!Reporter.scannedEmpty(result(added: 0, removed: 0, unchanged: 0, unavailable: true)))
    }
}

/// A refresh pass runs off the loop.
///
/// **Every source was walked inside the tick**, so nothing else in the loop ran
/// meanwhile. That read as solved when the `walk_seen` diff took a
/// 5,093-photograph source from eighty-five minutes to 1.1 seconds — and a
/// network share of 4,510 put it back to 30.9 seconds on 2026-08-26, during
/// which a removed source left the deck empty and the window blank.
@Suite("One refresh pass at a time")
struct RefreshPassTests {

    @Test("A second tick cannot start a pass over the first")
    func onePassAtATime() {
        let pass = Latch()

        #expect(pass.tryEnter(), "the first tick must get in")
        #expect(!pass.tryEnter(), "a tick started a second pass over a running one")
        #expect(pass.isHeld)

        pass.leave()
        #expect(pass.tryEnter(), "a finished pass must let the next one in")
    }

    @Test("Finishing is reported to the loop rather than stamped by the pass")
    func finishingIsHandedBack() {
        // The heartbeat belongs to the loop, so a detached pass raises a flag
        // and the loop stamps it on the next tick. Read-and-clear, so one
        // finished pass is stamped exactly once.
        let finished = Flag()
        #expect(!finished.lower())

        finished.raise()
        #expect(finished.lower())
        #expect(!finished.lower(), "one pass was stamped twice")
    }

    @Test("A pass that is still running leaves the heartbeat saying it is due")
    func aRunningPassDoesNotStampItself() {
        // `isDue` reads the last *finish*, so it keeps saying yes for as long as
        // a pass runs. The latch is the only thing standing between that and a
        // new pass every tick — which is why it is a latch and not a flag.
        var heartbeat = Heartbeat()
        let now = Date(timeIntervalSince1970: 1_000)
        let pass = Latch()

        #expect(heartbeat.isDue(.refresh, every: .seconds(300), at: now))
        #expect(pass.tryEnter())
        // Ten ticks go by while the walk runs.
        for tick in 1...10 {
            let later = now.addingTimeInterval(Double(tick))
            #expect(heartbeat.isDue(.refresh, every: .seconds(300), at: later))
            #expect(!pass.tryEnter(), "tick \(tick) started a second pass")
        }
    }
}
