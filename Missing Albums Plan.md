# Summary

A Photos album that stops resolving keeps serving what the cache holds, stops costing cards, and is shown in the settings panel by name with Remove and Reconnect — instead of being deleted one photograph at a time and appearing as "040". Subordinate to `PLAN.md` and to `Apple Photos Plan.md`.

# Rationale

A Photos library rebuild on 2026-09-07 renumbered two albums. The agent could not tell that from a deletion: the provider answers *absent* for any identifier that fails against a readable library, so every cached photograph from those albums was deleted at the moment it would have been shown, and every uncached one was dealt, fetched, failed, and deleted. The panel showed the two albums as "040, 040" because nothing stores an album's name, and the picker could not remove them because it lists only what the library holds now. The person had the information nowhere and the fix nowhere. This plan puts both in the client and makes the agent hold still until they act.

# Phases

- **Phase 1 — complete, 2026-09-07. The provider tells the truth.** Existence asks whether the album resolves before it asks whether the photograph does. An album that is not there answers *unknown*, and serving and fetching already do the right thing with that.
  - `existence(of:in:)` resolves the collection first; unresolved is `.unknown("the album is not in this Photos library")`.
  - Tests against `FakePhotoLibrary` for all four answers, and `MissingAlbumTests` replaying the rebuild through the cache.
  - Run it: a cached photograph from a missing album is served, marked unconfirmed, and its row stays.
- **Phase 2 — complete, 2026-09-07. An unavailable source deals only what it holds.** The deck's population excludes photographs whose source is unavailable and whose bytes are not here, for every kind.
  - The pool predicate gains `source available OR cached_at IS NOT NULL`, by a join to `source`; no migration.
  - Tests in `DeckPoolTests`: held photographs of an unavailable source are dealt, unheld ones are not, and the pool count agrees. Three tests that asserted the old rule were rewritten to the new one.
  - Run it: the "no asset" fetch churn from a missing album stops.
- **Phase 3 — complete, 2026-09-07. The name is stored beside the identifier.** Title, collection kind, and folder path are captured from the catalog at add time and written to the preference entry and the source row.
  - Migration 11: `title`, `collection_kind`, `folders` on `source`; `folders` is a JSON array.
  - Three optional keys on the preference dictionary; absent for folders and files. One `SourceDescription` value in Swift.
  - A successful refresh renews the row, so a rename shows through; the preference keeps the add-time name as the seed.
  - The wire form's `title` falls back to the stored one, and `missing` says the album is the thing that is gone — from a fourth `SourceAvailability` case.
- **Phase 4 — The panel says so.** Under the chosen collections: "There are missing albums: *name*, *name*. Do you want to remove these references?" with a Remove button.
  - Missing albums leave the chosen-collections line and appear only here.
  - Remove deletes every listed source, as the picker's untick does today.
  - `SourcesModelTests` for the partition and the removal.
- **Phase 5 — Reconnect.** A missing album with exactly one catalog match by kind, title, and folders can be pointed at its new identifier without losing the source.
  - `POST /v2/sources/<uuid>/reconnect`; 409 when there is no match or more than one.
  - Row and preference are rewritten together under the editing lock, keeping the source's uuid.
  - A Reconnect button beside Remove, enabled when the list reports at least one reconnectable album.

# Design Decisions

