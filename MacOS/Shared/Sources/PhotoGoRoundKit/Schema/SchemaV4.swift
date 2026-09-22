import Foundation

/// The cache stops being recorded in the database.
///
/// Three changes that only make sense together. **Durable identities** arrive on
/// `photo` and `source`, because the cache's filenames carry them and a row id
/// would be a silent corruption: the database is disposable, a rebuilt one
/// renumbers from 1, and a surviving cache would then be served under the wrong
/// names. **`cache_path` and `materialized_at` go**, because the service's
/// in-memory index is rebuilt from the filesystem at every launch and a second
/// record of the same thing could only disagree with it. And the index that
/// ordered eviction goes with them.
///
/// `byte_size` stays. It is scan metadata about the original rather than about
/// our copy of it.
enum SchemaV4 {
    static let sql = """
        -- Durable identity, and the only one that ever leaves the database.
        -- Nullable here and filled below, because SQLite cannot add a column
        -- that is NOT NULL UNIQUE in one statement; the index is what enforces
        -- it from here on.
        ALTER TABLE photo ADD COLUMN uuid TEXT;
        ALTER TABLE source ADD COLUMN uuid TEXT;

        -- Existing rows get one each. `randomblob` rather than a Swift loop so
        -- a library of fifty thousand photographs is one statement.
        UPDATE photo SET uuid = lower(
            substr(hex(randomblob(4)), 1, 8) || '-' ||
            substr(hex(randomblob(2)), 1, 4) || '-4' ||
            substr(hex(randomblob(2)), 2, 3) || '-' ||
            substr('89ab', abs(random()) % 4 + 1, 1) ||
            substr(hex(randomblob(2)), 2, 3) || '-' ||
            substr(hex(randomblob(6)), 1, 12)
        ) WHERE uuid IS NULL;

        UPDATE source SET uuid = lower(
            substr(hex(randomblob(4)), 1, 8) || '-' ||
            substr(hex(randomblob(2)), 1, 4) || '-4' ||
            substr(hex(randomblob(2)), 2, 3) || '-' ||
            substr('89ab', abs(random()) % 4 + 1, 1) ||
            substr(hex(randomblob(2)), 2, 3) || '-' ||
            substr(hex(randomblob(6)), 1, 12)
        ) WHERE uuid IS NULL;

        CREATE UNIQUE INDEX photo_uuid ON photo(uuid);
        CREATE UNIQUE INDEX source_uuid ON source(uuid);

        -- The cache is no longer described here. Its index lives in the
        -- service's memory, rebuilt from the filesystem at launch, so nothing in
        -- the database can go stale against what is actually on disk.
        DROP INDEX photo_materialized;
        ALTER TABLE photo DROP COLUMN cache_path;
        ALTER TABLE photo DROP COLUMN materialized_at;
        """
}
