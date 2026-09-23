import Foundation

/// Placement is random again — by rank, not by key.
///
/// `SchemaV8` made the queue a FIFO because only one thing arrived and the tail
/// was the only end there was. That is still true, and the tail is still the
/// wrong place for it: a card dealt from a newly added source waits a whole
/// traversal before anybody sees it — about three and a half minutes at twenty
/// cards and ten seconds a picture — and Syd's requirement on 2026-09-05 is that
/// a new source shows results in seconds or a few minutes. A shorter queue would
/// shorten the traversal, and was declined: a deep queue is what keeps pictures
/// coming when the sources are hostile.
///
/// So a new card lands at a uniformly random place among the cards present —
/// anywhere from second to last, never at the head, so the card about to be
/// shown is never displaced and every new card has at least one picture of
/// fetch lead. `SchemaV6` did this with a `REAL` key drawn between neighbours,
/// which shrank toward a tie and needed respacing to stay honest. **An integer
/// rank shifted on insert has no such failure**: the queue is twenty rows, so
/// bumping the ranks at and above the chosen slot is one trivial `UPDATE`, and
/// the order is exact for ever. `position` stays the primary key and the
/// identity a delete names; it just no longer decides who is next.
enum SchemaV10 {
    static let sql = """
        ALTER TABLE queue ADD COLUMN rank INTEGER NOT NULL DEFAULT 0;

        -- Existing cards keep the order they are in. `position` is monotonic, so
        -- using it as the initial rank preserves a live agent's queue exactly
        -- across the migration rather than shuffling it underneath the agent.
        UPDATE queue SET rank = position;

        -- Serving reads in rank order and takes the smallest; the fetcher walks
        -- it the same way. This is the index both live on.
        CREATE INDEX queue_rank ON queue(rank);
        """
}