- **Existence has four answers, and the album is asked before the photograph.** Unreadable library and unresolved album are *unknown*; a resolved album with a missing photograph is *absent*; otherwise *present*. Only *absent* deletes, which is the rule the plan already states, applied one level up.
- **`.gone` is still never returned.** A missing album and a switched library are indistinguishable, and this plan does not try. Both are *offline* and both keep serving from the cache.
- **No time limit, and nothing automatic.** A missing album stays listed until the person removes or reconnects it. The plan's rule that removal is a real delete makes it the person's act.
- **An unavailable source deals only what it holds, whatever its kind.** Residency was removed as a general gate on 2026-09-05 because it paced a new source; this gate applies only to sources already marked unavailable, so a healthy source is untouched. It also covers an unmounted drive, which today costs a card per photograph.
- **The identifier stays the locator; the name is stored beside it.** Decided 2026-09-07 over making the name the locator. Two same-named albums in one folder stay distinct, and the identity every other rule matches on does not change.
- **The agent captures the name; the client sends nothing new.** Adding already resolves the identifier against PhotoKit, and the catalog has the title, kind, and folders in hand at that moment.
- **The stored title follows a rename.** A refresh that resolves the album rewrites the title, so the stored name is what the album was last called, not what it was called when added. **Built 2026-09-07 as: the row follows, the preference does not.** The preference is the seed a rebuilt database projects until its first refresh, seconds later; the row is what the panel reads and what Reconnect will match on. One writer for the fact that changes, and no preference write from the agent's own loop.
- **`folders` is a JSON array, not a joined string.** Decided 2026-09-07 in the building. A Photos folder may be called anything, including something with a separator in it, and Reconnect's rule is exact or nothing.
- **The three facts travel as one optional value.** `SourceDescription` on the row model and the preference record; three columns in the table. A title without a kind is a row nothing in this project writes, and it reads as no description rather than half of one.
- **The source endpoint takes its providers as a parameter.** A test seam, nil in the agent. The production set asks PhotoKit, which has no grant under a test runner and says nothing, and "missing" is exactly the answer the v2 list has to be able to give.
- **Reconnect rewrites the row and the preference in the same locked step.** Reconcile matches rows to preferences by locator; rewriting the preference alone would make reconcile remove the row, its cached bytes, and its directory, and add a stranger.
- **A match is exact or it is not a match.** Kind, title, and folder path, and exactly one candidate. Smart albums match on kind alone, since their titles are Apple's and their kinds are unique.
- **`missing` is a flag on the wire, not a string to compare.** The app must not recognise an album problem by matching the reason text. **Behind it, since 2026-09-07, is a fourth `SourceAvailability` case**, `.missing`, chosen over a second associated value on `.offline`: everything that serves, fetches, or deals treats it as offline, and only the endpoint reads it. The flag is present for every Photos source in v2 and absent for a folder or a file, and it is computed only for a source the scan has already marked unavailable.

# Background

- The Photos provider's `existence` checks the asset and never the collection. Its `availability` and `enumerate` do check the collection and answer *offline* / *unavailable* with "the album is not in this Photos library"; the refresh keeps every row on that answer. The two questions disagree about the same album.
- Serving asks existence about the head card and deletes on *absent*. A failed fetch asks the same question and deletes on *absent*. On *unknown*, serving checks availability for *gone*, and otherwise serves the cached bytes marked unconfirmed; the fetch path keeps the row.
- Since 2026-09-05 the deck deals from every enabled photograph whether or not its source is reachable or its bytes are here. The plan's stated intent that an unavailable source is not asked to produce is not what the code does.
- A source is stored as kind, locator, recursive, enabled, in preferences and in the row. The wire form's `title` is asked of the provider live and is nil for an album that does not resolve; the app then falls back to the locator's last path component, which for `A1B2…/L0/040` is "040".
- The picker's rows come from the library catalog. A source whose album is not in the catalog has no row and cannot be unticked. The settings panel shows Photos sources only as a comma-separated line of names.
- Log excerpt from 2026-09-07, source 110 being the renumbered album: `SERVE: … dropped — gone from a source that is right there`, then `CACHE: … failed — no asset …` twice, pool falling from 17998 to 17995.

# Detailed discussions

## The bug, traced

`PhotosCollectionSourceProvider.existence(of:in:)` is two lines: if the library cannot be read, *unknown*; otherwise `assetExists(identifier) ? .present : .absent`. It was written to guard against deleting over a permission prompt, and it does. What it does not guard against is the library being perfectly readable while the album that the source names is not in it. After a rebuild every stored asset identifier fails, the library is readable, and the answer is *absent* for every one of them.

Two callers act on *absent*. `PhotoCache.serve` asks it about the head card just before handing it over and, on *absent*, logs "gone from a source that is right there" and calls `remove(card.id)`, which deletes the row and its cached bytes. `PhotoCache.handleFailedDownload` asks it after a fetch fails and does the same. So a missing album is deleted from the pool one card at a time, at the rate the deck deals its cards, each deletion preceded by a wasted fetch for the uncached ones. The pool count in the log falls by exactly the number of *absent* answers.

Meanwhile `availability(of:)` and `enumerate` both resolve the collection and say *offline* / *unavailable* for the same album, and `refresh` on that answer marks the source unavailable and keeps every row, precisely so that a library switch does not delete a library. The two questions were written at different times with different failure modes in mind, and they disagree.

## The four answers, and who acts on each

