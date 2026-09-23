import Foundation

/// Counting what actually reached a client.
///
/// `times_shown` already existed and is **not** this number. It counts a
/// photograph being *chosen* — incremented inside `Deck.markShown` at the moment
/// serving picks a card and hands it back, before the endpoint has rendered
/// anything. A render that fails increments it and shows nobody a picture; the
/// endpoint then moves to the next card, so one request can raise it more than
/// once. It is the deck's own bookkeeping, and the shuffle key and repeat window
/// are re-rolled in the same statement, which is why it has to happen there.
///
/// `times_delivered` is the other number: bytes left the process with a 200 on
/// them. Where the two disagree is exactly the set of photographs the deck
/// believes it is showing and the user has never seen — a file that will not
/// decode, a rendering that failed, a source that went away between selection
/// and read. Nothing else in the system can currently tell you that.
enum SchemaV5 {
    static let sql = """
        -- Not backfilled, and cannot be: nothing recorded it until now, and a
        -- copy of `times_shown` would assert something untrue about every row
        -- that ever failed to render. Zero means "not counted yet" for existing
        -- rows and "never delivered" for new ones, and the two are only
        -- distinguishable by age, which is the honest state of the fact.
        ALTER TABLE photo ADD COLUMN times_delivered INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE photo ADD COLUMN last_delivered_at INTEGER;
        """
}
