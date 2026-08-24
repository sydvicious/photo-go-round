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

## Suggested fix order

1. The `--once` port clobber and the signal-handler lifetime — small, contained,
   and both protect the running agent.
2. The small-library pass logic (bug 1).
3. The man page PREFERENCES table and EXIT STATUS corrections, and the
   `pgr_ctl serve` usage line.
4. `FillerBox`/`Gauge`/`seedIfEmpty` tests.
5. The remaining bugs and stale-test cleanups as they come up.