| Library | Album | Photograph | Answer | Serve | Fetch failure |
| --- | --- | --- | --- | --- | --- |
| unreadable | — | — | unknown (authorization) | serve cached, unconfirmed | keep row |
| readable | unresolved | — | unknown ("the album is not in this Photos library") | serve cached, unconfirmed | keep row |
| readable | resolves | unresolved | absent | delete row and bytes | delete row and bytes |
| readable | resolves | resolves | present | serve | keep row, retry when dealt |

The second line is the change. The first, third, and fourth are today's behaviour restated.

Serving's *unknown* branch already asks `availability` and deletes only on *gone*, which this provider never returns, so the cached bytes go out with `unconfirmed` set to the reason. Nothing in `serve` changes. `handleFailedDownload`'s *unknown* branch logs "could not be confirmed either way; keeping it" and does nothing. Nothing there changes either. The whole of Phase 1 is one guard in the provider and its tests.

The cost of resolving the collection on every existence check is one `fetchAssetCollections(withLocalIdentifiers:)` per served picture, the same call `availability` makes. Listing was measured as instant in the Apple Photos plan; this is a lookup by identifier, cheaper still.

A photograph removed from an album but still in the library answers *present* under this table and keeps being shown until the next refresh walks the album and drops it. That is today's behaviour and is not addressed here; membership is the refresh's job and the existence check is a deletion guard.

## Dealing only what is held

With *unknown* no longer deleting, an uncached photograph of a missing album would be dealt, fetched, fail, be kept, and be dealt again on its next turn through the pass. Phase 2 stops that at the deck.

The population predicate today is `p.source_enabled = 1 AND p.media_type = 'image'`, used by `poolSize`, `unusedCount`, `candidateCount`, `dealablePopulation`, and `candidateSQL`. It gains a conjunct: the source is available, or `p.cached_at IS NOT NULL`.

**Two ways to ask whether the source is available.** A join to `source` — `candidateSQL` already joins it, the others would start to — or a `source_available` column on `photo`, maintained by `markUnavailable` and `markAvailable` the way `setEnabled` maintains `source_enabled`. The join is proposed first: no migration, no second copy to keep in step, and `source` is a table of ten rows. If `DeckPoolTests` or `pgr_ctl deck stats` show the count queries slowing, the column is the fallback and has precedent.

**`cached_at` is the residency column**, kept in step with the byte store since Phase 1 of the deck and queue plan and reconciled after every store operation. It is the right thing to ask here because the question is "would serving find bytes", and the answer for a referenced photograph of an unmounted drive is no, which is the correct answer.

**Every kind, not only Photos.** An unmounted external drive's referenced photographs are dealt today, fail at serve because the file is not there, and are dropped from the queue after costing a card. Under this gate they are not dealt until the drive is back and the refresh marks the source available. That is what `PLAN.md` says should happen — "a source that is unavailable is not asked to produce" — and it is a strict improvement. The refresh that marks a source available again brings its photographs back into the pool with their deal history intact.

**The pool shrinks, and the repeat window with it.** The window is a fraction of the pool, so a large album going missing makes repeats come sooner for as long as it is missing. That is the same accepted consequence the plan records for a cleared cache, and it reverses on Reconnect or on the album's return.

**What this does not gate.** A source marked unavailable because the *library* is unreadable, with photographs in the cache: those are held, so they are dealt. That is the case `PLAN.md` line 1302 promises to keep showing, and it does.

## What is stored, and where

Three things, all optional, all absent for a file-backed source:

- `title` — `localizedTitle` as the catalog reported it; empty is stored as empty, not as absent.
- `collection_kind` — `LibraryCollectionKind`'s raw value: `userAlbum`, `favorites`, and so on.
- `folders` — the containing folders outermost first, joined with `/` for the row and stored as an array in the preference. Empty for a top-level album and for every smart album.

**In the preference**, as three more keys on the dictionary `SourceSpec.propertyList` writes. `init?(propertyList:)` reads them as optional, so a hand-written entry or one from before this plan still loads. They are not part of identity: `reconcile` matches on locator alone and does not compare them.

**In the row**, as three nullable columns added by migration 11. `SourceStore.add` takes them; `reconcile` passes them through from the spec when it creates a row. `SchemaSnapshot` and `MigratorTests` cover the migration.

**Captured by the agent at add time.** `SourceStore.add(_:to:)` already asks the provider whether each non-path locator resolves, before the lock is taken. The Photos provider answers that by fetching the collection; it can hand back the collection's title, kind, and folders in the same breath. The client keeps sending `{kind, path}` and nothing else, which means `pgr_ctl` and the app both get the stored name without a change on their side.

