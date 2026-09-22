# Audit: the picture-serving agent (`photogoroundd` + PhotoGoRoundKit)

2026-08-24. Audited by Claude (Fable 5) against PLAN.md, `app/mac/FEATURES.md`, and
`Documentation/photogoroundd.md`, with the live agent (debug build, PID 12569,
started 5:22 PM) observed over OSLog and read-only HTTP. Method: full read of all
three documents and the agent/kit serving core, three parallel adversarial passes
(test coverage, serving pipeline, HTTP layer), every finding re-verified against
the code before inclusion. `swift test` was not run (the running agent shares
`.build`), and `/v1/next` was never requested — it pops the queue.

**TLDR:** The implementation matches the documented design remarkably closely —
the serve walk, deal pacing, random placement, cache index, and the five source
endpoints all do what PLAN.md says, and the recent queue rework is faithfully
reflected in code. Found: **one live misbehavior** (the doorbell self-ring PLAN
says was fixed is racy; the agent was re-scanning every ~19 seconds during a
copy), **three high-confidence bugs** (small-library pass logic, `--once` port
clobber, signal-handler lifetime), a handful of medium/low bugs, a **man page
drifted from the code in five places** (`queueSize` 250 vs 20 being the worst),
and real test-coverage holes — the daemon's queue-pacing core (`FillerBox`/
`Gauge`) has zero tests.

A note on logs: OSLog works fine — `log` is shadowed in the interactive zsh;
`/usr/bin/log show --predicate 'subsystem == "com.sydpolk.photogoround"'` reads
the whole run.

## What the live agent showed

Healthy overall: 4 sources, ~11,800 photos, all available; queue steady at 20;
~2.3 GB cached; serving the app a picture every dwell with clean
`DEAL:`/`SERVE:`/`CACHE:` narration.

**But: source 9 was being refreshed every ~19 seconds instead of every 300.**
68 `refreshed source 9` lines in 21 minutes, while that folder was being copied
into (its count grew 3261→3355 during the capture). Mechanism:
`Sources/photogoroundd/RunCommand.swift:366` announces `.sourcesChanged` when a
refresh found changes; the agent observes its own announcement; the
drop-pending-ring at `RunCommand.swift:254` runs microseconds after the post,
but `notify_register_dispatch` delivers the callback asynchronously on
`.global()` — so the flag is usually raised *after* the drop, and the next
2-second tick refreshes again. This is exactly the loop *The doorbell rings back
at you* records as settled; the fix works only when the drop wins the race,
which it mostly loses. Cheap per PLAN's own scan measurements, and self-limiting
once the copy ends — but it is the documented-fixed behavior, observably back.

## Bugs

