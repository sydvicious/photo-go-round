import Foundation

/// Blacklisting a photograph that will not render.
///
/// A file that is present and decodes to nothing is a different failure from one
/// that has gone: removing it from the pool does not work, because the file is
/// still on disk and the next refresh finds it and adds it back. It would cycle
/// for ever, costing a card each time round.
///
/// So the count lives on the row and survives a rescan. Three attempts rather
/// than one, because a decode can fail from memory pressure or from a file caught
/// mid-copy, and neither says anything permanent about the photograph.
enum SchemaV3 {
    static let sql = """
        -- How many times rendering this photo has failed. At the threshold it
        -- stops being offered, which is a predicate rather than a deletion — the
        -- row stays, so `pgr_ctl` can show what was blacklisted and clear it.
        ALTER TABLE photo ADD COLUMN render_failures INTEGER NOT NULL DEFAULT 0;
        """
}
