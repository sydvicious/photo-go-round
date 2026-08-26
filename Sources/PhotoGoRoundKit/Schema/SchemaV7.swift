import Foundation

/// Residency comes back into the database, because it is now the deck's pool.
///
/// `SchemaV4` took the cache out of the database on the grounds that the index
/// is rebuilt from the filesystem at launch and a second record could only
/// disagree with it. That was right while residency was a *hint* — something
/// serving discovered and acted on. It is wrong once the deck deals only what
/// can be shown right now, because a pool has to be something a `WHERE` clause
/// can say, and shipping the whole resident set into a temp table on every deal
/// is what `Deck.withServableSet` was already reduced to doing.
///
/// **The filesystem is still the truth and this is still a projection.** The
/// column records when a photograph's *original* landed, nothing about
/// renderings, and `PhotoCache.indexCache` reconciles it against the disk walk
/// at every launch. A disagreement is resolved in the disk's favour, always.
///
/// `NULL` means *not held*, which is what every existing row gets: an upgraded
/// database looks empty until the first launch reconciliation fills it in, and
/// that walk already happens.
enum SchemaV7 {
    static let sql = """
        ALTER TABLE photo ADD COLUMN cached_at INTEGER;

        -- The deck's pool predicate leads with the two equality columns it
        -- already filters on and ends at the one this migration adds, so the
        -- servable set is an index range rather than a scan.
        CREATE INDEX photo_resident ON photo(source_enabled, media_type, cached_at);
        """
}
