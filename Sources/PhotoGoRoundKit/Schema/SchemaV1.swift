import Foundation

/// The initial schema.
///
/// Never edited once it has run anywhere. Changes arrive as migration 2.
enum SchemaV1 {
    static let sql = """
        -- ---------------------------------------------------------------
        -- source: a row, never a setting.
        --
        -- Mixed kinds coexist without special cases; the deck is the union of
        -- every enabled source. `kind` deliberately carries no CHECK
        -- constraint, because a new source kind is meant to be a new provider
        -- rather than a migration.
        -- ---------------------------------------------------------------
        CREATE TABLE source (
          id                  INTEGER PRIMARY KEY,
          kind                TEXT    NOT NULL,
          -- Path, PHAssetCollection id, PHAsset id, Google album id. For folder
          -- and file sources this is the only absolute path in the system:
          -- photos inside a folder are stored relative to it, so recovering a
          -- moved folder is one row to repair rather than fifty thousand.
          locator             TEXT    NOT NULL,
          -- Durable identity, stored from the first commit even though the Mac
          -- runs unsandboxed and ignores it today. One nullable column now
          -- removes a migration later, and it is the same column the
          -- rename-and-move tracking wants.
          bookmark            BLOB,
          -- The UUID written into the item's com.apple.metadata: xattr, which
          -- is what Spotlight can be asked for when the path stops resolving.
          stamp_uuid          TEXT,
          -- Disabling is not deleting: it drops the source's photos from the
          -- deck without discarding their deal history.
          enabled             INTEGER NOT NULL DEFAULT 1,
          recursive           INTEGER,
          -- A source that loses everything at once has become unavailable; it
          -- has not had its contents deleted. Unmounted volumes, revoked Photos
          -- authorization, and library switches all land here.
          available           INTEGER NOT NULL DEFAULT 1,
          unavailable_reason  TEXT,
          unavailable_at      INTEGER,
          added_at            INTEGER NOT NULL,
          scanned_at          INTEGER
        );

        -- ---------------------------------------------------------------
        -- photo: rows are cheap and complete; bytes are expensive and windowed.
        --
        -- Every photo in every source gets a row, however many that is. The
        -- cache holds a bounded window of actual files. Conflating the two
        -- would cap the shuffle at the cache size.
        -- ---------------------------------------------------------------
        CREATE TABLE photo (
          id              INTEGER PRIMARY KEY,
          source_id       INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
          -- PHAsset localIdentifier, Google media item id, or — for folder
          -- sources — the path RELATIVE to source.locator.
          external_id     TEXT    NOT NULL,
          -- 'image' in v1. 'video' is expressible and never selected, so
          -- turning video on later is a change to a predicate rather than a
          -- rescan of every source the user has ever added.
          media_type      TEXT    NOT NULL DEFAULT 'image'
                                  CHECK (media_type IN ('image', 'video')),
          -- Denormalised from source.enabled so the deal can be served from one
          -- index without a join. Maintained in the same transaction that
          -- enables or disables a source.
          source_enabled  INTEGER NOT NULL DEFAULT 1,
          -- Soft delete. The row survives so an unmounted volume is not ten
          -- thousand deletions, so rename tracking has something to match
          -- against, and so times_shown stays honest across an absence.
          available       INTEGER NOT NULL DEFAULT 1,
          -- Whether the bytes can go away, which is a property of where the
          -- file lives rather than of which provider found it. Internal boot
          -- volume: referenced in place, no copy, no cache budget. Anything
          -- removable, network, or ubiquitous: materialized.
          storage         TEXT    NOT NULL DEFAULT 'materialized'
                                  CHECK (storage IN ('referenced', 'materialized')),
          -- Absolute for referenced photos; relative to the cache root for
          -- materialized ones. NULL when not resident.
          cache_path      TEXT,
          byte_size       INTEGER,
          materialized_at INTEGER,
          -- Purely a statistic, for the deck inspector and `pgr deck stats`.
          -- Nothing orders by it.
          times_shown     INTEGER NOT NULL DEFAULT 0,
          -- Global deal ordinal. NULL means never dealt, which makes a newly
          -- added photo eligible at once without being placed anywhere special.
          last_dealt_seq  INTEGER,
          -- Random, re-rolled on every deal.
          shuffle_key     REAL    NOT NULL,
          last_shown_at   INTEGER,
          added_at        INTEGER NOT NULL,
          -- Permits the same photo reaching us from two sources to be two rows
          -- and to be dealt twice. Deduplication is out of scope for v1, and
          -- this constraint declines to solve identity rather than foreclosing
          -- it: a nullable content_hash column later is one ALTER TABLE.
          UNIQUE (source_id, external_id)
        );

        -- The deal orders by shuffle_key and takes a LIMIT, so the index leads
        -- with the equality columns and ends at shuffle_key. That lets SQLite
        -- walk in shuffle order and apply the repeat window as a residual,
        -- stopping as soon as it has enough — O(cards wanted) rather than a
        -- sort of half the library on every deal.
        CREATE INDEX photo_deck ON photo(source_enabled, available, media_type, shuffle_key);

        -- The complement, for the case the first index is bad at: at repeat
        -- window fraction 1.0 near the end of a pass, almost nothing is
        -- eligible and walking shuffle order would traverse the whole library.
        -- Both are cheap to maintain at these rates; the planner picks.
        CREATE INDEX photo_window ON photo(source_enabled, available, media_type, last_dealt_seq);

        CREATE INDEX photo_source ON photo(source_id);

        -- Materialization follows deck order, so oldest-materialized is also
        -- longest-since-dealt. This is what makes plain FIFO eviction correct.
        CREATE INDEX photo_materialized ON photo(materialized_at)
          WHERE materialized_at IS NOT NULL;

        -- ---------------------------------------------------------------
        -- consumer: every display is a separate virtual consumer.
        --
        -- `kind` carries no CHECK for the same reason source.kind does not — a
        -- new surface is a new consumer row, not a new code path in the deck.
        -- ---------------------------------------------------------------
        CREATE TABLE consumer (
          id         INTEGER PRIMARY KEY,
          kind       TEXT    NOT NULL,
          -- CGDisplayCreateUUIDFromDisplayID, which survives reboots and port
          -- changes, so the same monitor resumes its own rotation after a sleep
          -- or a cable swap. NULL for consumers that are not tied to a display,
          -- which makes (kind, display_id) the identity — so a surface with
          -- several simultaneous instances discriminates them in `kind`
          -- ('widget.small' and 'widget.large' are two consumers, not one).
          display_id TEXT,
          -- Per consumer, derived from its known interval: enough cards to
          -- cover roughly twenty minutes of playback. A wallpaper at one photo
          -- per half hour wants a small hand; a screensaver wants a large one.
          hand_size  INTEGER NOT NULL,
          -- Heartbeat. The reaper keys abandoned hands off this.
          seen_at    INTEGER NOT NULL,
          created_at INTEGER NOT NULL
        );

        CREATE UNIQUE INDEX consumer_identity ON consumer(kind, IFNULL(display_id, ''));

        -- ---------------------------------------------------------------
        -- hand: a contiguous block of cards reserved from the shared deck.
        --
        -- A card is dealt — ordinal assigned, window clock started — when it is
        -- PLAYED, not when it is reserved. Reservation only marks it spoken
        -- for, which is what lets an abandoned hand's unplayed cards return to
        -- the deck instead of silently thinning the library over weeks.
        -- ---------------------------------------------------------------
        CREATE TABLE hand (
          consumer_id INTEGER NOT NULL REFERENCES consumer(id) ON DELETE CASCADE,
          photo_id    INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
          position    INTEGER NOT NULL,
          reserved_at INTEGER NOT NULL,
          played_at   INTEGER,
          PRIMARY KEY (consumer_id, position)
        );

        -- Serves both the "is this card already spoken for" check in the
        -- reservation query and the "never evict a card in an outstanding
        -- hand" guard in the evictor.
        CREATE INDEX hand_photo ON hand(photo_id) WHERE played_at IS NULL;

        -- The prefetcher's work list: unplayed cards across all outstanding
        -- hands, in position order.
        CREATE INDEX hand_unplayed ON hand(consumer_id, position) WHERE played_at IS NULL;

        -- ---------------------------------------------------------------
        -- deck_state: the single monotonic deal ordinal, advanced by every card
        -- played anywhere in the system, plus the ordinal the current pass
        -- began at.
        --
        -- A photo is unused in the current pass when its last_dealt_seq is at
        -- or below pass_start_seq. When nothing is left unused the deck
        -- reshuffles: pass_start_seq moves up to the current ordinal and every
        -- photo becomes eligible again. One integer is the entire pass
        -- mechanism — there is no per-photo epoch column.
        -- ---------------------------------------------------------------
        CREATE TABLE deck_state (
          id             INTEGER PRIMARY KEY CHECK (id = 1),
          deal_seq       INTEGER NOT NULL DEFAULT 0,
          pass_start_seq INTEGER NOT NULL DEFAULT 0
        );

        INSERT INTO deck_state (id, deal_seq, pass_start_seq) VALUES (1, 0, 0);

        -- ---------------------------------------------------------------
        -- deck_event: relaxations and short hands, surfaced rather than
        -- swallowed, so `pgr deck stats` and eventually the settings UI can say
        -- that the repeat window is larger than the library can support.
        -- Trimmed to a bounded tail; nothing depends on old rows.
        -- ---------------------------------------------------------------
        CREATE TABLE deck_event (
          id     INTEGER PRIMARY KEY,
          at     INTEGER NOT NULL,
          kind   TEXT    NOT NULL,
          detail TEXT
        );

        CREATE INDEX deck_event_at ON deck_event(at);
        """
}