**Refreshed on a successful walk.** `applyRefresh` calls `markAvailable` when the enumeration resolved; it can write the current title in the same transaction. A person who renames an album in Photos sees the new name in the panel after the next refresh rather than the name from the day they added it. The kind and folders are refreshed at the same time, so a Reconnect match uses where the album is now.

**Why not have the client send the name.** The app's picker has the catalog and could send the title with the add. But `pgr_ctl --add-collection` does not have it, a hand-written `defaults write` does not have it, and the agent is the only process that can ask PhotoKit anyway. One writer.

## Naming a missing album on the wire

`SourceEndpoint.wire` asks the provider for the live title and sends nil when the album does not resolve. It should fall back to the stored title, so the app's `name` never reaches its last-path-component fallback for a Photos source that has one.

**A `missing` flag.** The app has `available` and `unavailableReason` and could tell "the album is not in this Photos library" from "Photos access is denied" by comparing the reason string. It must not: the reason is prose for a person. The wire form gains `missing: Bool?`, true when the source is unavailable and the provider's availability answer is the album-not-resolving one, absent for file-backed kinds. The provider distinguishes the two internally already; it needs to say which it is, which is a small change to `SourceAvailability.offline` — a second associated value, or a separate `missing` case that the serve path treats as `offline`. The separate case is cleaner to read and one more arm in two switches.

**`reconnectable: Bool?`** for Phase 5, true when the agent found exactly one match. Computed on list for missing Photos sources only, which is a catalog listing per poll; the panel polls on a timer measured in minutes, and listing is instant.

## The panel

The Apple Photos group box today is a comma-separated line of chosen collection names on the left and a photo count and Select Collections… on the right. Phase 4 adds, below the chosen line and only when there is something to say:

> There are missing albums: Kids 2019, Trip to Maine. Do you want to remove these references?  [Remove] [Reconnect]

**Missing albums leave the chosen line.** Otherwise a missing "Kids 2019" appears twice, once as chosen and once as missing, and the chosen line is meant to be an inventory of what is in play.

**Remove acts on all of them**, in one pass through `service.remove(uuid)` per source, the way `CollectionsModel.apply` removes unticked collections. A per-album row with its own buttons was considered and set aside: the case is two or three albums after a rebuild, not a list to manage, and a person who wants to keep one can reconnect it first. If that turns out wrong, rows are the next step and nothing here prevents them.

**Reconnect acts on the reconnectable ones** and leaves the rest listed. Phase 4 ships the line and Remove; Reconnect appears with Phase 5 and is disabled until then rather than hidden, so the panel's shape does not change between phases.

The panel's colour rule holds: the line reads in the secondary style with the orange the folder list uses for an unavailable source, and the words carry the meaning.

`app/mac/FEATURES.md` owns what the panel looks like and will need this added when it is next audited. Not edited here.

## Reconnect

**The match.** Among the catalog's collections, those whose `kind` equals the stored `collection_kind` and, for a user album, whose title and folder path equal the stored ones. Exactly one is a match. None, or two or more, is not, and the album stays missing with Reconnect disabled for it. For a smart album the title is not compared: Favorites is Favorites in every library and there is one.

**The write.** Under `SourceStore.editing`: update the row's `locator` to the new identifier, keeping its `uuid`, `enabled`, `added_at`, and stored name; then rewrite the preference entry's `locator` to the same value; then release the lock. Reconcile, running later, finds a row and a spec with matching locators and does nothing.

**Why the order and the lock matter.** Reconcile identifies a row by its locator. If the preference changed and the row did not, the next reconcile would find a spec with no row — add one, fresh uuid, fresh cache directory — and a row with no spec — remove it, cascading its photo rows and unlinking its cache directory. The album would be reconnected and its cache gone. Doing both in one locked step is the whole of the design.

**What Reconnect buys, honestly.** After a rebuild the asset identifiers changed too, so the next refresh of a reconnected source removes every old row and adds new ones, and the old cached bytes leave with their rows. The cache is refetched either way. What Reconnect keeps is the source itself — its uuid, its enabled state, its place in the list — and what it saves the person is finding the album again among three hundred in the picker. That is worth a button, and not more than a button.

