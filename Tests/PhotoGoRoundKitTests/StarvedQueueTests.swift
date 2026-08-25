import Foundation
import Testing

@testable import PhotoGoRoundKit

/// The queue going empty and staying empty while the pool is full of
/// photographs.
///
/// Observed live on 2026-08-25 after seven network folder sources totalling
/// ~10,000 photographs were added at once: `SERVE: nothing to show — out of
/// cards, walked 0` every three seconds, with no `DEAL:` and no `CACHE:` line
/// in twelve minutes. `walked 0` means the queue was empty, not that the walk
/// found nothing servable.
///
/// **The invariant these assert is the one sentence: a pool with photographs in
/// it must always be able to refill an empty queue.** Nothing about the deck's
/// pacing may reach a state that only *serving* can leave, because serving is
/// exactly what an empty queue cannot do.
@Suite("A starved queue")
struct StarvedQueueTests {

    // MARK: - The deck refusing to deal into an empty queue

    /// **When the deck has nothing to offer, answering nothing is correct — and
    /// something still has to ask again.**
    ///
    /// `nextCandidate` can legitimately decline: everything dealable is inside
    /// the repeat window, or queued, or claimed. The decision on 2026-08-25 was
    /// that this is a `204 no photos` rather than a reason to break the window,
    /// because breaking it would make the photograph just served eligible again
    /// at once and record a reshuffle for every picture.
    ///
    /// **What must not happen is the system going quiet afterwards.** Dealing is
    /// paced by pictures served, so a decline that stopped there would leave the
    /// one event that restarts dealing as the one event that cannot occur. The
    /// endpoint therefore rings the filler on the empty answer — asserted in
    /// `InFlightStarvationTests.emptyAnswerRestartsTheFiller` — and the
    /// heartbeat's `seedIfEmpty` remains the backstop.
    ///
    /// This test pins the half that lives in the deck: declining is a *decision*
    /// and never an error, so it costs nothing and can be asked again
    /// immediately.
    @Test("Declining to deal is free, repeatable, and changes nothing")
    func decliningToDealIsAPlainAnswer() throws {
        let (library, ids) = try TestLibrary.withPhotos(1_000)
        try library.setDealSeq(5_000)
        for id in ids { try library.setLastDealt(id, seq: 5_000) }

        let before = try library.deck.state()
        // Asked twice, because a decline that quietly advanced the pass or
        // recorded an event would make the second ask a different question.
        #expect(try library.deck.nextCandidate(settings: .default) == nil)
        #expect(try library.deck.nextCandidate(settings: .default) == nil)
        let after = try library.deck.state()

        #expect(before.dealSeq == after.dealSeq)
        #expect(before.passStartSeq == after.passStartSeq)
        // And nothing was claimed on the way out: a decline that left claims
        // behind would sideline photographs for the claim timeout.
        #expect(
            try library.database.scalarInt(
                "SELECT COUNT(*) FROM photo WHERE claimed_at IS NOT NULL;") == 0
        )
    }

    // MARK: - Deciding under a write lock

    /// **A write lock is taken before there is anything to write.**
    ///
    /// `nextCandidate` opens `transaction(.immediate)` and then does all of its
    /// deciding inside it — the pool count, the eligibility counts, the pass
    /// arithmetic, the candidate select. Only the very last statement, the
    /// claim, is a write. So every decision a deal makes is serialised against
    /// whatever else is writing, and during a long refresh that is a queue that
    /// cannot be topped up while thousands of rows are being inserted.
    ///
    /// The rule this asserts: hold the write lock only once the data to write is
    /// in hand.
    @Test("Dealing does not take the write lock while it is still deciding")
    func dealingDoesNotHoldTheWriteLockWhileDeciding() throws {
        let folder = TemporaryFolder(name: "pgr-deadlock")
        let library = try TestLibrary.onDisk(at: folder.url)
        let source = try library.addSource()
        try library.addPhotos(50, to: source)

        // A second connection standing in for the refresh: it holds the single
        // writer while it inserts, exactly as a scan of a network folder does
        // for minutes at a time.
        let writer = try Database(
            path: TestLibrary.path(in: folder.url), busyTimeout: .milliseconds(50))
        try writer.execute("BEGIN IMMEDIATE;")
        defer { try? writer.execute("ROLLBACK;") }

        // The dealer wants to choose a card. Choosing is entirely reading; only
        // the claim that follows needs the writer.
        let reader = try Database(
            path: TestLibrary.path(in: folder.url), busyTimeout: .milliseconds(50))
        let chosen = try Deck(database: reader).chooseCandidate(settings: .default)
        #expect(
            chosen != nil,
            "choosing a card was blocked by an unrelated writer, so a refresh starves the queue"
        )

        // The claim that follows *is* a write and may legitimately wait for the
        // writer — that is the rule, not a violation of it. What matters is that
        // every count, every piece of pass arithmetic, and the select all
        // happened without it.
    }

    // MARK: - The one case where photographs really cannot be served

    /// **Every source offline with nothing cached is a real "nothing to show",
    /// and it is still not this one.**
    ///
    /// A source being unreachable says nothing about the pool: the rows are
    /// still there, and dealing is pure database work that never touches a
    /// volume. So the queue still fills, and the walk still has cards to walk —
    /// it just cannot find bytes for any of them. That surfaces as `walked N`
    /// with a skip line per card, never as `walked 0`.
    ///
    /// Which is what makes `walked 0` diagnostic: it means the queue was empty,
    /// so the failure was in *dealing*, not in serving. This test exists to keep
    /// the two apart, so a future change cannot quietly turn the honest case
    /// into the broken-looking one.
    @Test("Offline sources still deal — an unreachable volume empties the cache, not the queue")
    func offlineSourcesStillFillTheQueue() throws {
        let library = try TestLibrary()
        let source = try library.addSource(locator: "/Volumes/gone/")
        try library.addPhotos(100, to: source)

        // The source is unreachable, which is a fact about the volume and not
        // about the pool. Enabled stays true: offline is not disabled.
        try library.database.run(
            """
            UPDATE source
               SET available = 0, unavailable_reason = 'the volume is not mounted'
             WHERE id = :id;
            """,
            ["id": .int(source)]
        )

        // Dealing is a row read and a row write. It does not care.
        var dealt = 0
        while dealt < 20, let card = try library.deck.nextCandidate(settings: .default) {
            try library.enqueue(card.id, sourceID: source)
            try library.deck.releaseClaim(photoID: card.id)
            dealt += 1
        }

        #expect(
            dealt == 20,
            "an offline source stopped the deck from dealing; offline is a serving problem"
        )
        #expect(try PhotoQueue(database: library.database, nominalSize: 20).size() == 20)
        // So a walk has cards to walk. It will skip every one of them for want
        // of bytes — `walked 20`, not `walked 0`.
    }
}
