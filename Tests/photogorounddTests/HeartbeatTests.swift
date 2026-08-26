import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd
@testable import PhotoGoRoundAgentAPI

/// The agent's schedule.
///
/// Four lines of arithmetic that decided whether the agent served anything at
/// all, and which nothing could reach while they lived inside the run loop.
@Suite("Heartbeat")
struct HeartbeatTests {

    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Work that outruns its own interval

    /// **The re-arm bug, stated as a property.**
    ///
    /// A refresh that takes longer than the scan interval must still get a full
    /// interval of quiet afterwards. Stamping the time read at the top of the
    /// tick meant the opposite: the pass satisfied its own next deadline the
    /// moment it ended, so the next tick started another, and the loop never
    /// came back to anything else.
    @Test("A pass longer than its interval still gets a full interval afterwards")
    func longWorkDoesNotReArmItself() {
        var heartbeat = Heartbeat()
        let interval = Duration.seconds(300)

        // Due at launch, because it has never run.
        #expect(heartbeat.isDue(.refresh, every: interval, at: epoch))

        // The pass runs for six minutes — longer than the five-minute interval.
        let ended = epoch.addingTimeInterval(360)
        heartbeat.finished(.refresh, at: ended)

        // The bug: `isDue` at the moment it ended was true, because the
        // timestamp recorded was the one read before it started.
        #expect(!heartbeat.isDue(.refresh, every: interval, at: ended))
        #expect(!heartbeat.isDue(.refresh, every: interval, at: ended.addingTimeInterval(299)))
        #expect(heartbeat.isDue(.refresh, every: interval, at: ended.addingTimeInterval(300)))
    }

    @Test("Every job keeps its own clock")
    func jobsAreIndependent() {
        var heartbeat = Heartbeat()
        heartbeat.finished(.refresh, at: epoch)

        #expect(!heartbeat.isDue(.refresh, every: .seconds(300), at: epoch))
        // Never run, so due — a long refresh must not make the queue look fresh.
        #expect(heartbeat.isDue(.queue, every: .seconds(30), at: epoch))
        #expect(heartbeat.isDue(.maintenance, every: .seconds(600), at: epoch))
    }

    @Test("The doorbell overrides the clock")
    func forcedIsDueRegardless() {
        var heartbeat = Heartbeat()
        heartbeat.finished(.refresh, at: epoch)
        #expect(!heartbeat.isDue(.refresh, every: .seconds(300), at: epoch))
        #expect(heartbeat.isDue(.refresh, every: .seconds(300), at: epoch, forced: true))
    }

    @Test("Nothing has run at launch, so everything is due")
    func everythingIsDueAtLaunch() {
        let heartbeat = Heartbeat()
        for work in Heartbeat.Work.allCases {
            #expect(heartbeat.isDue(work, every: .seconds(3600), at: epoch))
            #expect(heartbeat.lastFinished(work) == nil)
        }
    }

    // MARK: - What runs first

    /// **The queue is seeded before anything is refreshed, but only at launch.**
    ///
    /// A restart already has a pool in the database and a cache index rebuilt
    /// from disk, so photographs can usually be dealt and served at once — while
    /// a refresh of a network source is minutes with the loop inside it.
    @Test("Launch seeds the queue before it refreshes")
    func launchPutsTheQueueFirst() {
        let first = Heartbeat.order(launching: true)
        let refresh = try! #require(first.firstIndex(of: .refresh))
        let queue = try! #require(first.firstIndex(of: .queue))
        #expect(queue < refresh, "a restart waited out a network walk before serving anything")
    }

    /// And afterwards the order goes back, so a queue seeded on a tick reflects
    /// whatever that tick's refresh just found.
    @Test("After launch, refreshing comes before seeding again")
    func steadyStatePutsRefreshFirst() {
        let later = Heartbeat.order(launching: false)
        let refresh = try! #require(later.firstIndex(of: .refresh))
        let queue = try! #require(later.firstIndex(of: .queue))
        #expect(refresh < queue)
    }

    @Test("Every job appears exactly once in a tick, whichever order it is")
    func everyJobRunsOncePerTick() {
        for launching in [true, false] {
            let order = Heartbeat.order(launching: launching)
            #expect(Set(order).count == order.count)
            #expect(Set(order) == Set(Heartbeat.Work.allCases))
        }
    }
}

/// Seeding the queue with no provider, no scan, and no network.
///
/// This is the substance of "the queue should start before the refresh": the
/// photographs are already in the pool from the last run, so there is nothing to
/// wait for. If seeding needed a refresh to have happened first, putting it
/// first would buy nothing.
@Suite("Seeding from a pool that is already there")
struct ColdStartSeedTests {

    @Test("A restart deals from the existing pool without refreshing anything")
    func poolFromTheLastRunSeedsImmediately() async throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-coldstart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "photogoround.sqlite").path(percentEncoded: false)
        let database = try Database(path: path)
        try Migrator.migrate(database)

        // A pool left behind by a previous run, on a source whose volume is not
        // even mounted — nothing here can be walked.
        try database.run(
            """
            INSERT INTO source (uuid, kind, locator, enabled, added_at)
            VALUES (:uuid, 'folder', '/Volumes/elsewhere/', 1, 0);
            """,
            ["uuid": .text(UUID().uuidString.lowercased())]
        )
        let source = database.lastInsertRowID
        for index in 0..<50 {
            try database.run(
                """
                INSERT INTO photo (uuid, source_id, external_id, media_type, source_enabled,
                                   storage, shuffle_key, added_at)
                VALUES (:uuid, :source, :external, 'image', 1, 'materialized', :key, 0);
                """,
                [
                    "uuid": .text(UUID().uuidString.lowercased()), "source": .int(source),
                    "external": .text("photo-\(index).heic"), "key": .double(Double(index) / 50),
                ]
            )
        }

        #expect(try PhotoQueue(database: database, nominalSize: 20).size() == 0)

        let box = FillerBox()
        let cacheRoot = directory.appending(path: "cache")
        box.configure(
            databasePath: path, cacheRoot: cacheRoot, store: PhotoStore(root: cacheRoot),
            pending: nil)
        let preferences = Preferences(
            defaults: UserDefaults(suiteName: "pgr.coldstart.\(UUID())")!)
        let round = await box.topUpIfShort(preferences: preferences)

        #expect(round.failure == nil, "seeding failed: \(round.failure ?? "")")
        #expect(round.produced > 0, "a restart could not deal from a pool it already had")
        #expect(try PhotoQueue(database: database, nominalSize: 20).size() > 0)
    }
}
