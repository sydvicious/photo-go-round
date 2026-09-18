import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// What the reconciliation reads and what it writes, and how much of each it
/// does under the writer.
///
/// **Measured on 2026-09-18, the first reboot after the fixed port landed.**
/// `reconcileResidency` held the write lock for `17208ms · commit 0ms` — the
/// time was in the statements, not the fsync. `EXPLAIN QUERY PLAN` named it:
/// clearing the rows recorded as held and no longer on disk was `SCAN photo`, a
/// full table scan, and a scan of thirty thousand rows a minute after a reboot
/// is thirty thousand rows off a cold disk. Warm, the same reconciliation took
/// 7.9 ms, which is why nothing had noticed in months.
///
/// Syd, 2026-09-10: "doing this 100 at a time saves ram and keeps the database
/// locks short." `Plans/Agent Performance Overhaul.md`, Phase 4's shape applied
/// where Phase 4 did not reach.
@Suite("Residency paging")
struct ResidencyPagingTests {

    private struct Fixture {
        let directory: URL
        let library: TestLibrary
        let cache: PhotoCache
        let source: Source

        init(photographs: Int, recordedAsHeld: Int) async throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-resid-\(UUID().uuidString)")
            library = try TestLibrary.onDisk(at: directory)
            let store = SourceStore(database: library.database)
            let folder = TemporaryFolder(name: "pgr-resid-src")
            folder.write("seed.png", bytes: 16)
            source = try store.add(kind: .folder, locator: folder.path)

            // Seeded through a static, because a stored property cannot be
            // assigned before a closure in the same `init` has been past.
            try await Self.seed(
                library.database, source: source.id, photographs: photographs,
                recordedAsHeld: recordedAsHeld)

            var cache = PhotoCache(
                database: library.database, root: directory.appending(path: "cache"),
                sources: store, store: PhotoStore(root: directory))
            cache.log = { _ in }
            self.cache = cache
        }

        private static func seed(
            _ database: Database, source: Int64, photographs: Int, recordedAsHeld: Int
        ) async throws {
            let now = SQLValue(Date())
            try await database.transaction(.immediate) {
                for index in 0..<photographs {
                    var row: [String: SQLValue] = [:]
                    row["s"] = SQLValue(source)
                    row["u"] = SQLValue("U\(index)")
                    row["e"] = SQLValue("E\(index)")
                    row["k"] = SQLValue(Double(index))
                    row["a"] = now
                    row["c"] = index < recordedAsHeld ? now : SQLValue.null
                    try database.run(
                        "INSERT INTO photo (source_id, uuid, external_id, shuffle_key, added_at, cached_at)"
                            + " VALUES (:s, :u, :e, :k, :a, :c);", row)
                }
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }

        func recorded() throws -> Set<String> {
            Set(
                try library.database.all("SELECT uuid FROM photo WHERE cached_at IS NOT NULL;") {
                    try $0.string("uuid")
                })
        }
    }

    @Test("What is no longer held is cleared a page of 100 at a time")
    func clearingGoesInPages() async throws {
        let fixture = try await Fixture(photographs: 500, recordedAsHeld: 250)
        defer { fixture.cleanUp() }

        let result = try await fixture.cache.reconcileResidency(with: [])

        #expect(result.cleared == 250)
        #expect(result.recorded == 0)
        #expect(result.pages == 3, "250 to clear is 100 + 100 + 50")
        #expect(try fixture.recorded().isEmpty)
    }

    @Test("What is held and unrecorded is recorded a page of 100 at a time")
    func recordingGoesInPages() async throws {
        let fixture = try await Fixture(photographs: 500, recordedAsHeld: 0)
        defer { fixture.cleanUp() }
        let resident = Set((0..<150).map { "U\($0)" })

        let result = try await fixture.cache.reconcileResidency(with: resident)

        #expect(result.recorded == 150)
        #expect(result.pages == 2, "150 to record is 100 + 50")
        #expect(try fixture.recorded() == resident)
    }

    /// **The ordinary case, and it must cost nothing.** The walk runs at launch
    /// and every hour; almost every time it finds exactly what the database
    /// already says, and a reconciliation that took the writer to discover that
    /// is the 17 seconds this came from.
    @Test("A reconciliation with nothing to change takes no transaction at all")
    func agreementTakesNoLock() async throws {
        let fixture = try await Fixture(photographs: 500, recordedAsHeld: 120)
        defer { fixture.cleanUp() }
        let resident = Set((0..<120).map { "U\($0)" })

        let result = try await fixture.cache.reconcileResidency(with: resident)

        #expect(result == PhotoCache.Residency(recorded: 0, cleared: 0, pages: 0))
        #expect(try fixture.recorded() == resident)
    }

    /// Both directions in one pass, which is what a drifted database looks
    /// like: some files gone, some arrived behind the agent's back.
    @Test("Recording and clearing happen in the same reconciliation")
    func bothDirectionsAtOnce() async throws {
        let fixture = try await Fixture(photographs: 500, recordedAsHeld: 100)
        defer { fixture.cleanUp() }
        // Half of what is recorded is gone; a hundred new ones are here.
        let resident = Set((50..<250).map { "U\($0)" })

        let result = try await fixture.cache.reconcileResidency(with: resident)

        #expect(result.cleared == 50, "U0…U49 were recorded and are no longer held")
        #expect(result.recorded == 150, "U100…U249 are held and were not recorded")
        #expect(try fixture.recorded() == resident)
    }

    /// A file on disk whose row has gone — a source removed between the walk
    /// and the reconciliation. It updates nothing, which is the right answer.
    @Test("A resident photograph with no row changes nothing")
    func aResidentWithNoRowIsHarmless() async throws {
        let fixture = try await Fixture(photographs: 10, recordedAsHeld: 0)
        defer { fixture.cleanUp() }

        let result = try await fixture.cache.reconcileResidency(with: ["GONE-1", "GONE-2"])

        #expect(result.recorded == 2, "it asked for two, and neither matched a row")
        #expect(try fixture.recorded().isEmpty)
    }
}