**The endpoint.** `POST /v2/sources/<uuid>/reconnect`, no body. 200 with the source's wire form on success; 409 with `{error, matches: [titles]}` when the match is not exact; 400 for a source that is not missing or not a Photos kind. `pgr_ctl` gets no new command for it in this plan — the case is a panel case, and a command would need a man page entry and tests it does not yet earn. If `pgr_ctl sources` is to show the stored name, that is a one-line change to its listing and is covered by the existing output tests.

## Favorites, smart albums, and the rebuild

The renumbered albums on 2026-09-07 were user albums; Favorites came through. That fits: a smart album's identifier is derived from its subtype and survives a rebuild, a user album's is minted and does not. The match rule handles both without a special case, because a smart album's kind is its identity and a user album's is its name and place.

## The library switch, still

Switching the system library fails every album at once. Under this plan every Photos source becomes missing, every held photograph keeps serving, nothing is dealt that is not held, the panel lists every album by name, and Reconnect finds nothing because the other library's albums are different albums. Switching back marks every source available at the next refresh and everything returns. That is the behaviour `Apple Photos Plan.md` promised, now with the panel saying what is happening instead of the agent quietly deleting.

## What this plan does not do

- No automatic removal, on any signal or after any interval. Decided 2026-09-07.
- The name does not become the locator. Decided 2026-09-07; see Design Decisions.
- No change to the refresh's handling of an unresolved album: it still marks the source unavailable and keeps every row.
- No attempt to tell a deleted album from a switched library.
- No per-album rows in the panel.

## Verification

- **Phase 1.** `PhotosProviderTests` with `FakePhotoLibrary`: the four rows of the table above, and the reason string for an unresolved album. `ServeWalkTests`: a card from a missing album with bytes held is served with `unconfirmed` set and its row survives; the same card with no bytes is dropped from the queue after the wait and its row survives. `HostileProviderTests`: a fetch that fails for a missing album keeps the row.
- **Phase 2.** `DeckPoolTests`: a database with one available source and one unavailable, each with a held and an unheld photograph; the pool is three, the unheld photograph of the unavailable source is never dealt, and marking the source available brings it back. `pgr_ctl deck stats` on the live library shows the pool fall by the missing albums' uncached count and nothing else.
- **Phase 3.** `MigratorTests` and `SchemaSnapshot` for migration 11. `PhotosSourceEditingTests`: adding a collection stores its title, kind, and folders in the row and in the preference; a preference entry without them still loads; a refresh that resolves the album rewrites the title. `photogorounddTests`: the wire form carries the stored title when the live one is nil, and `missing` is true for an unresolved album and absent for a folder.
- **Phase 4.** `SourcesModelTests`: a missing Photos source is absent from the chosen list and present in the missing list; Remove calls the service once per missing source. The panel checked by eye against the running agent with an album renamed in Photos — the one reproduction that needs no rebuild.
- **Phase 5.** `PhotosSourceEditingTests`: reconnect with one match rewrites row and preference and keeps the uuid; with none or two it throws and changes nothing; a reconcile after a reconnect adds and removes nothing. `photogorounddTests` for the endpoint's three answers.
- **From nothing.** The reproduction that started this: rename a user album in Photos, watch the panel list it as missing with Reconnect enabled, reconnect it, and confirm the source keeps its uuid and the next refresh repopulates it.

## What running it found

**Phase 1, 2026-09-07.** The tests failed first exactly as the log had: the cache served nothing because it had deleted the held photograph, and the failed fetch took the row. The fix was one guard in the provider. The reason string was already spelled in two places and is now one constant. Serving and the fetch-failure path needed no change: both already treat *unknown* as "keep the row", and serving already marks the picture unconfirmed with the reason.

**The rebuild is replayed against the database, not the fake library.** `MissingAlbumTests` builds a Photos source on the fake, refreshes and fetches one card, then rewrites the source's locator and every asset identifier in the rows to values the library has never heard of. That is what a rebuild looks like from the agent's side — the library moved on and the rows describe a world that is gone — and it needed no second fake.

**Phase 2, 2026-09-07.** The join was taken over the denormalised column and cost nothing measurable; the whole suite runs in the same five seconds it did. `Deck.population` is the one `FROM` clause every population query shares, so the alias the predicate relies on is spelled once.

**Three tests asserted the old rule by name and were rewritten.** *Offline sources still deal — reachability is the fetch's problem, not the deck's* in `StarvedQueueTests` had made the point that `walked 0` was diagnostic because an offline source still filled the queue; it now asserts the held half deals and the cold half does not, and its comment says what `walked 0` means now. *An unreachable folder leaves every row untouched* in `SourceTests` now expects a pool of zero beside two untouched rows. *Clearing unavailable sources frees only what can never be fetched again* in `CacheTests` now expects the cleared photographs to leave the pool, since nothing of them is held.

