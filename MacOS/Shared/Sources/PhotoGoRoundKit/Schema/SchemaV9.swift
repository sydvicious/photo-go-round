import Foundation

/// One photograph, one row, however many sources contain it.
///
/// `SchemaV1` declined this on purpose, and said so:
///
/// > Permits the same photo reaching us from two sources to be two rows and to
/// > be dealt twice. Deduplication is out of scope for v1, and this constraint
/// > declines to solve identity rather than foreclosing it: a nullable
/// > `content_hash` column later is one ALTER TABLE.
///
/// **The content hash it was reserving room for is not needed.** Identity is
/// already in hand for every kind we have:
///
/// - A Photos asset in twelve collections has one `PHAsset.localIdentifier`,
///   and that is what `external_id` already holds. Exact, free, no bytes read.
/// - A file reached through two overlapping folder sources — `~/Pictures`
///   walked recursively and `~/Pictures/2024` added beside it — is one
///   absolute path, which is `source.locator` joined to `external_id`.
///
/// A hash would only buy genuinely distinct copies of identical bytes in two
/// folders neither of which contains the other. That is rare, and showing it
/// twice is arguably not even wrong, since the person did add both folders.
///
/// **Why a column rather than an expression index.** SQLite cannot index across
/// a join, and the rule needs `source.kind` and `source.locator`. Denormalising
/// has precedent in this very table: `source_enabled` is carried on `photo` for
/// the same reason, so the deal can be served without one.
///
/// **What the de-duplicating DELETE costs.** A row it removes may be resident,
/// and since `SchemaV4` the bytes live on disk under the row's `uuid` rather
/// than in this table. Deleting here bypasses `PhotoPool.remove`, which is what
/// normally hands the caller the orphaned uuids to unlink, so the file is left
/// for the cache's own reconciliation to find. The row kept is chosen to make
/// that as rare as it can be: resident first, then most delivered, then most
/// shown, then oldest.
///
/// **The column is nullable and the index is not partial.** SQLite permits any
/// number of NULLs in a unique index, so a row that somehow reaches this table
/// without an identity is not rejected — it is simply not de-duplicated. That
/// is the failure this would rather have than a scan that cannot insert.
enum SchemaV9 {
    static let sql = """
        ALTER TABLE photo ADD COLUMN identity TEXT;

        -- A file source's locator *is* the photo, which is why it ignores
        -- external_id: see `FileAccess.withPhotoURL`. A folder's locator
        -- already carries its trailing slash, applied in `SourceSpec.init`.
        UPDATE photo SET identity = (
            SELECT CASE source.kind
                     WHEN 'file'   THEN source.locator
                     WHEN 'folder' THEN source.locator || photo.external_id
                     ELSE photo.external_id
                   END
              FROM source WHERE source.id = photo.source_id
        );

        DELETE FROM photo
         WHERE identity IS NOT NULL
           AND id NOT IN (
               SELECT id FROM (
                   SELECT id, ROW_NUMBER() OVER (
                       PARTITION BY identity
                       ORDER BY cached_at IS NULL, times_delivered DESC,
                                times_shown DESC, id
                   ) AS rank
                     FROM photo
                    WHERE identity IS NOT NULL
               ) WHERE rank = 1
           );

        CREATE UNIQUE INDEX photo_identity ON photo (identity);
        """
}
