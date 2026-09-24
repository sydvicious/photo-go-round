import Foundation

/// A served card stays on the queue, marked taken, until its deal is written.
///
/// **The deal moves off the client's path.** Until 2026-09-24 serving took the
/// writer twice before a picture could go out: the `DELETE` that popped the card
/// and the `UPDATE`s that dealt it. At boot, with the refresh and the cache walk
/// on the same disk, those two waits were 0.9 s and 2.6 s of a 10.7 s first
/// picture. Syd chose to keep the pop before the response — it is what settles
/// two consumers choosing the same card — and to write the deal off its path.
/// `Plans/Startup Performance.md`.
///
/// **Why the row stays.** The deck's candidate query excludes a photograph on
/// the queue or dealt within the window. A card popped and not yet dealt is
/// neither, so the filler could deal it straight back in. Marking it taken keeps
/// it on the queue — and out of the filler's reach — until the one transaction
/// that deletes the row and records the deal.
///
/// `taken_at` is null for a card waiting its turn. Everything that asks what is
/// waiting — the head, the depth, the fetcher's walk — reads only those.
enum SchemaV14 {
    static let sql = """
        ALTER TABLE queue ADD COLUMN taken_at INTEGER;
        """
}
