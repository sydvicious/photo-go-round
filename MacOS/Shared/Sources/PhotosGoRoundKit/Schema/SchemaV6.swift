import Foundation

/// The queue stops being first-in-first-out.
///
/// `position` was an autoincrementing key, so every card landed at the tail and
/// the queue was a strict FIFO. Both things that go into it now want otherwise:
///
/// - A card **returned after its fetch** is warm and ready, and putting it at the
///   back means waiting a whole traversal to be shown — its bytes paid for and
///   then left sitting.
/// - A card **freshly dealt** from a newly added source is invisible until the
///   queue has turned over once, which at fifty cards and ten seconds a picture
///   is eight minutes before that source is even looked at.
///
/// Putting either at the *head* was tried on 2026-08-23 and is worse: the order
/// pictures appear in becomes the order they were fetched in, so the fastest
/// source owns the front of the queue whatever its share of the library.
///
/// So placement is random, and `sort_key` is what makes it cheap — a card is
/// given a key drawn uniformly between the smallest and largest currently
/// queued, which is a uniform position among the cards present without moving
/// any of them. No gap-finding, no shifting, no explicit-position inserts; that
/// machinery existed for the head-and-tail experiments and is not coming back.
enum SchemaV6 {
    static let sql = """
        ALTER TABLE queue ADD COLUMN sort_key REAL NOT NULL DEFAULT 0;

        -- Existing cards keep the order they are in. `position` is monotonic, so
        -- using it as the initial key preserves the queue exactly across the
        -- migration rather than shuffling a live agent's queue underneath it.
        UPDATE queue SET sort_key = position;

        -- The walk reads in key order and takes the smallest, so this is the
        -- index it lives on. `position` is still the primary key and still the
        -- identity a delete names; it just no longer decides who is next.
        CREATE INDEX queue_order ON queue(sort_key, position);
        """
}
