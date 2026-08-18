import Foundation

/// Claiming a photo at selection time.
///
/// Selecting a candidate and queuing it are separated by a fetch, so without a
/// claim two producers asking the same source can pick the same picture and both
/// download it. The queue refuses the duplicate, so the cost was never a
/// duplicated *showing* — but it was a duplicated download, and with four
/// concurrent fetches per source it was reachable rather than theoretical.
///
/// The claim is written in the same transaction as the selection, so the second
/// producer sees it and picks something else. It is nullable because a claim is
/// the exception rather than the state: almost every row has none.
enum SchemaV2 {
    static let sql = """
        -- When a producer took this photo to fetch its bytes. NULL means nobody
        -- is working on it, which is the case for all but a handful of rows at
        -- any moment.
        --
        -- Read with an expiry rather than trusted outright: a producer that dies
        -- between the claim and the queue cannot release it, and a claim that
        -- outlives any plausible fetch has to stop counting or the photo is
        -- sidelined for ever. Expiry is what makes that self-healing and is why
        -- there is no reaper.
        --
        -- No index. It is a residual filter on rows the source predicate has
        -- already narrowed, and an index on a column that is almost always NULL
        -- would cost every write to buy nothing.
        ALTER TABLE photo ADD COLUMN claimed_at INTEGER;
        """
}
