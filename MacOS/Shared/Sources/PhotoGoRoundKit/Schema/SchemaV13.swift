import Foundation

/// A row for every resized copy the cache holds.
///
/// **The resize cache comes back.** It was removed on 2026-09-06 (`PLAN.md`,
/// *The resize cache is removed*) and brought back on 2026-09-16, once the agent
/// resized one picture at a time and a stalled HEIC decoder could hold that one
/// resize for minutes. `Agent Performance Overhaul.md`, Phase 2b.
///
/// **A row per copy, not a folder walk.** Syd: "rows in the database. writing one
/// row should not lock for very long, and saves the big directory walk at
/// launch." The row is how full the cache is, which copy is oldest, and what a
/// request for a photograph at a box is answered with.
///
/// - `box_width` × `box_height` is the box **asked for**, which is the key; the
///   `pixel_` pair is what was produced, for `X-PGR-Pixels`.
/// - `created_at` is when the copy was made. Eviction takes the oldest file
///   first, copies and originals alike.
/// - The row goes with its photograph's; the file is deleted by whoever deletes
///   the photograph, from `file`, read before the row goes.
enum SchemaV13 {
    static let sql = """
        CREATE TABLE resized (
          id           INTEGER PRIMARY KEY,
          photo_id     INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
          box_width    INTEGER NOT NULL,
          box_height   INTEGER NOT NULL,
          format       TEXT    NOT NULL,
          pixel_width  INTEGER NOT NULL,
          pixel_height INTEGER NOT NULL,
          byte_size    INTEGER NOT NULL,
          file         TEXT    NOT NULL,
          created_at   INTEGER NOT NULL,
          UNIQUE (photo_id, box_width, box_height, format)
        );
        CREATE INDEX resized_created ON resized(created_at, id);
        """
}
