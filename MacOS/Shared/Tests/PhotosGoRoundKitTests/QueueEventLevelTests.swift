import Foundation
import OSLog
import Testing

@testable import PhotosGoRoundKit

/// **What a release build persists, and what it does not.**
///
/// `.default` persists to disk and is therefore the retention budget; `.info`
/// does not unless asked. This pins which side of that line each queue event
/// falls on, so a case added later cannot quietly spend the budget — and so the
/// demotion itself cannot be quietly undone.
///
/// Every test passes the rung explicitly rather than reading `Log.chatter`,
/// because a test run is a Debug build, where the rung *is* `.default` and every
/// case would look identical. `Plans/Logging.md`, Phase 2.
@Suite("How loud each queue event is")
struct QueueEventLevelTests {

    /// What per-request traffic takes in a release build.
    private let quiet = OSLogType.info

    private func photo(_ name: String = "a.jpg") -> String { name }

    @Test("The library changing is persisted in every build")
    func theLibraryChangingIsPersisted() {
        let events: [QueueEvent] = [
            .dropped(photo: photo(), source: 1, because: "gone", queued: 3),
            .cacheFailed(photo: photo(), source: 1, because: "offline"),
            .cacheTimedOut(photo: photo(), source: 1, after: .seconds(10)),
            .sourcePaused(source: 1, until: .seconds(60)),
            .configurationChanged(what: "queueSize 20 → 30"),
        ]
        for event in events {
            #expect(event.level(chatter: quiet) == .default, "\(event.line)")
        }
    }

    /// The deck coming up empty contradicts *always have something to show*, so
    /// it is never the thing a release build drops.
    @Test("Nothing to show is persisted in every build")
    func nothingToShowIsPersisted() {
        let event = QueueEvent.nothingToShow(walked: 20, because: "out of cards")
        #expect(event.level(chatter: quiet) == .default)
    }

    /// Announced before the wait so a request that hangs is distinguishable from
    /// one that is silent. Syd, 2026-09-19, on demoting it: log rotation will
    /// save us.
    @Test("Waiting is persisted in every build")
    func waitingIsPersisted() {
        let event = QueueEvent.waiting(photo: photo(), source: 1, upTo: .seconds(5), queued: 4)
        #expect(event.level(chatter: quiet) == .default)
    }

    @Test("The queues turning over drops a rung outside Debug and Claude builds")
    func ordinaryTrafficDropsARung() {
        let events: [QueueEvent] = [
            .dealt(photo: photo(), source: 1, queued: 19),
            .skipped(photo: photo(), source: 1, because: "not here", queued: 18),
            .caching(photo: photo(), source: 1, within: .seconds(20)),
            .cacheUnnecessary(photo: photo(), source: 1),
            .cached(photo: photo(), source: 1, bytes: 1024),
            .cacheDropped(photo: photo(), source: 1, because: "no bytes", queued: 17),
        ]
        for event in events {
            #expect(event.level(chatter: quiet) == quiet, "\(event.line)")
        }
    }

    /// **The ordinary success is the most frequent line in the system**, and the
    /// unconfirmed one beside it is the single moment the deleted-photo
    /// guarantee is knowingly relaxed. They must not share a level.
    @Test("A confirmed serve drops a rung; an unconfirmed one does not")
    func servingSplitsOnUnconfirmed() {
        let confirmed = QueueEvent.serving(
            photo: photo(), source: 1, unconfirmed: nil, queued: 19)
        let unconfirmed = QueueEvent.serving(
            photo: photo(), source: 1, unconfirmed: "the volume is not mounted", queued: 19)

        #expect(confirmed.level(chatter: quiet) == quiet)
        #expect(unconfirmed.level(chatter: quiet) == .default)
    }

    /// **A Debug or Claude build says everything**, which is the other half of
    /// the policy: the rung moves, nothing is silenced.
    @Test("Nothing is below default when the rung is default")
    func aWatchedBuildSaysEverything() {
        let events: [QueueEvent] = [
            .dealt(photo: photo(), source: 1, queued: 19),
            .serving(photo: photo(), source: 1, unconfirmed: nil, queued: 19),
            .caching(photo: photo(), source: 1, within: .seconds(20)),
            .cached(photo: photo(), source: 1, bytes: 1024),
            .cacheDropped(photo: photo(), source: 1, because: "no bytes", queued: 17),
        ]
        for event in events {
            #expect(event.level(chatter: .default) == .default, "\(event.line)")
        }
    }
}
