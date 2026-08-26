import Foundation

/// The queue is a queue again.
///
/// `SchemaV6` made placement random, because two things arrived in the queue
/// and wanted opposite ends of a FIFO: a card freshly dealt, and a card
/// returning from a completed fetch. Putting either at the head made the order
/// pictures appeared in the order they were *fetched* in, so the fastest source
/// owned the front; putting either at the tail cost a full traversal.
///
/// **Only one thing arrives now.** A completed fetch does not put anything on
/// the deck — it makes a photograph *eligible*, and the deck picks it up on its
/// own terms. So the tail is the only end there is, and `position` deciding the
/// order is an honest description rather than the silent reversion that
/// `respaceIfCollapsing` existed to prevent.
///
/// The column is dropped rather than left unused. It costs a few bytes a row
/// and would not grow, but it is dead code, and dead code is read by whoever
/// comes next as something that must mean something. A later design that wants
/// a placement key can add one on the evidence that made it want one.
enum SchemaV8 {
    static let sql = """
        DROP INDEX queue_order;
        ALTER TABLE queue DROP COLUMN sort_key;
        """
}