**A restore assertion tripped over pass mechanics.** The new pool test first asserted that eight draws after the source returned would deal all eight photographs. They do not: the two cold ones are the only eligible cards until the pass ends, the pass then reshuffles, and eight draws over a reshuffled eight miss one. The assertion became "the next two deals are exactly the cold ones", which is the stronger claim anyway.

**A wall-clock bound in `ServeWaitTests` failed once under the full parallel run**, at 6.25 seconds against a 5 second limit, with the bytes landing at 300 ms. It passed three times alone and in the next full run. The limit is 15 seconds now and the fixture's wait is 30, so the assertion still distinguishes "noticed the bytes" from "waited the bound out". Syd's call, 2026-09-07.

**A second test in that suite is fragile under load and was left alone.** *A card whose fetch fails during the wait is passed over for the new head* failed once with two waiting events instead of one: the background fetcher fails the head and fetches the next card on a fixed 200 ms delay, and under load the request moved to the new head before its bytes had landed and waited a second time. Five passes alone and two more full runs. A timing assumption in the test, not in the gate.

**Phase 3, 2026-09-07.** Ten tests, 660 in all, and the Mac app builds against the changed model. Four departures from the text above, each recorded under Design Decisions: `folders` as JSON, one `SourceDescription` value, a `.missing` case, and a providers seam on the endpoint. The fifth is the one worth reading — the refresh renews the row and not the preference — because the plan's "updates the stored title" could have meant either.

**The description is captured where the album is already being asked about.** `SourceStore.add` asks the provider whether each non-path locator resolves before it takes the lock; the same loop now asks for the description and hands it into the write, so the client sends `{kind, path}` exactly as before and `pgr_ctl` and a hand-written `defaults write` get the same name without knowing to ask.

**The two albums that started this stay "040".** They were added before any name was stored, and the library cannot name them now, so nothing renews their rows. They will read as their identifiers until Phase 4 removes them or Phase 5 reconnects them. Every album added or refreshed from this build on carries its name.

**The v1 list is untouched.** Neither the title fallback nor `missing` reaches it; v1 carries no Photos sources at all.

## Other plan documents this touches

Amended 2026-09-07 for Phases 1 to 3:

- `Apple Photos Plan.md` — the decision that a collection which stops resolving is `.offline`, and the *existence* and *availability* subsections, the latter now naming `.missing`.
- `PLAN.md` — the *Sources* decisions on the moment-before-showing check and on the System Photo Library; the *Cache* decisions on dealing over everything and on every photo being dealt; the *What happens to a source that never comes back* discussion; the source-as-preference section, which gains the three optional keys.
- `Deck and Queue v2.md` — the readers of `cached_at`.

Still to amend, with Phases 4 and 5:

- `app/mac/FEATURES.md` — the Apple Photos group box's missing-albums line and its two buttons.

# References

- `PLAN.md` — *Sources* and *Cache* under Design Decisions; "Switching libraries is the failure mode to handle" and "A photo keeps being shown if its bytes are local" in the detailed discussions.
- `Apple Photos Plan.md` — Design Decisions on `.offline` never `.gone`; the `.gone` discussion at its end.
- `Deck and Queue v2.md` — residency in the database; `cached_at` as the residency column.
- Agent log, 2026-09-07 12:40, sources 110 and 111 — the excerpt in this conversation.
- `Sources/PhotoGoRoundKit/Photos/PhotosCollectionSourceProvider.swift` — `existence`, `availability`, `enumerate`.
- `Sources/PhotoGoRoundKit/Cache/PhotoCache.swift` — `serve`'s existence check; `handleFailedDownload`.
- `Sources/PhotoGoRoundKit/Deck/Deck.swift` — `availablePredicate`.
- `Sources/PhotoGoRoundKit/Sources/SourceStore.swift` — `reconcile(specs:)`, `markUnavailable`, `markAvailable`.
- `Sources/PhotoGoRoundAgentAPI/Model/SourceSpec.swift` — the preference dictionary.
- `Sources/photogoroundd/Service/SourceEndpoint.swift` — `Wire`, `wire(_:store:version:)`.
- `app/mac/Sources/SourcesSettingsView.swift`, `SourcesModel.swift`, `CollectionsModel.swift` — the panel and the picker.