**1. Small libraries: the pass machinery fires constantly and the repeat window
is nullified.** `Sources/PhotoGoRoundKit/Deck/Deck+Consumers.swift:135-153`
treats `eligible == 0` as end-of-pass, but the candidate predicate (`:322`)
also excludes *queued* and *claimed* photos — cards that are staged, not used
up. With pool ≲ queueSize + window (a 30-photo wallpaper folder at queueSize 20,
say), every top-up finds zero eligible, declares a new pass, writes a
"reshuffled" `deck_event`, and makes the just-served photo immediately
re-dealable — window gone, one fake pass event per picture, and
`unusedInCurrentPass` (which doesn't exclude queued) contradicts it in
`deck stats`. The current 11.8k library never hits this; PLAN explicitly calls
small libraries "the normal case for a folder of wallpapers." No test covers it
— `DeckTests` never enqueue and the small-library `QueueFiller` test uses a mock
dealer.

**2. `--once` (or any non-signal exit) leaves a stale `servicePort` — and
clobbers a running agent's.** The listener starts and publishes unconditionally
(`Sources/photogoroundd/RunCommand.swift:132-137`); withdrawal happens only in
the SIGTERM/SIGINT handler. `--once` breaks out of the loop and exits normally,
so the published port stays behind pointing at nothing — and if a long-running
agent in the same preference domain is up, the `--once` run *overwrites* its
published port on the way through. This is precisely the two-agents hazard
FEATURES.md documents as having bitten on 2026-08-24, reachable from a single
flag. The comment "this process only ever ends by signal" is false for `--once`.

**3. The signal-handler sources can be released early.**
`let shutdown = Self.withdrawPortOnTermination(...); _ = shutdown`
(`RunCommand.swift:144`) — ARC is free to release after last use, which is that
line. If the resumed `DispatchSourceSignal`s are disposed, they stop delivering
— and since the handler first sets `signal(n, SIG_IGN)`, an optimized build
could end up *ignoring* SIGTERM/SIGINT outright: unkillable except by SIGKILL,
port never withdrawn. Debug builds mask it (Ctrl-C evidently works today). The
code's own comment states the lifetime requirement; `withExtendedLifetime`
around the loop is the shape of the fix.

**4. `Accept` is ignored on rendering-cache hits.** The cache key is
`(photoUUID, size)` with no format
(`Sources/PhotoGoRoundKit/Cache/PhotoStore.swift:51`), and the hit path
(`Sources/photogoroundd/Service/PictureEndpoint.swift:250-270`) never consults
the negotiated format — whatever was rendered first at that size is served. A
JPEG-only client gets HEIC bytes on a hit, contradicting the man page's "the
format comes from `Accept`." Secondary: rendering the second format replaces the
index entry for the same key, stranding the first file on disk unindexed. The
test titled "Accept decides the format, and the cache keeps them apart" pins
only the miss path.

**5. A local failure during a fetch deletes the photograph.** One `catch` in
`Sources/PhotoGoRoundKit/Cache/PhotoCache.swift:309-324` covers `materialize`
(genuine missing-file) *and* `store.adopt` *and* the `byte_size` UPDATE;
`handleFailedDownload` then removes the row and bytes whenever the source stats
online. A cache root gone read-only, a failed move, or `SQLITE_BUSY` past
retries (the SQL case fires *after* a successful download) deletes photos from
the pool; the next refresh re-adds them as new rows with new UUIDs — deal
history lost, bytes re-fetched, in a loop while the condition persists.

**6. The deal gauge doesn't count fetches in flight *during* the download.**
`CacheQueue.Pending` tracks `waiting.count`, decremented the moment a lane takes
the item (`Sources/PhotoGoRoundKit/Cache/CacheQueue.swift:147`) — so through the
long phase, the card counts as neither queued nor pending, and `Gauge.isShort`
(`RunCommand.swift:642-648`) deals up to `downloadConcurrency` cold
replacements; the warm cards then return to a queue that already moved on. This
is a bounded version of the churn the "cards out for fetching still count as the
queue's" rule exists to remove. The intent is tested only with an injected
closure; the wiring isn't.

**Smaller, verified:**

- A crash mid-download leaks files in `cache/.staging` forever — the index walk
  (`PhotoStore.index`) skips the directory and never deletes there.
- A served file evicted between the size `stat` and the stream open produces a
  200 with `Content-Length: 0` that the client will parse as a picture. Narrow
  window — the pop removes the card's eviction protection at exactly the moment
  it streams.
- `POST /v1/sources` accepts a regular file as a `folder` kind (and vice versa)
  — only `fileExists`, never directory-ness, in
  `Sources/PhotoGoRoundKit/Sources/SourceRequest.swift:64` — and silently drops
  `recursive` on a `file` kind where PATCH refuses it with 400.
- A client that hangs up mid-header gets 431 rather than 400.
- A connection that sends nothing is held open forever (no read deadline).
  Loopback-only, so cosmetic.

## Documentation vs implementation

`Documentation/photogoroundd.md` has drifted in five places, all on the
PREFERENCES/behavior side of the 2026-08-24 rework:

- **`queueSize` default: doc says 250, code says 20**
  (`Sources/PhotoGoRoundKit/Host/Preferences.swift:221`, with the dated sweep
  rationale beside it). The most user-visible error — anyone reasoning from the
  table gets the wrong steady state.
- **`downloadConcurrency` "fetches in flight per source"** — it is now one
  global `CacheQueue` width; the code says so plainly (`CacheQueue.swift:33`).
  The stale "per source" comment also survives inside `Preferences.swift`
  itself.
- **`maintenanceIntervalSeconds` "how often to verify, sweep, and evict"** —
  maintenance only evicts now; verify and sweep were deleted with the in-memory
  index.
- **`queueRefreshIntervalSeconds` "how often to top the queue up"** — the timer
  now only *seeds an empty queue*; topping up rides serving.
- **EXIT STATUS: "a folder that does not exist" is listed as a fatal non-zero
  exit — not implemented.** `--add-folder` with a bad path is written to
  preferences and later marked unavailable; the agent runs on and exits 0. (The
  HTTP add path *does* refuse missing paths; the launch flag doesn't.)

Also: the 200-response description implies `X-PGR-Pixels` is always present, but
original-bytes responses (no `w`/`h`) omit it; and the man page doesn't mention
the `-d` short form of `--database`.

Drift outside the man page:

- **The agent's own `--help` text tells the user to "run `pgr_ctl serve` in
  another terminal"** (`Sources/photogoroundd/Options.swift:153`) — that verb no
  longer exists; the documented path is `curl`. A live instance of the
  usage-drift failure *Known shortcomings* item 10 predicts.
- **FEATURES.md describes `advanceIntervalSeconds` in the present tense** —
  "defaults to 0.5 and is parsed with a default and a clamp like every other
  key, so `pgr_ctl set` tunes it" — but the key exists nowhere in code. The
  app's `Shuffle` has a hardcoded 10-second dwell and no manual advance at all,
  and `pgr_ctl set` would refuse the key (not in `Preferences.allKeys`). The man
  page's "when that key exists" is the accurate one; FEATURES.md is ahead of the
  build.
- PLAN's *Talking to the subsystems we do control* section and the
  `Sources/PhotoGoRoundKit/Host/DarwinNotification.swift` header both still
  assert "the database is the transport… no HTTP server" as if current. (Noted
  only; the plan documents are the owner's.)

## Test coverage gaps

The suites are strong where they look — endpoints, serve walk, deck fairness,
queue randomness, source editing, clamping are all pinned at the right layer.
The holes cluster:

- **`RunCommand`/`FillerBox`/`Gauge`/`seedIfEmpty` have zero tests.** This is
  the daemon's queue-pacing core — the in-flight gauge, the seed-only-when-empty
  rule, the shared-filler guard — and it is where bugs 2, 3, and 6 above live.
  `QueueTopUpTests` tests the policy shape with hand-built closures; the
  daemon's actual closures are a parallel implementation the suite never
  touches. Given the project's own history (the stuck-queue and one-per-picture
  bugs), this is the highest-value gap.
- **"Documented means tested" violations:** the 30-second preference poll,
  `--add-folder` write-through at launch, `--once`'s one-pass-and-exit, the
  port publish wiring (`onReady → publishServicePort`), and withdraw-on-signal
  all have no test. Exit codes are never asserted anywhere.
- **Daemon-side response gaps:** `X-PGR-Source`/`X-PGR-Storage` are never
  asserted against the daemon (only client-side header parsing); the
  render-failure skip/retire loop in `PictureEndpoint` has no daemon test;
  503/500 paths, 431, and malformed request lines are unexercised.
- **Kit gaps:** consumer registry (`register`/`touch`/`forget`),
  `clear(.source)`/`.unavailableSources`/`costOfClearing` (destructive,
  user-facing via `pgr_ctl`), the critical-free-space eviction branch,
  EXIF-orientation rendering (no rotated fixture anywhere), and
  `PGR_DATABASE`/`PGR_PREFS_SUITE` effects.
- **Suspect tests:** `Tests/PhotoGoRoundKitTests/QueueTests.swift:82` ends in a
  literal tautology — `#expect(where_ != order.count - 1 || where_ ==
  order.count - 1)` asserts nothing; `ServeWalkTests` still narrates "a fetch
  does not put it back" above a mechanism that now does; `CacheTests` and
  `PhotoQueue`'s header sell the pre-rework FIFO/provider rationale;
  `OptionsTests`' frozen-environment check exempts `PGR_PREFS_SUITE` so it
  asserts nothing about it.

## Housekeeping (dead code)

- `PhotoStore.heldOriginals(ofSource:)` has zero callers — PLAN's *What this
  replaces* even lists it as deleted, but it is still there — and a stray
  `@discardableResult` at `PhotoStore.swift:285` got orphaned onto it instead of
  `removeSource`. `removeSource` also never prunes `sourceOfPhoto` entries
  (slow map growth in a long-lived agent).
- `RunCommand` has a triplicated "The queue maintainer, which always runs" doc
  comment, an orphaned QueueFiller-era comment attached to `describeSources`,
  and an unused `nominalSize` parameter on `makeFiller`.

## Checked and found sound

So it doesn't get re-audited: `--prod`/container/cache/prefs-domain resolution
and precedence exactly per the man page; SQL injection (everything binds);
queue-pop atomicity; `respaceIfCollapsing`; the random-placement key math
including empty/one-card cases; FK cascades; locator normalization (trailing
slash); the mass-disappearance guard; the all-or-none POST with 400/413/201/200
semantics; PATCH/DELETE rules; atomic rename in the store; and the walk budget's
pop-before-check ordering.

## Addressed later on 2026-08-24

Each fix landed behind a failing test written first, except where noted. Full
suite green afterwards: 425 tests across all four targets.

- **Bug 1 (small-library pass logic) — fixed.** `nextCandidate` now treats
  `eligible == 0` as three states: everything in play → deal nothing; a
  population the window can free → wait (serving advances the ordinal and the
  window opens on its own); only a population the window can never leave a
  candidate in (`dealablePopulation ≤ window + 1`, which is fraction 1.0 and
  the too-small library) reshuffles. Retired photographs are excluded from that
  population so a mostly-blacklisted library still reshuffles. The `window + 1`
  comes from the eligibility comparison (`seq - w - 1`): at most `w + 1`
  photographs can be window-blocked at once, so any larger population frees one
  per serve and waiting cannot deadlock. Three new tests in `DeckTests`
  ("The pass fires only when the window has no answer").
- **Bug 2 (`--once` port clobber) — fixed.** A one-pass run never starts the
  listener and never installs the withdraw-on-signal handlers, so the published
  `servicePort` — a running agent's included — is left untouched. An
  ownership-checked withdraw on the error unwind covers a serving run that dies
  by thrown error. Pinned by `AgentLifecycleTests`.
- **Bug 3 (signal-handler lifetime) — fixed.** The `DispatchSourceSignal`s are
  held by a `withExtendedLifetime` defer for the life of `run()`. A
  process-level test spawns the built agent, waits for the published port,
  sends SIGTERM, and asserts exit 0 with the port withdrawn — pinning the
  publish wiring and withdraw-on-signal (previously untested); the lifetime fix
  itself is optimizer-dependent and not observable from a debug test.
- **Bug 6 (gauge undercount) — fixed.** `CacheQueue.Pending` now counts
  waiting *plus* executing, so a photograph mid-download still counts as the
  queue's. Pinned by "A photograph being fetched still counts as pending".
- **Coverage: `FillerBox`/`Gauge`/`seedIfEmpty`** — new `FillerBoxTests` drive
  the daemon's actual pacing closures against a real database: seed fills only
  an empty queue, `servedOne` deals exactly the served card back, the gauge
  counts in-flight cards.
- **Man page corrected** (`Documentation/photogoroundd.md`), sections OPTIONS
  (`--once` now states it does not serve; `-d` added to `--database`), SERVICE
  (`X-PGR-Pixels` present only when a box was asked for), PREFERENCES
  (`queueSize` 20; `downloadConcurrency` global; `maintenanceIntervalSeconds`
  evicts only; `queueRefreshIntervalSeconds` seeds only), EXIT STATUS (a
  missing folder at launch is not fatal). The `--help` text no longer names the
  retired `pgr_ctl serve`.
- **Housekeeping.** `PhotoStore.heldOriginals` deleted (zero callers; PLAN
  already listed it as removed) and the stray `@discardableResult` restored to
  `removeSource`, which now also prunes its `sourceOfPhoto` mappings. The
  `QueueTests` tautology replaced with a deterministic assertion (a card lands
  strictly inside the span — never head, never tail). Stale narration corrected
  in `ServeWalkTests`, `CacheTests`, `PhotoQueue`'s header,
  `Preferences.downloadConcurrency`, and `RunCommand` (triplicated doc comment,
  orphaned comment, unused `makeFiller` parameter).

**Addressed in the second pass, same evening** (after the agent was restarted
on the fixed build; the client app confirmed working):

- **`.staging` crash leak — fixed.** `PhotoCache.prepare` reclaims the staging
  directory at launch, the one place it can be: the index walk never looks
  inside. Pinned by "A crashed download's staging leftovers are reclaimed at
  the next launch".
- **431-vs-400 — fixed.** A FIN before the blank line is now `400 truncated
  request`; only a header block past the 64 KB cap gets 431. Both refusals
  pinned over a real socket in `RequestBodyTests`.
- **Source-add validation — fixed.** `SourceRequest.resolve` checks
  directory-ness: a file named as a folder (or the reverse) refuses the whole
  batch with 400, naming each path under a new `mismatched` field; missing
  outranks mismatched. `recursive` on a `file` source is refused at POST with
  exactly PATCH's wording instead of being silently dropped. `pgr_ctl sources
  add` reports both refusals. Pinned at the resolve seam
  (`SourceRequestTests`), the kit (`SourceStore.add`), and over HTTP
  (`SourceEndpointTests`); man page POST paragraph updated.
- **Coverage closed:** `X-PGR-Source`/`X-PGR-Storage` asserted against the
  daemon's own 200s (rendered and original), plus `X-PGR-Pixels` absent on
  originals; the endpoint's render-failure skip-and-retire loop tested end to
  end (client sees only 200s, the bad file burns three attempts and is
  blacklisted); both endpoints answer 503 for an unopenable library.

**Third pass, same evening — the self-ring, and PLAN.md brought current (both
at Syd's direction):**

- **Doorbell self-ring — fixed by deletion, not by a guard.** The
  refresh-completion `.sourcesChanged` announce is gone: nothing listened
  (clients ask over HTTP, the panel polls; the only observer was the agent
  itself), and a service announcing its own scan results ran against the
  outside-world→service direction rule. The post-refresh ring-drop went with
  it, so a client's ring landing mid-refresh now keeps its promptness.
  `Reporter` lost the `sawAnything` machinery that existed only to decide the
  announce. No red-green test: the assertable behavior is the absence of a
  machine-global notification, which any concurrent agent can make flaky —
  verified instead by the full suite and to be confirmed by cadence at the
  next restart (refreshes on the 300-second schedule during a copy, not every
  ~20 seconds).
- **PLAN.md made accurate** — twenty-two corrections, at Syd's request, as
  part of this audit. The load-bearing ones: the eligibility arithmetic is
  `deal_seq − w − 1` (minimum gap `w + 1`, `N − w − 1` candidates) everywhere
  the formula appears; the pass condition is "dealable population within
  `w + 1`", with a dated *Refined 2026-08-24* paragraph recording the
  three-states fix; the candidate SQL sketch matches the code (one shuffle
  over everything, claim expiry, render-failure clause); *Talking to the
  subsystems we do control* is marked superseded and rewritten to what
  survives (the control channel, and `pgr_ctl` as the rig); the Design
  Decisions bullets for the queue target, the per-source pump,
  dealable-vs-shown, and FIFO now describe the deal-over-everything shape;
  the 1000-photo cache cap became the byte ceiling; the launch queue-prune is
  struck through as removed; selection-claims-atomically replaced the stale
  "fix is to make it one statement again"; the scratch-agent hazard names
  `PGR_PREFS_SUITE`, the global-topic caveat, and `--once` now being safe;
  and *The doorbell rings back at you* carries the full self-ring reversal
  with the live measurement.

**Fourth pass — Accept on cache hits, design settled with Syd, fixed:**

- The cache key stays `(photo, size)` — one rendering per size. A hit now
  checks *admission*, not equality: a held rendering in any format the
  client's `Accept` allows is served as it is, and only a client that
  genuinely excludes it forces a re-render, in the negotiated format, from the
  original. The replacement takes the held file's place and deletes it, which
  also closes the stranding leak (two extensions sharing one key's identity,
  one invisible to the index forever).
- Negotiation can now fail: an `Accept` admitting neither HEIC nor JPEG is
  refused with `406 Not Acceptable`, decided before any card is popped. It
  used to fall through to HEIC silently.
- The one corner, decided deliberately: held format unacceptable *and*
  original evicted → the held bytes go out with the reason logged, rather
  than answering a client nothing over a format preference.
- Checked and untouched: the Mac app sends no `Accept` header, which admits
  everything — no app change is necessary, so no FEATURES.md TODO is due.
  Nothing under `app/mac/` or `Sources/PhotoGoRoundDisplay/` was modified.
- Pinned by failing-first endpoint tests (unacceptable hit → JPEG replaces
  HEIC on disk, permissive client then hits the JPEG; `image/png` → 406 with
  the queue depth unchanged; evicted-original corner) plus unit tests on
  `negotiated`/`admitted`; the test titled "Accept decides the format" now
  claims only what is true. Man page SERVICE paragraph updated. Full suite:
  439 tests, all passing.

**Fifth pass — the fetch-failure catch split, design settled with Syd, fixed:**

- **Only a provider-confirmed absence deletes.** `PhotoCache.cache` now has
  two catches: the provider failing asks `existence()` — the same three-valued
  question that guards serving — and only `.absent` removes the row and bytes;
  `.present` and `.unknown` keep everything, logged, retried when the card
  comes round. A failure on our side (adopt into the store, the `byte_size`
  UPDATE) cleans the temp file, logs, and deletes nothing — previously a
  read-only cache root deleted a photograph per fetch attempt, in a
  delete → rescan → re-add loop.
- **Decided deliberately:** a present-but-unreadable file keeps its row and
  retries forever — the churn is accepted over deleting a photograph that is
  demonstrably there. No strike counter for 0.1.
- `SourceStore.isOnline` lost its last caller and is deleted. The SQL-failure
  sub-case is covered by the restructure's scope, not by a test — forcing
  `SQLITE_BUSY` at that exact statement is timing-flaky and was left alone.
- Pinned by failing-first tests: an adopt failure (read-only cache root, with
  staging writable so the download itself succeeds) keeps the photograph; a
  present-but-unreadable file keeps it; the existing confirmed-absence test
  passes unchanged, pinning the one case that still removes. PLAN's *A photo
  that will not render* contrast sentence updated to the confirmed-absence
  rule. Full suite: 441 tests, all passing.

**Sixth pass — the eviction race, design settled with Syd, fixed:**

- **A file body is opened when the answer is decided, and streamed from the
  handle.** Serving pops the card, which removes the photograph's eviction
  protection at the moment its bytes go out; the endpoint used to visit the
  file three separate times (index check, `stat` for `Content-Length`, the
  pump's open after headers were on the wire), and anything deleting the file
  between visits — maintenance, a removal, a source delete — produced a 200
  with an empty or truncated body. Now `Response.Body.file` carries an open
  `FileHandle` plus a size measured through that same handle, so the promise
  and the delivery cannot disagree, and POSIX keeps the bytes alive however
  the name goes. The one remaining door — the open itself failing — closes
  before any header is written: the card is skipped like any other whose
  bytes are not here, with a re-fetch requested for materialized photographs.
- Pinned failing-first by a wire test whose route decides its answer, deletes
  the file, and returns — the client must receive every byte with a matching
  `Content-Length` (it got a truncated body before) — plus an endpoint test
  reading a 200's handle in full after the underlying file is deleted. The
  open-failure skip branch mirrors the established skip path and is covered
  by structure; the window cannot be forced deterministically from outside.
- One observation recorded honestly: a single kit-suite run failed with five
  issues during this pass and never reproduced — six consecutive clean runs
  since, test names not captured. Worth watching; not attributed.
- Full suite: 443 tests, all passing.

**Seventh pass — the coverage gaps closed, and the flake attributed:**

- **Consumer registry** — a new `ConsumerTests` suite: first sight creates and
  every sight after is the same row with the heartbeat moved; identity is
  `(kind, displayID)`, so two monitors are two consumers and `widget.small` /
  `widget.large` discriminate in the kind; a displayless consumer is stable;
  `touch` moves `seenAt` without moving `createdAt`; `forget` removes one and
  spares the rest; an unknown id is nil; and registering never spends a card.
- **Cache clearing scopes** — `clear(.source)` frees one source's bytes and
  leaves every other source's alone, keeping rows and shuffle history;
  `clear(.unavailableSources)` frees only what can never be re-fetched, with
  `costOfClearing` reporting `costsNothingToRefetch`; `costOfClearing`
  (.everything) states the price a full clear charges; and referenced
  photographs report as free, because re-retrieving one means opening a file.
- **Critical-free-space eviction** — the halve-the-ceiling branch, reached by
  a second cache over the same store (the settings clamp ties
  `criticalFreeBytes` to `minimumFreeBytes`, and a minimum every volume is
  under stops anything being cached at all), plus the healthy-disk control
  where the ceiling is the whole policy.
- **EXIF orientation** — a sideways JPEG (stored 400×200, orientation 6) is
  handed over upright at 200×400, and the box bounds the *upright*
  photograph: into 100×100 it comes back 50×100, which is the man page's
  "no image returned will exceed either bound" for the case that would break
  it. Both pin behaviour that was already correct.
- **`PGR_DATABASE` / `PGR_CACHE` / `PGR_PREFS_SUITE`** — the environment form
  of every path, the flag winning over it, an empty variable not being a
  value, and the hazard that has already been paid for once: relocating the
  container does **not** relocate preferences, and `PGR_PREFS_SUITE` is the
  only thing that isolates the third rung.

- **The one-off flake, attributed and fixed.** It was never reproducible on an
  idle machine — 24 clean full runs and 12 kit-only runs — so it was forced
  instead: every core loaded, and it appeared within six runs. All five issues
  were the same line, `CacheQueueTests`'s `eventually` deadline, and five
  *different* tests timing out together is the tell — not five slow queues but
  the whole target's tasks starved of a core while four test targets run in
  parallel. The two-second bound is now ten: a genuinely wedged queue still
  fails fast rather than hanging the suite, with enough headroom for a loaded
  machine. Verified with eight runs under the identical load that produced it.

**Also this pass, at Syd's direction:** a fetch that failed because its volume
is not mounted no longer prints in red. It changes nothing, it resolves itself
when the drive returns, and colouring it red drew the eye to the one line on
the console needing no attention. Red now means the library changed — a
photograph dropped, a source going unavailable, a scan's removals — which is
where it belongs.

**Nothing is left open from this audit** except `app/mac/FEATURES.md`'s
`advanceIntervalSeconds`, deliberately deferred to Syd's audit of the Mac app.

## Suggested fix order

1. The `--once` port clobber and the signal-handler lifetime — small, contained,
   and both protect the running agent.
2. The small-library pass logic (bug 1).
3. The man page PREFERENCES table and EXIT STATUS corrections, and the
   `pgr_ctl serve` usage line.
4. `FillerBox`/`Gauge`/`seedIfEmpty` tests.
5. The remaining bugs and stale-test cleanups as they come up.
