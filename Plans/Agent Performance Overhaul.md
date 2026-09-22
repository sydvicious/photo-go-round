# Summary

**Closed 2026-09-19.** Syd: "we are not doing Phase 7. I am closing this effort." Everything here is
built and installed except the `NSLock`s outside the agent, which are the test doubles and the
wallpaper extension's `PaneHandler`; Phase 7 was answered by measurement rather than built. The agent
does not go silent under load any more.

Stop the agent going silent under load. The agent keeps resizing for its clients, one resize at a time on a `Resizer` actor of its own, and caches what it resizes again so the queue has less to do. It also gives every HTTP request its own actor on its own thread, holds the database's write lock only while it writes, and moves the refresh and the downloads onto actors of their own.

# Rationale

On 2026-09-16 the app and the screensaver lost the agent three times in one afternoon, and not because anything had crashed. A thread sample of the running agent showed every thread in Swift's shared pool stuck in blocking work: four resizing pictures, one refresh holding the write lock while reading pages off disk, and two waiting for that lock. With the pool full, nothing else in the process could run, so requests took 10 to 212 seconds against a client that gives up at five. Every surface depends on `/v1/next` answering, so this is the agent's first job to get right.

# Phases

- **Phase 1 — Reproduce it.** A failing test that fills the pool the way the sample did, before anything is fixed. **Built 2026-09-16; it failed as intended, and passes since the `Resizer`.**
  - `PictureEndpoint.resize` is a hook, so a test can make a resize hang the way the system decoder did.
  - `ServingUnderLoadTests`: more hanging resizes than the machine has cores, then a request with no size and `GET /v1/sources`, each of which must answer inside `ServiceTiming.pictureReadLimit`. Both took 6.05 s — they never ran until the resizes were let go.
  - A `LOCK:` log line for every transaction that holds the write lock too long, so the baseline is on record before anything changes. Built, with `LongLockTests`. *Since late 2026-09-16 it also says how much of the hold was the commit; see* The commit, split out.
- **Phase 2 — The `Resizer`.** Every resize the agent does runs on one serial actor with its own dispatch queue, off the shared pool. **Built 2026-09-16.**
  - `/v1/next`'s resizes and the dashboard's thumbnail both go through `Resizer.shared`.
  - `TIMING:` splits `resize wait` from `render`.
  - *Reversed the same day:* this phase was "clients stop asking for a size" until the probe; see *The resize probe*.
- **Phase 2a — Serve the original when the resizer stalls.** A request waits at most a second for its resize, then streams the original. **Built 2026-09-16.**
  - The second counts the wait for a turn and the resize together; a pinned bound keeps it inside the client's five.
  - A resize still queued when its request gives up is skipped; one already running finishes.
  - A `RESIZE:` log line and a `TIMING:` stage say when it happened.
  - `Shuffle` decodes to its box with EXIF orientation applied, as the wallpaper already does.
  - Serving the original is not a render failure.
- **Phase 2b — The resize cache comes back.** Keep what the `Resizer` makes, so a picture already resized for a box is not resized again. **Designed 2026-09-16, question by question; built the same day.** Syd, 2026-09-16: "We will pretty much resize each picture once if there is a small number of pics in the sources and everything fits in the cache, and save the expensive HEIC resizer resource."
  - Evicted oldest first, by each file's creation date or the same date kept in the database.
  - A resized copy stays when its original is evicted.
  - One file for each photograph, box asked for and format — so several per photograph — in a `resized/` folder of the cache, with a row for each in the database. *Agreed 2026-09-16. Built as `.resized/`, with a dot, so the walk that indexes originals by source never takes it for one.*
  - A hit is streamed before the `Resizer` is asked; a miss is resized, written, then served. *Agreed 2026-09-16.*
  - Copies count against the same `cacheByteCeiling` as originals. *Decided 2026-09-16, against the proposal of a ceiling of their own.*
  - Eviction takes the oldest file first, original or copy, by when the file was made. *Decided 2026-09-16; replaces the originals' last-shown rank.*
  - A deleted photograph's copies are deleted straight away, files and rows — only when it is actually deleted, never because its source is offline. *Decided 2026-09-16, replacing the proposed launch sweep.*
  - The dashboard's thumbnail uses the same cache. *Decided 2026-09-16.*
  - Eviction runs after every file written to the cache — an original a fetch brings in, or a copy kept — and at no other time; the maintenance timer is gone. *Decided and built 2026-09-16, late; recorded in `TODO.md`, item 10 of* Passed over on 2026-09-16*, and* Eviction *in `PLAN.md`.*
- **Phase 3 — One actor per request.** Each HTTP request runs on an actor whose executor is a serial dispatch queue of its own, and opens its database connection there. **Built and installed 2026-09-17.** The agent says so on a red line if it is ever built without the package setting the phase depends on. See *Built* under *One actor per request*.
  - Every route, not only `/v1/next`.
  - The async functions on the request path stay on that thread instead of hopping to the shared pool.
- **Phase 4 — The refresh locks only to write.** The walk stages what it found in temporary tables with no lock held, then applies additions and removals under the lock, 100 at a time. **Built 2026-09-16,** after a probe measured where the lock's time went, and installed the same night: 173 of 190 pages took no lock, and no transaction held the writer 50 ms. See *Built*, under *The refresh locks only to write*.
  - Each page of 100 is read with no lock, and locks only if it has something to write, as the walk goes. *Decided 2026-09-16: "as the walk goes, 100 at a time".*
  - Removing a source deletes its photographs 100 at a time too, before the source row goes. *Decided 2026-09-16: "pages of 100, accept the count".*
- **Phase 5 — Refresh and downloads on their own actors.** Each gets its own executor and database connection, with no `NSLock`. **Built 2026-09-17, in four slices:** the refresh and the fetcher, `PhotoStore` and the editing gate, the evictor, and the last of the locks. **No `NSLock` is left in the agent or the kit.** Four of them could not become actors; see *Built: the last of the locks*.
- **Phase 6 — The cache index comes from the database at launch**, so the port opens in milliseconds rather than after a walk of the cache. **Built and installed 2026-09-17.** See *Built*, under the section of that name.
- **After each phase,** Syd installs the agent and reads the `TIMING:` lines during a refresh.
- **Not a phase, and the largest single win:** the LaunchAgent's `ProcessType` was `Background`, which throttles disk I/O. `Adaptive` since 2026-09-17; see *Most of the restart was an I/O throttle, not the walk*.
- **`Deadline`'s timer no longer depends on the shared pool.** **Built 2026-09-18** after the app spent a morning blank; see *The deadline's own clock*. What it left behind was Phase 7.
- **Phase 7 — Nothing that blocks runs on the cooperative pool. Answered 2026-09-19 by measurement, and not built.** The probe went in first, at Syd's "you should be the probe so you can prove it does when we think we are done" — and it said the pool is not starved. `0ms typical` in every one of some 325 windows, worst single sample 364 ms, and 1–10 ms in the windows that contained a late deadline. See *Phase 7 — nothing that blocks runs on the cooperative pool*, under *What the probe said*.
  - **`PoolWait` stays.** Syd, 2026-09-18: "keep PoolWait." One sampler, one line a minute, and the thing that would say if this ever changes.
  - What the give-ups actually were is the item below.
- **The resize budget is the p95 of measured renders, not a guess. Built 2026-09-19.** One second was set from the healthy case and was cutting one render in nine; 1.5 s is the p95 of 3,573 measured ones. See *The budget was measuring its own wall*.
- **Nothing is left open here.** The two items this plan was holding were carried to `TODO.md` when it closed on 2026-09-19 — *The `NSLock`s outside the agent* (one in `PaneHandler`, 28 in test doubles) and *A disallow-list for images that will not decode*. Serving's own one-row writes are no longer the story either: since `ProcessType Adaptive` and the evictor, every long hold measured has been its own `COMMIT` with nothing waiting. **Everything in this plan is built and installed.**

# Design Decisions

- **Long locks in the database are death.** Syd, 2026-09-16. Every write takes the lock for a bounded amount of known work and lets go; the rest of this list follows from it.
- **The agent keeps resizing for its clients, and caches the results again.** Syd, 2026-09-16, after the resize probe: "This finding reverses a couple of choices I have made, if we can get this to work: the agent will continue to do the resizing; the clients don't need to mess with this complication. we should start caching the resized images again to reduce the workload on the resize queue." The probe showed resizes are fast one at a time and nothing needs the main thread; the deathtrap was running many at once on the shared pool. *This reverses* three decisions below, kept as a record: clients resizing, the client logging decode failures, and the resize cache staying gone.
- ~~**Clients stop asking for a size and resize the original themselves; `/v1/next` serves originals.**~~ *Reversed 2026-09-16, see above.* Syd, 2026-09-16: "yes, clients resize; the agent serves originals", later narrowed by the dashboard decision below: the clients stop requesting `w` and `h`, except the dashboard.
- **`w` and `h` stay on `/v1/next`; the agent keeps its entire resizing mechanism.** Syd, 2026-09-16: "you still need the entire resizing mechanism; it just needs to perform better. and it will be much less commonly called". This reverses the earlier "Since we have no customers, we don't have to rename the API to remove the h and v parameters. We can just do it." The parameters stay, and the clients keep sending them.
- **Each HTTP request gets its own actor and thread.** Syd, 2026-09-16: "Each http request gets its own actor/thread." *Claude's reading: an actor whose `unownedExecutor` is a `DispatchSerialQueue`, as `SystemPhotoLibrary.Album` already has, so blocking SQLite calls wait on that request's thread and not on the shared pool.*
- **A refresh locks the database only while it writes, in pages of 100.** Syd, 2026-09-16, offering two ways: stage additions and removals in temporary tables and apply them all at once, or "lock-do 100 operations-unlock, repeat". Claude proposed both, staging first and then applying in pages; asked whether pages or one merge, Syd: "pages of 100". No single lock lasts as long as a whole album.
- **Refresh and downloads run on separate actors, not behind `NSLock`.** Syd, 2026-09-16: "the agent should run the refresh and downloads in separate actors (not using NSLock). It should only lock the database when adding or removing entries, so as not to lock the database for a long period of time."
- **A failing test comes before each fix.** The first test written for this, which sent one request at a time and resized nothing, did not reproduce the stall; the sample is what showed why.
- **The `TIMING:` lines stay.** They are how each phase is judged on the real machine. **Downgraded 2026-09-19, not removed**: `TIMING:`, `RENDER:` and `POOL:` now log at the level per-request traffic takes, so a Debug or Claude build still writes them at `.default` and a release build one rung below, where `log show --info` still finds them. `Logging.md`, Phase 5.
- **Eviction follows every write to the cache, and nothing else starts it.** Syd, 2026-09-16: "you should evict when you know the total size is too big, and not any other time", "ditch the timer", "So, after you write any file to the cache, run evict()", and "you might temporarily exceed the space, but that's fine".
- **Measure where a lock's time goes before redesigning it.** Syd, 2026-09-16: "yes, add the timing probe first". The `REFRESH:` line came before Phase 4, and confirmed the lookups were the cost.
- **A transaction that holds the write lock too long says so, on a `LOCK:` line.** Syd, 2026-09-16: "yes, add the LOCK: line." It catches a long lock coming back in daily use, which no test run will. *Claude's threshold: 50 ms, `Database.incidentalWait` — the patience SQLite gives a statement outside a transaction, so a lock held longer than that is one that makes those statements fail.*
- **A request runs to completion even if its client has hung up.** Syd, 2026-09-16: "we are not doing that. we don't do that at Indeed, and we serve billions of requests/month." No watching the connection and no cancelling the work.
- ~~**A picture the client cannot decode is discarded, and the client asks for another card at once.**~~ *Moot since 2026-09-16: clients keep receiving resized pictures the agent has already decoded.* Syd, 2026-09-16: "the client reports it or ignore the error and immediately requests another card", then "the client discards it. And what would the agent be doing anway? Client requests -> agent fetches and returns the bits -> client attempts to decode and fails. The agent has already moved on at that point." Nothing is reported. The agent's own render-failure retirement stays for the resizes it still does; Syd, 2026-09-16: "yes, keep the retirement".
- ~~**The dashboard's thumbnail is the one thing the agent still resizes.**~~ *Overtaken 2026-09-16: the agent resizes for everyone again.* Syd, 2026-09-16: "it needs to display in other browsers as well. so given that, we need to keep the resizing in the agent, but update all of the clients to not pass h,v EXCEPT the thumbnail in the dashboard." *Claude's reading: the thumbnail already has its own route, `/v1/dashboard/thumbnail`, with its size fixed in the agent, so the page itself needs no change.*
- ~~**A client logs every picture it cannot decode.**~~ *Moot since 2026-09-16, with the reversal above; the disallow-list idea stands as later work.* Syd, 2026-09-16: "The client needs to log when the decode fails. Later, we might keep track of which images in the client fail, and when a certain number of failures in a row happen, we have an endpoint to tell put the image on a disallow-list". The line names the card, the deal, the photograph and its source, from the `X-PGR-` headers the client already reads. The disallow-list is later work, outside this plan.
- **Resizing runs on an actor of its own, one resize at a time.** Syd, 2026-09-16: "since we have to keep resizing, please make sure that it itself is done in a separate actor", and after the thread sample at 16:40: "it looks like we will need a queue for the Renderer. I would not be surprised if resizing requires MainActor, and two cannot be resized at once." The probe answered both: nothing needs the main thread, and two at once work but HEIC stops getting faster past two. One `Resizer` actor for the process, its executor a serial dispatch queue. **Built 2026-09-16.**
- ~~**The one open risk: a resize that hangs holds up every sized request behind it.**~~ *Answered below.* Serial means one stuck decoder call stops all resizing, as an 89 s resize did at 17:02 on 2026-09-16.
- **Resized copies are evicted oldest first, by creation date, and outlive their originals.** Syd, 2026-09-16: "I suggest cache eviction is based on LRU of the files themselves, and don't bother with removing resized images if the original is evicted", then: "should be strictly based on creation date of the file, or an equivalent semantic in the database." So the order is when each copy was made, not when it was last served, and nothing needs to be recorded on a read. *Claude's reading: this is the eviction for the resized copies Phase 2b brings back; originals keep the eviction they have.*
- **If the resizer stalls, serve the original.** Syd, 2026-09-16, after three thread samples caught the resizer waiting inside Apple's HEIC decoder: "just serve the original image if the resizer stalls." Then, of the shape proposed — a one-second budget covering queue and resize, skipping queued resizes nobody is waiting for, a `RESIZE:` line, `Shuffle` applying orientation, and no render failure charged: "I like all of those choices." *The one-second number is Claude's*: `serveWait` 2 s + check 1 s + resize 1 s stays under `pictureReadLimit` 5 s. *Superseded 2026-09-19 by the decision below; the behaviour is unchanged, only the number.*
- **The resize budget is the p95 of measured renders.** Syd, 2026-09-19: "we should set the limit to the p95 of our measurements." One picture in twenty is served as its original, which is the case the budget was always for. He accepted that it is machine-specific — "on slower machines it might not be enough. Oh, well. M1 Max is 6 years old now" — because a slower Mac serves more originals rather than showing nothing, which is the right direction to be wrong in. **1.5 s, built 2026-09-19**; `serveWait` 2 + check 1 + resize 1.5 = 4.5 still fits under `pictureReadLimit` 5, so the agent carried the change alone and no client needed reinstalling.
- **A budget wide enough to measure comes before the budget that ships.** Syd, 2026-09-19: "let's do 10 now and pick the real number after data", and "but we have to measure". A budget that cuts work censors the data you would set it from — the old one-second number looked defensible because the renders that *finished* had a p99 of 997 ms, which was the wall and not the distribution. Ten seconds for one night, `RENDER:` on every render including the abandoned ones, then the p95 and put it back.
- **Why abandoning a resize buys so little.** Syd, 2026-09-19: "the calling client is going to resize them anyway; no sense in abandoning a mostly-done resize just to redo it again on the client side." Cutting a resize does not save that second, it moves it to the client and adds a 6.4 MB mean transfer. The budget exists for the 89-second decoder, and a generous number does that job as well as a tight one.

# Background

- Already in place on 2026-09-16, and uncommitted: serving's source check has a one-second budget (`ServiceTiming.serveCheckBudget`), `/v1/next` writes a `TIMING:` line per request, and the agent's install waits for launchd to finish removing the old job.
- The refresh already writes in batches of 500 per transaction, and already records what a walk saw in a `TEMP` table (`walk_seen`). *Pages of 100, read before the lock, since Phase 4.*
- `HTTPListener.dispatch` runs every request as a plain `Task` on the shared pool, and `PictureEndpoint` opens a `Database` per request on whatever thread that task lands on.
- `ConfinedDatabase` (the dealer's connection) and `SystemPhotoLibrary.Album` are the two places the agent already keeps blocking work off the pool.
- `Deadline.swift` carries a TODO listing every `NSLock` in the project.

# Detailed discussions

## What happened on 2026-09-16

The day in order, because each stall looked like a different fault until the sample.

1. **About 12:15, Photos stopped answering the agent.** `authorization`, `title` and `assetExists` each waited out their ten-second bound. Serving asked those about every Photos picture before handing it over, so one request took 58 seconds. Fixed the same afternoon with a one-second budget on the check (`SilentLibraryServingTests`, 21 s before, 1.1 s after).
2. **12:37, after a restart.** The agent took two minutes from launch to listening. Every step logged tens of seconds apart; the whole Mac was busy booting, and `photolibraryd` had only started at 12:36.
3. **13:12 and 13:17, during refreshes of Favorites (8,547 photographs).** `/v1/next` took 10–55 seconds while the refresh ran, and 150–700 ms either side of it. This happened on the agent without the one-second fix as well, so that fix did not cause it.
4. **13:24–13:28, the agent before the reinstall.** Requests of 42, 160, 192 and 212 seconds, completing in bunches.
5. **13:29, the install failed.** `launchctl bootout` returns before the job is gone; bootstrap at 13:29:11.409 failed with "37: Operation already in progress", and launchd removed the old service at .417. Fixed in `Scripts/install-agent.sh`.
6. **13:30, the new agent.** No request completed at all in its first minute, though `SERVE:` lines showed cards being taken. Two downloads failed with `database is locked` on the bare `UPDATE photo SET byte_size …` in `PhotoCache.attemptCache`, which runs outside a transaction and so gets only SQLite's 50 ms of patience.

## The thread sample

`sample` of `photogoroundd` pid 13044, three seconds, 13:31:39. Every thread below was in the same frame for all 2,464 samples.

| Thread | Where |
|---|---|
| pool | `PictureEndpoint.next` → `PhotoRenderer.render` → HEIF encode, waiting on a condition variable inside VideoToolbox |
| own queue | `PhotoRenderer.render` → HEIF decode → `RemoteVideoDecoder_StartRemoteSession` → synchronous XPC to the decoder service |
| pool | `PhotoRenderer.render` → `CGContextDrawImage` → `resample_horizontal` |
| pool | the same, a second request |
| pool | `PhotoRenderer.render` → HEIF decode → `FigDataByteStreamRead` |
| pool | `Deck.register` → `Database.transaction` (the synchronous form) → SQLite's busy handler → `nanosleep` |
| pool | `RunCommand.runRefresh` → `SourceStore.applyRefresh` → `PhotoPool.upsert` → `INSERT OR IGNORE` → `sqlite3BtreeIndexMoveto` → `pread` |
| pool | `RunCommand.run` → `describe` → `PhotoCache.status` → `pread` |
| pool | `QueueFetcher` lane → `PhotoCache.attemptCache` → bare `UPDATE` → busy handler → `nanosleep` |

What that says:

- **The pool had nothing left.** Swift's shared pool is sized to the machine's cores. Every thread in it was in synchronous work that does not suspend, so no other task in the process could be scheduled — including the ones that would have finished a request.
- **Resizing was most of it.** Four pool threads, plus one on the listener's own queue. A decode of a large HEIC measured 109 ms median and up to about a second in `PLAN.md`; five at once under a busy disk is what the sample shows.
- **The refresh held the write lock while reading.** `INSERT OR IGNORE` has to find out whether each row exists, which means walking the unique index, which means reading pages. Under `BEGIN IMMEDIATE` that reading happens with every other writer locked out.
- **Two writers were waiting on it from pool threads.** `Deck.register` uses the synchronous `transaction`, which retries with `Thread.sleep`. The download's `UPDATE` is outside any transaction, so SQLite's own busy handler sleeps the thread.

## Reproducing it

### The first attempt

`RefreshWhileServingTests` re-read an 8,547-photograph fake album on its own connection while serving one request at a time. The slowest request was 12 ms, and 5 ms again with a walk that blocked a thread for 430 ms per 500 photographs. It left out the two things the sample shows mattered: **requests at the same time**, and **resizing**. It also had no downloads writing and a small database that stays in the page cache, so the refresh's index reads never touched the disk.

### The second attempt: waves of real resizes

`PictureEndpoint` was given its source providers so a fake Photos album could be served through the real endpoint. Waves of concurrent `w=2560&h=1440` requests for a noisy 12-megapixel HEIC original, while a 30,000-photograph album was re-read in a loop and downloads landed, each on its own connection. **It passed.** Twelve at once: 0.67 s median, 1.1 s slowest. Forty at once: 1.2 s median, 2.0 s slowest. Resizing on the shared pool is slow under load but does not stall, as long as each resize finishes.

The providers hook and the waves test were both removed once the third attempt replaced them; nothing else needed either.

### What the agent's own lines said

By then the agent installed at 13:30 had written 644 `TIMING:` lines.

| Stage | Median | p90 | Slowest |
|---|---|---|---|
| total | 546 ms | 48 s | 751 s |
| render | 427 ms | 18.8 s | 741 s |
| waited | 0 ms | 1.1 s | 109 s |
| check | 22 ms | 1.3 s | 224 s |

Outside two windows, 13:30–13:45 and 14:00–14:15, the median request was about 400 ms. Inside them, **single resizes took up to twelve minutes**, and the thread sample had caught one waiting on synchronous XPC to the system's video decoder. What made the decoder that slow is not measured. What the agent did with it is: requests could not even start for up to 109 s.

**The one-second check budget did not hold either** — 224 s. `Deadline.run`'s timer is itself a task, and a task needs a free pool thread to fire. Any bound built from tasks is only as good as the pool's availability, which is one more reason blocking work has to leave it.

### The third attempt: a resize that hangs

`PictureEndpoint.resize` is a hook, defaulting to `PhotoRenderer.render`. `ServingUnderLoadTests` sets it to block on a semaphore, fires `activeProcessorCount + 4` sized requests, waits from a thread of its own until no more resizes start, then sends a request with no size and `GET /v1/sources` and watches them for `pictureReadLimit` plus a second before letting the resizes go.

**It fails, as it should.** On Syd's MacBook Pro, 10 of 14 resizes started — every core — and both unrelated requests took 6.05 s: they did not run until the watch ended. Phases 2 and 3 are what should make it pass: the resize moves to the `Resizer` actor's own thread, so the hanging resizes wait there and leave the pool free.

**While it fails, it freezes the test process's pool for about six seconds.** In two of three full runs that knocked over `SourceEndpointTests`' "An album identifier that names nothing is refused at the door", which asks the real PhotoKit under a time bound. Once the test passes it holds no pool threads, and that goes away.

## The resize probe

Measured 2026-09-16 at 16:45, eleven minutes after a restart, on Syd's MacBook Pro. 16 HEIC and 16 JPEG originals from the development cache, each resized with `PhotoRenderer.render`'s exact calls to fit 2560×1440 and encoded as HEIC at 0.9, on an `OperationQueue` of the given width — ordinary threads, no main thread, no Swift concurrency.

| Width | HEIC wall | HEIC each (median) | JPEG wall | JPEG each (median) |
|---|---|---|---|---|
| 1 | 3.81 s | 0.24 s | 1.54 s | 0.10 s |
| 2 | 1.70 s | 0.22 s | 0.86 s | 0.11 s |
| 4 | 1.28 s | 0.32 s | 0.50 s | 0.12 s |
| 8 | 1.10 s | 0.58 s | 0.32 s | 0.13 s |

- **Nothing needs the main thread.** Every resize succeeded on a worker thread.
- **Resizes can run at once,** with no failures even at eight.
- **HEIC stops scaling past two.** Each HEIC resize at eight takes more than twice as long as at one, and eight finish barely sooner than four. That fits a shared hardware encoder. JPEG scales.
- **So the deathtrap was never resizing itself.** At 16:39 the agent had six resizes running at once on the shared pool, each taking 17–71 s, and nothing else could run. One at a time they take a quarter of a second.

That is what reversed *Clients stop asking for a size*, below: the complication of resizing in every client buys nothing once the agent resizes serially and off the pool.

**With the `Resizer` built,** `ServingUnderLoadTests` passes: 1 of 14 hanging resizes runs at a time, and the request with no size and `GET /v1/sources` answered in 4 ms and 2 ms.

## The resize cache, proposed

**Written as Claude's proposal, then settled with Syd one question at a time on 2026-09-16.** Each subsection says what was decided and, where the decision went against the proposal, keeps the proposal beneath it as a record.

**As decided:**

- One file for each combination of photograph, box asked for, and format, in `resized/`, with a row per copy in the database. **A photograph can have several copies at once** — Syd, 2026-09-16: "you can store mulitple sizes per photograph, and if the dashboard is showing while something else is also showing, you will have that happen." The app's 1280×768 HEIC, the screensaver's 2560×1440 HEIC and the dashboard's 480×480 JPEG of one photograph are three copies and three rows.
- A hit is served before the `Resizer` is asked; a miss is resized, saved and served; a resize that finishes after its request gave up still saves its copy.
- Originals and copies share `cacheByteCeiling`, and eviction takes the oldest file first by when it was made — a copy's creation, an original's `cached_at` — replacing the originals' last-shown rank.
- No walk at launch. Files with no row are cleared at the first eviction after launch; a row whose file is gone is deleted when a request finds it missing.
- A photograph actually deleted takes its copies with it straight away; an offline source keeps them.
- The dashboard's thumbnail uses the same cache.
- The 1 GB default is to be reexamined later.

### What was measured first

The cache removed on 2026-09-06 died of drift: its key was the client's box in pixels, a window moved two pixels made a second full set, and the hit rate was near zero. So before proposing a key, the boxes asked for since the Mac restarted at 16:29, from the agent's console log, which spans every install since:

| Consumer | Display | Box | Requests |
|---|---|---|---|
| app | 83015B0E… | 1280×768 | 490 |
| app | 83015B0E… | 1280×673 | 267 |
| screensaver | 83015B0E… | 2560×1440 | 58 |
| system-wallpaper | 83015B0E… | 2560×1440 | 11 |
| app | 37D8832A… | 2560×1536 | 6 |
| app | 37D8832A… | 1800×1066 | 2 |
| system-wallpaper | 37D8832A… | 3600×2338 | 1 |

Seven boxes in two and a half hours, and Syd counts five in use now. The screensaver and the wallpaper ask for their display's size and never drift. **Only the app's window drifts, and only while somebody resizes it.** Two boxes for one window, as above, is the cost of that — not the unbounded churn the old cache had, because eviction here is by age within a ceiling, not by rank in a pool.

Resized pictures served before Phase 2a, from the `served` lines, were 170–370 KB each at 1280 and 2560 wide. At about 250 KB a copy, 1 GB holds about four thousand.

### The key, and the file

- **One file per photograph, box and format:** `resized/<photo uuid>_<box w>x<box h>_<pixels w>x<pixels h>.<heic|jpg>`. The box is what was asked for, so a lookup needs nothing but the request; the pixels are what was produced, so a hit can send `X-PGR-Pixels` without opening the file.
- **Keyed by the box, not by the fitted size. Agreed 2026-09-16;** asked which, Syd: "asked for". Two boxes can fit a photograph to the same pixels — a portrait picture in 2560×1440 and in 2600×1440 — and keying by output would share them. It would also need the original's dimensions read before every lookup, which is a file open on every request to save a few copies. Not worth it at five boxes.

### ~~No database~~ A row per copy

**Decided 2026-09-16, against the proposal.** Syd: "rows in the database. writing one row should not lock for very long, and saves the big directory walk at launch." The row holds the copy's key, its size in bytes and when it was made — "an equivalent semantic in the database" to the file's creation date. How full the cache is comes from the rows, so nothing walks the folder to find out.

**No launch walk; files with no row are cleared when eviction runs.** A file can have no row if the agent dies between writing a copy and inserting its row, or if something else puts a file in `resized/`. Syd, 2026-09-16: "accept the rare uncounted file; clear out unaccounted for files when eviction happens." A row whose file has gone needs no walk: the request that finds it missing deletes the row and treats it as a miss. **The walk is at the first eviction after launch**, not every one: once full, eviction follows nearly every write, and a file with no row comes from a crash, which means a relaunch. Syd, 2026-09-16: "first eviction after launch".

The proposal as it was:

- **The creation date is the file's.** `URLResourceKey.creationDateKey` gives it without anything written anywhere else, which is the *strictly based on creation date of the file* half of Syd's rule.
- **An index in memory**, built at launch by listing `resized/`, holding each file's key, size and creation date. Writing a copy adds to it; evicting removes from it.
- **Why not the database.** Every copy would be a write taking the lock, from the resizer's thread, beside the refresh and the downloads. "Long locks in the database are death"; no lock at all is better still.

### Hit, miss, and a resize nobody waited for

1. **Hit:** the request streams the copy with its `Content-Type` and `X-PGR-Pixels`. The `Resizer` is not asked, so a hit never waits behind a stalled resize. **Agreed 2026-09-16.** Syd: "hits should be service before the Resizer is asked. That's the entire point of caching the resized images"
2. **Miss:** the resize runs on the `Resizer` as now, writes its copy there — a temporary name, then a rename — and the request serves the bytes it got back.
3. **A resize whose request gave up after its second still writes its copy.** Nobody gets it this time; the next request for that picture at that box is a hit. That is what turns a stall into one slow picture rather than a slow picture every time it is dealt. **Agreed 2026-09-16.** Syd: "save the copy of the file that did not finish resizing in 1 second. Maybe it will be asked for again." Said alongside: "resizer is a scarce resource prone to stalls".

### The ceiling

**Decided 2026-09-16: one ceiling for originals and copies together.** Asked whether copies should have a limit of their own, Syd: "no, combined limit." So `cacheByteCeiling` bounds both. **Eviction takes the oldest file first, whichever kind it is.** Syd, 2026-09-16: "oldest file first, whether or not is an original." **"Oldest" is when the file was made** — a copy's creation, an original's `cached_at`. Asked whether originals should keep counting a recent showing as new, Syd: "when the file was made." This replaces the originals' present rank, the latest of `last_shown_at`, `cached_at` and `added_at` (`PhotoCache.evictionOrder`), so an original fetched a month ago and shown a minute ago is among the first to go. **The 1 GB default is to be reexamined later.** Syd, 2026-09-16: "1 GB is almost certainly way too big, but we will reexamine that later."

The proposal as it was:

- **`resizedCacheBytes`, 1 GB by default,** a preference like `cacheByteCeiling` and separate from it. Originals and copies are evicted by different rules — originals by the database's rank, copies by age — and sharing one number would make each rule's outcome depend on the other's.
- **Checked after every write:** oldest copies go until the total is under the ceiling.
- **1 GB is a guess**: about four thousand copies at 250 KB, which covers a few hundred photographs at every box in use. `TIMING:` gains `resized copy` and `resize` stages, and the dashboard could count hits and misses, so the number can be judged.

### Deleted photographs

**Decided 2026-09-16: straight away.** Asked whether a deleted photograph's copies should go when it does or be left to the first-eviction sweep, Syd: "delete them straight away." So wherever a photograph's row is removed and its cached original deleted — a source removed, a photograph found absent — its copies' files and rows go with it. **Only for a real deletion.** Syd, the same day: "but only if they are actually deleted. if the source is offline, don't." A source that is offline or unavailable keeps its rows and its cached originals today, and its copies stay with them. The launch sweep proposed below is not built.

The proposal as it was:

- **A copy is only ever served for a card that was dealt and passed the *is it still there?* check**, so a copy of a deleted photograph is never shown, and the deleted-photo guarantee holds without the cache doing anything.
- **At launch, copies of photographs the database no longer holds are removed.** That is not eviction — Syd's "don't bother with removing resized images if the original is evicted" is about the original's bytes going, and those rows stay. A photograph the user deleted leaves no picture of itself on the disk longer than one launch.

### The dashboard

The thumbnail is 480×480 JPEG. It goes in the same cache, keyed the same way, so the page asking about a picture it showed a minute ago costs nothing. **Decided 2026-09-16.** Syd: "yes, same cache"

### Tests

- A second request for the same picture at the same box is served without the resizer being asked, even while a resize hangs.
- A different box is a miss.
- A resize that outlived its request's budget leaves a copy that the next request hits.
- Past the ceiling, the oldest file goes first by when it was made, whether an original or a copy — including an original shown a moment ago.
- A photograph found absent, or a source removed, takes its copies' files and rows with it; a source gone offline keeps them.
- A file in `resized/` with no row is gone after the first eviction following launch, and not before.
- A row whose file has vanished is deleted by the request that finds it, which then resizes.
- The dashboard's thumbnail is a hit the second time it is asked for.

### Built

- **`SchemaV13`**, migration 13: the `resized` table — photograph, box asked for, format, pixels produced, bytes, file, `created_at` — unique on photograph, box and format, its rows cascading with the photograph's.
- **`ResizedCopies`** in the kit: `find` (a row whose file is gone is dropped and is a miss), `save` (file first under a temporary name, then the row; a photograph deleted meanwhile leaves no copy), the byte count, the files of a photograph's or a source's copies, and the once-per-launch sweep of files with no row.
- **`PhotoStore.discard(_:)`, the one owner of a deleted photograph's bytes.** Syd, while this was being built: "refactoring photo deletion is a good idea". A photograph found absent (`PhotoCache.remove`), one a refresh no longer finds (`SourceStore.applyRefresh`) and a removed source (`SourceStore.remove`) all end there, originals and copies together. `PhotoPool.Removal` names the copies' files, read before the rows cascade. Nothing about an offline source calls it.
- **Eviction** reads originals by `cached_at` and copies by `created_at` into one order, takes from it until originals and copies together are under `cacheByteCeiling`, never takes the last original, and deletes evicted copies' rows a hundred to a transaction. The first eviction after launch first clears files in `.resized/` that no row names.
- **`PhotoStore`'s launch walk skips `.resized/`**, which would otherwise have been taken for a source and emptied.
- **`/v1/next`** looks for a copy before asking the resizer and streams it with `X-PGR-Pixels`; `TIMING:` shows `resized copy`. On a miss the resize is saved as a copy on the resizer's thread, whether or not its request has already given up.
- **The dashboard's thumbnail** does the same at 480×480 JPEG, and is served from a copy even if the original has been evicted.
- **`cacheBytes` and `pgr_ctl cache status`** count copies with originals.
- **Tests:** `ResizedCopiesTests` (11) and four endpoint tests — a hit while the resizer hangs, a late resize keeping its copy, the same box resized once, the dashboard's thumbnail resized once. `EndpointCacheTests` "The same size asked for twice renders twice and keeps nothing on disk" was the reversed contract and is replaced. Each was checked by breaking the code it covers; the eviction-order test did not catch copies being ranked after every original until it was given a third photograph, and now does.
- **Docs:** `Documentation/photogoroundd.md`, *Resized copies are kept* and the `cacheByteCeiling` row; `Documentation/pgr_ctl.md`, `cache status`, `cache evict` and `cache clear`; `PLAN.md`, *Eviction*, *The resize cache is removed*, the cache decision, and Phase 3.

**Where the build went beyond what was decided — for Syd to confirm or reverse:**

- **`pgr_ctl cache clear` clears copies too**, in every scope. Clearing asks for the cache's bytes back, and copies are the cache's bytes. **Confirmed.** Syd: "pgr_ctl cache clear nukes everything. Why wouldn't it?"
- ~~**Eviction runs on the agent's maintenance interval, as before**, not after every copy written as the proposal said. Between ticks the cache can sit over its ceiling by the copies written since.~~ *Reversed and built 2026-09-16. Syd: "since you are keeping track of the cache in the database, you should evict when you know the total size is too big, and not any other time", "ditch the timer", and "So, after you write any file to the cache, run evict()". Eviction now follows every original a fetch writes and every resized copy kept, at no other time; the maintenance heartbeat and `maintenanceIntervalSeconds` are gone. Recorded in `TODO.md`, item 10 of* Passed over on 2026-09-16.
- ~~**A copy is served only for a card whose original is still held.**~~ **Fixed the same day.** Syd: "You can serve the copy if the original has been evicted." `PhotoCache.serve` takes `fitting:` again — the box and format — and a card is ready if its original is held **or** it has a copy for that box; `ServedPhoto.copy` carries it, and `/v1/next` streams it. A request with no box still needs the original. `ResizedCopiesTests` "A card whose original was evicted is served from its copy, without waiting or being dropped" waited out a five-second serve wait and returned nothing before, and passes; `EndpointCacheTests` "A sized request is served from its copy after the original has been evicted" was checked by passing no box to `serve`, and caught it.

## When the resizer stalls

### What the samples caught

The `Resizer` was installed at 17:00. At 17:02 one resize took 89.4 s with nothing ahead of it, and the wallpaper and the app waited 92.5 s and 93.4 s behind it. Other renders with an empty queue took 4.0, 5.6 and 22.5 s; the probe at 16:45 had them at 0.1–0.24 s. A watcher sampled the agent every eight seconds and kept three samples in which the resizer thread was inside `PhotoRenderer.render`:

| Caught | Where the resizer waited |
|---|---|
| 17:08:01 | 70% in synchronous XPC to the video decoder service: `VTTileDecompressionSessionDecodeTile` → `RemoteVideoDecoder_DecodeTile` |
| 17:17:32 | 35% in hardware scaling, `IOSurfaceAcceleratorTransformSurface`, a kernel call; the rest decoding |
| 17:18:04 | 66% blocked on a dispatch group inside `CMPhotoDecompressionContainerCreateImageForIndex` |

All three are the **HEIC decode**, not the encode, and all of it is inside Apple's frameworks and the services behind them. The SDK's `CGImageSource.h` has no option to ask for a software decode; its decode options are about HDR and SDR. What makes those services slow at a given moment is not measured.

### The shape

- **Budget.** One second from asking the resizer to having a result, covering the wait for a turn and the resize. On expiry the request streams the original, with the original's content type and no `X-PGR-Pixels`, exactly as a request with no size gets it.
- **Queued work nobody wants.** Each resize carries a flag the request sets when it gives up. The resizer checks it when the resize's turn comes and skips it. A resize already inside ImageIO cannot be stopped; it finishes, and its result is dropped.
- **The line.** `RESIZE: gave up after 1000ms on IMG_0327.HEIC (card 6921, deal #84642); serving the original`, and a `TIMING:` stage so the request's own line shows it.
- **Not a failure.** A stalled decoder says nothing about the photograph, so `render_failures` is not charged.
- **The deadline is a task.** `Deadline.run`'s timer needs a free pool thread to fire, which is what let a one-second check take 224 s on 2026-09-16. With resizing off the pool the timer should be free; the Phase 1 test, extended to a resize that hangs past the budget, is what shows it.

### The clients

- **`Shuffle`** decodes with `CGImageSourceCreateImageAtIndex`, which ignores EXIF orientation and decodes at full size. A portrait original would show sideways, and a 48-megapixel HEIC costs about 190 MB, inside `legacyScreenSaver` too. It switches to `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize` at its box, `kCGImageSourceCreateThumbnailFromImageAlways` and `kCGImageSourceCreateThumbnailWithTransform`. For a picture that was already resized to the box, that costs nothing extra.
- **The wallpaper** already decodes that way in `AgentPicture`.
- **Not measured:** when the system decoder is stalled, the client's own decode of a HEIC original may be slow too. It is on the client's thread, so it delays that client's next picture and nothing else.

### Built

- `ServiceTiming.resizeBudget`, one second; `BoundOrderingTests` holds `serveWait` + `serveCheckBudget` + `resizeBudget` under `pictureReadLimit`.
- `Resizer.Ticket`, abandoned by the request on expiry; `Resizer.run` throws `Skipped` for an abandoned ticket whose turn comes.
- `PictureEndpoint.next` runs the resize under `Deadline.run`; on expiry it logs `RESIZE:` on the console and the unified log, laps `resize gave up`, and streams the original through the same path as a request with no size. No render failure is charged.
- `Shuffle.decode(_:fitting:)` reads the original's dimensions and EXIF orientation, fits the upright size to the box, and decodes a thumbnail at that size with the transform applied.
- Tests: `ServingUnderLoadTests` "A request whose resize stalls gets the original, and the resize queued behind it is skipped" failed first — both requests waited out the 60-second hang and got resized bytes — and passes; `ShuffleDecodeTests` failed on a rotated 40×20 JPEG decoding as 40×20, and passes; `RequestLogTests` pins the `RESIZE:` wording.
- `Documentation/photogoroundd.md`, *`w` and `h` are maximums*, says a resize over a second returns the original.
- **The dashboard's thumbnail got the same budget**, after it waited 38.9 s behind the picture requests' resizes and the page's image fell behind its filename. Syd chose it over a resizer of its own. On expiry it answers `503` with `Retry-After: 1` — a browser cannot be handed a HEIC original — and the page keeps its image, fetches one thumbnail at a time, and asks for the newest picture on a later redraw. `DashboardEndpointTests` "A thumbnail whose resize stalls answers 503 inside the budget" waited 60 s before, and passes.
- **The page moved to `Sources/photogoroundd/js/`** on the way *(in `MacOS/Agent/Dashboard/Resources/` since 2026-09-22; `Project Source Reorg.md`)* — `dashboard.html`, `dashboard.css`, `dashboard.js` — copied into the agent's bundle by the `Photo-Go-Round Server` target's synced `photogoroundd` folder, excluded from the Swift package, and read from that folder when there is no bundle. Syd first said "put the files in app/js/", then: "these files should go in the same directory the agent sources are in, with a subdirectory /js".

## Clients stop asking for a size

**Reversed 2026-09-16; kept as a record.** See *The resize probe*.

Every client of `/v1/next` stops sending `w` and `h` and resizes the original itself. The one exception is the dashboard's thumbnail, which the agent still resizes; see *The dashboard*.

**The agent keeps all of its resizing.** Syd, 2026-09-16: "you still need the entire resizing mechanism; it just needs to perform better. and it will be much less commonly called". So `/v1/next` goes on accepting a size and resizing to it. What changes is that nothing in the project asks it to, and that a resize, when it happens, runs on the `Resizer` actor rather than on whatever thread the request is on.

### What changes on the agent

- **Nothing is removed from `/v1/next`.** `w`, `h`, `Accept` and `X-PGR-Pixels` all keep working; a request without a size gets the original, as it does today.
- **`PhotoRenderer.render` is called only through the `Resizer` actor**, from `PictureEndpoint` and from `DashboardEndpoint`. See *The dashboard* for its shape.
- **The render-failure retirement stays** for the resizes the agent still does. See *Photographs that will not decode*.
- The clients' fitting arithmetic is `AspectFit`, already in the display module.

### What changes on the clients

- **`Shuffle`** decodes with `CGImageSourceCreateImageAtIndex` today, trusting that what arrives is already its size. It switches to `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize` set to the box's longest side, `kCGImageSourceCreateThumbnailFromImageAlways`, and `kCGImageSourceCreateThumbnailWithTransform`, which is the call `PhotoRenderer` makes now. Memory stays bounded by the box, not by the original.
- **The decode moves off the main thread** if it is on it. It is on the client's own process, so a slow decode delays that client's next picture and nobody else's.
- **The wallpaper extension** already decodes with those options in `AgentPicture`; it stops sending `w` and `h`.
- **The screensaver** uses `Shuffle`, so it follows. It runs inside `legacyScreenSaver`, which is the client where decode memory matters most; the thumbnail decode is what keeps a 48-megapixel HEIC from costing 48 megapixels.
- **The saver spike** in `app/saver/Spike` sends `w=1920`. It is a spike; it can stay as it is or go.

### What it costs

- **Transfer.** Originals of 10–40 MB over localhost instead of a few hundred kilobytes. On the same Mac that is a memory copy, not a network cost.
- **Decode on the client.** The same 109 ms median moves into the client, where it already sits inside the gap between pictures.
- **A future remote client** — Watch, widgets, iPhone — can ask for a size, since `/v1/next` still takes one.

### Photographs that will not decode

Today the agent decodes every picture it serves, so it notices a file that will not render, counts it in `render_failures`, and stops dealing it after three. That is what caught Live Photos whose movie was fetched in place of the still. Once the clients stop asking for a size, the agent mostly streams bytes and seldom learns a file is bad. The options were:

1. **A client reports it**: a small `POST` naming the card, which increments the count. The client already knows the card's identity from the `X-PGR-Card` header.
2. **The agent checks at download time**: `CGImageSourceCreateWithURL` plus reading the properties, without decoding pixels, when a download lands. Cheap, and catches the wrong-file-type case, but not a file that parses and then fails to decode.
3. **Nothing retires them**, and a bad file is shown as a blank frame whenever it is dealt.

**Decided 2026-09-16: the client discards it and asks for another card.** Syd first: "the client reports it or ignore the error and immediately requests another card." Then, on whether to report: "the client discards it. And what would the agent be doing anway? Client requests -> agent fetches and returns the bits -> client attempts to decode and fails. The agent has already moved on at that point."

So neither a blank frame nor a report. A client that cannot decode what it was given drops it and asks again straight away, the same way the agent walks past an unrenderable card today. What it costs is known and accepted: a bad file stays in the deck, and each time it is dealt it spends one request and one failed decode on the client.

**The client logs it.** Syd, 2026-09-16: "The client needs to log when the decode fails. Later, we might keep track of which images in the client fail, and when a certain number of failures in a row happen, we have an endpoint to tell put the image on a disallow-list".

*Claude's wording*, in the client's existing style — its consumer name as the prefix, as `app: not answering` already is — at notice level in the `deck` category:

```
app: could not decode card 4821 · deal #83911 · IMG_2481.HEIC · source 5 (Photos › Favorites) · 20.1 MB image/heic: <error>; asking for another
```

- **Every field comes from `ServedPicture`**, which already parses `X-PGR-Card`, `X-PGR-Deal`, `X-PGR-Name`, `X-PGR-Source` and `X-PGR-Source-Name` — nothing new crosses the wire. The byte count and content type are what arrived, which is what tells a movie fetched in place of a still from a truncated file.
- **In `Shuffle`**, so the app and the screensaver share one line; **in `AgentPicture`** for the wallpaper, with its own `system-wallpaper:` prefix.
- **Tested for its wording**, as `TIMING:` is: a test hands `Shuffle` bytes that do not decode and asserts the line and that the next card was asked for.

**Later, and not in this plan: a disallow-list.** Syd's sketch: the client counts failures per image, and after some number in a row calls an endpoint that puts the image on a disallow-list. The log line is written so that work can start from it — it already names the card a client would report. The count, the threshold and the endpoint are decided then. Whether that list is the agent's existing `render_failures` retirement or something beside it is part of that decision. **Carried to `TODO.md`, *A disallow-list for images that will not decode*, when this plan closed on 2026-09-19** — it is the only open item this plan was holding, and closing the plan would have been the end of it.

**The agent's retirement stays.** An earlier draft of this plan deleted `render_failures` and everything that reads it, reasoning that the agent would no longer decode anything. Then: Syd, 2026-09-16: "you still need the entire resizing mechanism; it just needs to perform better. and it will be much less commonly called". Asked whether the retirement is part of that mechanism, Syd: "yes, keep the retirement". So a sized request the agent cannot resize still counts against the photograph as it does now. It will simply fire far less often, because almost nothing asks for a size.

### The dashboard

`DashboardEndpoint` renders a JPEG thumbnail of the last picture served, because not every browser draws HEIC. The options were to keep that one render (it runs once per new picture, not per request, and serves one person looking at a page), or to send the original and let the browser scale it, which fails for HEIC in some browsers.

**Decided 2026-09-16: the thumbnail keeps its JPEG render.** Syd first: "the client has to convert to JPEG now." Asked whether Safari alone was enough, since a browser that cannot decode HEIC cannot convert it either: "it needs to display in other browsers as well. so given that, we need to keep the resizing in the agent, but update all of the clients to not pass h,v EXCEPT the thumbnail in the dashboard."

The page never passed a size: it asks `/v1/dashboard/thumbnail?photo=…`, and `DashboardEndpoint.thumbnailSize` is fixed in the agent. So nothing on the page changes. That render runs once per new picture for one person looking at a page.

**Every resize runs on an actor of its own.** Syd, 2026-09-16: "since we have to keep resizing, please make sure that it itself is done in a separate actor." Then: Syd, 2026-09-16: "you still need the entire resizing mechanism; it just needs to perform better. and it will be much less commonly called".

- **One `Resizer` actor for the whole agent** (Claude's name), whose `unownedExecutor` is a `DispatchSerialQueue` — the same construction as `SystemPhotoLibrary.Album`. A resizing request — the thumbnail, or a sized `/v1/next` — awaits it and suspends; the blocking decode and encode happen on the resizer's thread, not on the request's and not on the shared pool.
- **One, not one per request.** A serial actor means at most one resize at a time in the whole process. With the clients no longer asking for a size, the callers are one person's dashboard and the occasional hand-typed request, which is never a queue worth noticing, and it puts a hard ceiling on what resizing can take from the machine — five concurrent resizes were most of the sample. If a future client makes resizing common again, a small fixed set of resizer actors is the next step, not the shared pool.
- **`PhotoRenderer.render` is called from inside an isolated method on the actor**, not from a `nonisolated async` wrapper, since those hop to the shared pool in this package (see *One actor per request*).

## The `LOCK:` line

### What it says

```
LOCK: held 812ms · waited 3ms · 2 attempts · upsert(_:to:at:isolation:onAdded:) (PhotoPool.swift:96)
```

One line per transaction whose hold passed the threshold, in the unified log at notice level, filtered the same way as `TIMING:`:

```
/usr/bin/log show --info --predicate 'eventMessage BEGINSWITH "LOCK:"'
```

- **held** — from `BEGIN IMMEDIATE` succeeding to `COMMIT` returning. This is the number the rule is about.
- **waited** — from the first attempt to the one that got the lock. Not the rule, but it is the other half of the story: a long `waited` beside a short `held` is somebody else's long lock.
- **attempts** — how many tries it took.
- **where** — the calling function, file and line, taken from `#function`, `#fileID` and `#line` defaults on both forms of `Database.transaction`, so no call site changes.

### Where it is measured

Both `transaction` forms go through `attemptTransaction`, which is the one place `BEGIN` and `COMMIT` are issued, so the clock lives there. Savepoints nested inside a transaction are not measured separately; their time is inside the outer transaction's.

**Not covered:** a write outside any transaction, like `PhotoCache.attemptCache`'s bare `UPDATE`. SQLite takes and releases the lock inside that one `sqlite3_step`. Phase 5 moves that statement into a transaction, which brings it under the line; any other bare write found on the way should follow it.

### The commit, split out

**Added 2026-09-16, late.** `LOCK: held 812ms · commit 790ms · waited 3ms · …`: how much of the hold was `COMMIT` itself. Serving's one-row writes had held the writer 0.5–2.2 s, which no single-row statement explains; the automatic WAL checkpoint, which syncs inside whichever commit crosses its threshold, is the guess this is here to test. `TODO.md`, *Serving's own writes held the lock too long*.

### The threshold

50 ms, and it is not arbitrary. `Database.incidentalWait` is how long SQLite's own busy handler waits for a statement that has no retry — every bare write in the agent, and every `BEGIN` before `transaction` starts backing off. A lock held longer than that is one that turns other writers' statements into `database is locked` errors, which is exactly what happened to two downloads at 13:30:52. How long a page of 100 rows actually holds has not been measured; the Phase 1 baseline is where that number comes from, and if pages routinely pass 50 ms the threshold or the page size is revisited then.

It is a constant beside `incidentalWait`, not a preference: nobody should need to tune how long a lock may be held.

### Tested

The measuring takes an injected clock and log sink, as `StageTimes` and `PictureEndpoint.Served` do, so a test can hold a transaction open past the threshold and assert the line's wording, and assert that a short transaction writes nothing.

## One actor per request

### The shape

- `HTTPListener.dispatch` creates a request actor per connection instead of a bare `Task`.
- The actor owns a `DispatchSerialQueue` and returns it as its `unownedExecutor`. Everything the request does between suspensions runs on that queue's thread, so a synchronous SQLite call or a `Thread.sleep` retry blocks that request's thread and nobody else's.
- The request's `Database` is opened on that actor and never leaves it, which is exactly the one-connection-per-isolation-domain rule `Database` already asks for.
- **The actor alone does not keep the work on its thread.** `PhotoCache.serve`, `PhotoQueue.remove` and `Deck.markShown` are plain `nonisolated async` functions, and this package does not enable `NonisolatedNonsendingByDefault` — so each of them hops off the caller's actor onto the shared pool, and runs its synchronous SQLite there. `Database.transaction`'s async form and `PhotoPool.upsert` already take `isolated (any Actor)? = #isolation` and stay put. The rest of the request path needs the same, or the upcoming feature turned on for the package; which of the two is a Phase 3 decision, and the Phase 1 test is what shows whether it worked.

### Staying on the request's thread

**Decided 2026-09-17: the package-wide setting.** Asked whether to enable `NonisolatedNonsendingByDefault` for the package or to keep adding `isolation: isolated (any Actor)? = #isolation` to each function on the request path, Syd: "the package-wide setting". So every `nonisolated async` function runs on its caller's executor, and a request that hops through `PhotoCache.serve`, `PhotoQueue.remove` and `Deck.markShown` stays on its own queue's thread instead of landing on the shared pool. The five functions that already take the parameter keep it; it says the same thing.

*What it costs:* the change is not the request path's alone — the refresh, the fetcher and the dealer all run `nonisolated async` functions too, and each will now run on whatever executor called it. The tests are the check.

### Built

*2026-09-17, at Syd's "yes, build Phase 3".*

- **`RequestLane`**, an actor whose `unownedExecutor` is a `DispatchSerialQueue` of its own. `HTTPListener.dispatch` makes one per request and runs the route on it, in place of the bare `Task` that put every request on the shared pool.
- **`NonisolatedNonsendingByDefault` is on** for every package target (`Package.swift`, `everyTarget`) and for the Xcode project's own targets (`SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT`).
- **The agent says so if it is ever built without it**, as a red line with the kind `launch.requests-on-the-pool` — the mistake would otherwise be invisible and undo the phase.
- **Tests:** `RequestLaneTests` — the setting is on (`#if hasFeature`, which fails with the setting removed); a lane's work stays on its thread; two lanes run at once on threads of their own; a blocked lane holds up nobody. *The thread test is weaker than it looks: it passes with the setting off too, because a callee that never suspends can finish on the caller's thread. `theSettingIsOn` is what guards the setting.*
- **Not done here:** the endpoints still open their `Database` inside the route, which is now on the lane's thread anyway; Phase 5 is what moves the refresh and the fetcher off the pool.
- **A build note:** the first incremental Xcode build after the setting failed to link; a clean build fixed it. `Build Plan.md`, *An incremental build after a concurrency-feature change does not link*.

### Why an actor with its own queue, and not the alternatives

- **A `Task` on the pool** is today's arrangement and the thing the sample shows failing.
- **`Task.detached` with a task executor preference** also works, but spreads the executor choice across call sites; an actor holds it in one place.
- **A `Thread` per request** gives the thread but no isolation, and every call into async code would need bridging.
- **One shared serial queue for all requests** would serialise the requests behind each other, which is a different stall.

### Threads are not free

Dispatch brings up a thread when a queue has work and none is free, and that is bounded too, though the bound has not been measured here. A request that is abandoned but keeps running holds its thread until it finishes. Today that is how the pool filled up, because each request did seconds of resizing and waited on locks from a thread it did not own.

**Abandoned requests are not cancelled.** Claude proposed watching each connection for the client closing it and cancelling the request's work. Syd, 2026-09-16: "we are not doing that. we don't do that at Indeed, and we serve billions of requests/month." The overhaul removes the reasons a request is slow instead: with originals only (Phase 2), the lock held only to write (Phase 4), and the request's blocking work on its own thread (Phase 3), a request that outlives its client should finish in milliseconds anyway.

## The refresh locks only to write

### Today

For each batch of 500 found photographs, `applyRefresh` takes `BEGIN IMMEDIATE`, runs `INSERT OR IGNORE` and an update per photograph, commits, and then records each one in `walk_seen`. Removals are found afterwards by one query against `walk_seen`, deleted in batches of 500, each under its own lock. The lock lasts one batch. But each batch does 500 index lookups inside it, and on a cold cache those are disk reads with the lock held.

### The probe, before designing further

**Added 2026-09-16, not yet read.** That the time is index lookups under the lock is a guess; nothing measured it. If it is the commit, the sync or a checkpoint, staging would not help. Syd: "yes, add the timing probe first." Each refresh batch now logs a `REFRESH:` line, category `sources`, at info:

- `REFRESH: upsert 500 into source 5 · waited · held · inserts · updates · callbacks · commit · N added · N changed` — `callbacks` is the per-photograph `onChange` the refresh makes inside the lock today.
- `REFRESH: remove 500 · waited · held · lookups · deletes · commit` — `lookups` is the two reads before each delete.
- `REFRESH: walk_seen 500 for source 5 · took` — the temporary-table bookkeeping after each batch, outside the lock.
- `REFRESH: departed query for source 5 · took · N found` — the unlocked read for what left.

`RefreshBatchTiming`; tested in `RefreshBatchTimingTests`, whose report test fails with the report removed. What it shows decides the rest of this section.

**Read 2026-09-16, 22:10–22:11**, two refreshes of every source after Syd installed the agent and ran `pgr_ctl refresh`, 44 upsert batches:

- **The lock is the statements, not the commit.** Commit was 0–5 ms in every batch; callbacks 0 ms. `held` is inserts plus updates, to the millisecond.
- **Almost none of those statements wrote anything.** Every batch added 0 photographs and changed 0 to 2. So the held time is the `INSERT OR IGNORE`'s conflict check and the `UPDATE`'s `WHERE` — index lookups — for rows that are already there and do not change. The plan's guess stands, now measured.
- **How long:** 500-row batches of Favorites (source 5) held 31 ms to 1,114 ms, most 100–400 ms, in the first refresh; 58–218 ms in the second, 30 seconds later with the pages warm. One batch: inserts 996 ms, updates 110 ms, commit 5 ms, 1 changed. The 4.8 s and 5.8 s holds at 22:03–22:04 were the agent before the install, which logged at `PhotoPool.swift:96`.
- **Outside the lock:** `walk_seen` took up to 342 ms a batch, and the departed query 0–12 ms, finding nothing.
- **Not refresh, seen in the same lines:** `markShown` held the writer 1,641 ms, `register` 802 ms and `claim` 658 ms, all before the install. Serving's own writes can be long too; not looked into.

*Claude's reading: staging does what this section says. An unchanged refresh would do all its lookups unlocked and take no write lock at all.*

### Staging

**Decided 2026-09-16: additions are applied as the walk goes, 100 at a time.** Asked whether a page should wait for the end of the walk — which would leave a first walk of a large album or a slow share showing none of its photographs for minutes — Syd: "as the walk goes, 100 at a time". So steps 1–3 below run per page of 100 found, not once per walk; removals are still found and applied after the walk ends, since only the whole walk knows what is gone. *Claude's, following from it:* a page's diff also finds rows whose storage or size changed, and writes only those; the locked write keeps `INSERT OR IGNORE` and the update's `WHERE`, so a row another writer added or changed between the unlocked diff and the lock is still handled; recording the page in `walk_seen` moves into the unlocked step; and a removal page reads each photograph's identity and copies before taking the lock, then deletes by id under it — a copy saved in the moment between is left as a file with no row, which the first eviction after the next launch clears.

1. **Walk with no lock.** Every photograph the provider produces goes into a `TEMP` table (`walk_found`, holding external ID and the fields an insert needs). `TEMP` tables live in the connection's own temporary database, so writing them never takes the main file's lock.
2. **Diff with no lock.** Under WAL a reader never blocks the writer. `SELECT … FROM walk_found WHERE NOT EXISTS (… photo …)` gives the additions, and the reverse gives the removals; both go into their own `TEMP` tables. All the index reading happens here, unlocked.
3. **Apply in pages under the lock.** `BEGIN IMMEDIATE`, insert or delete up to 100 rows by primary key from the staged tables, commit, repeat. Each lock covers only writes whose rows are already known.

A refresh of Favorites with nothing added or removed, as on 2026-09-16, takes no write lock at all.

### Pages of 100, or one merge

Syd offered both. One `INSERT INTO photo SELECT … FROM walk_additions` is the fewest locks, and for a refresh with a handful of changes it is milliseconds. For a first walk of a hundred-thousand-photograph library it is one lock covering a hundred thousand inserts, which is the long lock this overhaul exists to remove. Pages bound the worst case; the cost is more commits. **Decided 2026-09-16: pages of 100.** Syd: "pages of 100". And later the same night, on why: "I don't mind building large lists in memory, doing a lock, and doing a large SQL command; however, doing this 100 at a time saves ram and keeps the database locks short".

### Removing a source

**Decided 2026-09-16: pages of 100, and the count may fall short.** Syd: "pages of 100, accept the count".

The same rule reaches past the refresh. `SourceStore.remove(id:)` deletes the source row inside one `BEGIN IMMEDIATE`, and the foreign key cascades to every photograph and queue entry it had. For Favorites that is one lock covering 8,547 photograph deletes and their index updates, taken while every surface is asking for pictures. So removal deletes the source's photographs in pages of 100 first, then the row with nothing left to cascade. The count it reports is read before the first page, as it is now read before the delete.

A refresh landing a page for that source between removal's pages is the case the current single transaction exists to prevent: its rows would be deleted without being counted. With pages, removal keeps deleting until the source has no photographs left, and the final row delete cascades anything that arrived after the last page. What that costs is a count that can fall short by whatever a concurrent refresh added — a log number, not a photograph. Once the row is gone, the refresh's next page fails the foreign key, which `refresh` already reads as "the source was removed" and stops.

### What moves with it

- `onChange` callbacks for additions and removals fire as each page commits, not as each photograph is found.
- The "enumerated to nothing but was not empty" guard reads the count from `walk_found` before anything is removed.
- The removal of cached bytes for photographs that went (`bytes?.remove(photoUUID:)`) follows each removal page.
- A source removed mid-walk is still the foreign-key failure that `refresh` handles today; with staging it surfaces at apply time rather than during the walk.

### Built

*2026-09-16, at Syd's "yes, build Phase 4".*

- **`PhotoPool.batchSize` is 100**, for the refresh's pages, its removals and removing a source.
- **An upsert page is read, then written.** `planUpsert` looks up each photograph with no lock — this source's row and its storage and size, or failing that whether another source holds the identity — and the lock is taken only if that found an addition or a change. `applyUpsert` writes just those, with `INSERT OR IGNORE` and the update's `WHERE` kept as guards. `onAdded` fires after the commit.
- **A removal page is read, then deleted.** `planRemoval` reads each row's identity, source and copies with no lock; `applyRemoval` deletes by id and answers only the rows it deleted, so a row another writer took first is not counted.
- **Removing a source** deletes its photographs in pages through `PhotoPool.remove(_:countingChanges: false)`, then deletes the row in one short transaction that names any late arrivals' copies first. The count is read before the first page.
- **Different from *Staging* above, as built:** no `walk_found` or additions tables. A page of 100 is already in memory when the walk hands it over, so its lookups are made row by row from there; `walk_seen` stays as it was, for the removals query after the walk. And "takes no write lock at all" is true of the photographs only: `markAvailable` still writes the source's `scanned_at` once per refresh, one row.
- **The `REFRESH:` line** gained `lookups` and `no lock`: `REFRESH: upsert 100 into source 5 · lookups 9ms · no lock · 0 added · 0 changed`.
- **Tests:** `RefreshLockingTests`, seven — pages of 100 as the walk goes; an unchanged refresh takes no lock; a page locks only when it has something to write; removals in pages after the walk; removing a source in pages, counted once; a removal page counts what it deleted; and a page that finds nothing takes no lock. Locking every page, pages of 500, and counting a removed source twice each fail at least one. `RefreshBatchTimingTests` updated for the new wording. The full suite passed twice.
- ~~**To read after installing:** the `REFRESH:` lines during a refresh of Favorites, where an unchanged page should say `no lock`, and the `LOCK:` lines, where `upsert` should be gone.~~ **Read 2026-09-16, 22:24–22:25**, two refreshes of every source after Syd installed the agent and ran `pgr_ctl refresh`:
  - **190 upsert pages; 173 took no lock.** The other 17 each changed one or two rows, and held the writer 0–4 ms. The night's probe, before the change, had 500-row batches holding it 31–1,114 ms.
  - **No `LOCK:` line at all** from 22:24 on, from anything — no transaction reached 50 ms. The last `upsert` lines, 51–137 ms at 22:21, were the agent before the install.
  - **Lookups, now unlocked:** median 5 ms a page, most 225 ms.
  - **The departed queries** found nothing, in 0–10 ms, so no removal page ran.
  - *Seen, not looked into:* the same 17 or so pages changed a row in both refreshes, 20 seconds apart. Something's storage or size reads differently each walk — in `TODO.md`.

## The cache index comes from the database at launch

**Proposed 2026-09-17; not built.** Syd, after the restart measurements: "the agent can ask the database what the cache was the last time it was alive, and can just try to get things out of the cache and return it", and "while the cache walk is going on".

### What the restart measured

Rebooted 13:57, logged in about 13:58, the agent serving at 14:05:22 — **8m22s**. Of that:

- **5m47s before the process was started at all.** `launchd` deferred it; `backgroundtaskmanagementd` was still registering the launch item at 14:02:43.
- **1m49s between the process starting and our first line of code** — dyld and the launch-constraint check, against a disk everything else on the machine was also reading.
- **44.5 s of ours:** `storage 960ms · open 3656ms · migrate 424ms · cache index 39355ms · wiring 28ms · listen 51ms`, then `sources 610ms`.

**The cache walk is 39 s after a boot and 137 ms warm** — the same 300 files and 938 MB, stat for stat. The walk is not slow; the disk is, while the machine boots. And the listener opens only after it. `TODO.md`, *The agent takes about two minutes from launch to listening after a restart*, holds both restarts' numbers.

### Why not simply listen first

Considered and refused, 2026-09-17. Syd: "nothing the clients can do about it, so, no?" An agent that answers with an empty index has no pictures to give, so the client is no better off — and worse, it would believe nothing is cached and fetch again what is already on disk.

### The shape

- **At launch the index is what the database says it was.** `photo.cached_at` records every original the agent adopted, with its `byte_size`, and `resized` records every copy. That is a row per file and one query, against a database the agent has just opened anyway.
- **The listener opens on that**, before anything touches the cache directory.
- **Serving tries the file and treats its absence as a miss.** Syd: "just try to get things out of the cache and return it." A photograph whose file has gone is already an ordinary miss — the queue fetches it again.
- **The walk still runs, at every launch and periodically.** Syd, 2026-09-17: "you still need to do the cache walk periodically, especially at startup, to make sure that the agent's idea of the filesystem matches what is actually on disk", and "while the cache walk is going on" — so it runs in the background, not before the port opens. It corrects the index: files the database did not know about, files the database claims and the disk does not have, the leftover-directory sweep, and the first eviction's clearing of copies with no row.
- **Eviction waits for the walk**, since a total the walk has not finished is not a total worth evicting against.

### Most of the restart was an I/O throttle, not the walk

**Measured 2026-09-17, after four restarts.** The agent's LaunchAgent declared `ProcessType` `Background`, and macOS throttles a background job's disk I/O. Syd: "yes, change it to Adaptive". With `Adaptive`, on the next restart:

| | `Background` | `Adaptive` |
|---|---|---|
| Between the process starting and our first line | 1m49s – 2m34s | **17 s** |
| The cache index walk | 16.1 s – 39.4 s | **8.9 s** |
| Process start to listening | 20 s – 44 s | **9.9 s** |
| `LOCK:` lines in the twenty minutes after | constant, up to 70 s held | **none** |

So the one-row writes that held the writer for hundreds of milliseconds — `markShown`, `register`, `claim` — were the throttle as well. `Scripts/install-agent.sh` carries the setting and the reasoning.

**This does not retire Phase 6.** The walk is still 8.9 s against 137 ms warm, and it is still what the port waits for.

### It waits for Phase 3

Syd, 2026-09-17: "this ties into 'each request is run on its own actor'", then "yes, Phase 3 first". Today the walk runs before anything serves, so it starves nothing. Behind the listener it becomes a long run of `stat` calls in the background, which must not sit on the shared pool — the starvation Phase 3 is for. So Phase 3 comes first, and the walk gets a queue of its own, as the `Resizer` has.

### Built

*2026-09-17, at Syd's "let's do phase 6".*

- **`PhotoCache.prepareFromDatabase()`** reads one query — every `photo` row with `cached_at`, joined to its source — and hands `PhotoStore.believe` the file each one should be at. The agent opens on that, and `STARTUP:` calls it `index`.
- **`PhotoCache.walkCache()`** is the old walk, and marks the store walked when it finishes.
- **`CacheWalk`**, an actor with its own serial queue at `utility`, runs it: once as soon as the listener is up, then every `cacheWalkIntervalSeconds` — 3600 by default, `60...86400`. Each walk logs `CACHE WALK: N held · bytes · N discarded · Nms`.
- **Eviction waits for the first walk**, and says so in the log if asked earlier.
- **A missing file needs nothing new:** `PhotoStore.url(forPhoto:)` already stats the file and forgets it if it has gone, so a believed photograph that is not there is the miss it always was.
- **Tests:** `LaunchIndexTests`, five — the index comes from the database; a believed file serves; a lost file is a miss and leaves the index; the walk corrects the index and the `cached_at` rows behind it; eviction takes nothing until the walk has run. Dropping `store.walked()` or believing nothing each fails one.
- **Not changed:** `prepare()` still walks, which is what `pgr_ctl` and the tests use.
- **Measured after a restart, 2026-09-17 16:08.** Process at 16:08:43 (19 s after the reboot), first line of our code at 16:09:02 (19 s of pre-main), `STARTUP: listening after storage 0ms · open 155ms · migrate 0ms · index 1728ms · wiring 15ms · listen 23ms · total 1924ms`, port accepting at 16:09:10 — **about 70 s from the reboot**, against 2m27s with the walk in front of it and 3m52s–8m22s before `Adaptive`. The walk ran behind the open port and finished at 16:09:22: `CACHE WALK: 225 held · 931.8 MB · 0 discarded · 17149ms`. An hourly walk had also run at 16:07:28 in 7.2 s.

### Open questions

- What the store's totals say while the walk is running, given the dashboard and `pgr_ctl cache status` read them.
- Whether a request that arrives before the walk finishes should be told anything — today a miss is a miss, and that may be enough.
- ~~How often the periodic walk runs, and what starts it.~~ **Decided 2026-09-17: a clock of its own, an hour by default, and always at launch.** Syd: "its own interval, default an hour", then "but definitly at launch". The refresh's clock was the alternative; a cache walk answers to a different pressure.
- What this leaves of *the filesystem is the index*, which `PhotoStore`'s header states as the design. The database becomes the record and the disk the check.

## Refresh and downloads on their own actors

- **The refresh** runs as one actor per source being walked, each with its own serial queue and database connection. `RunCommand.refreshing` (`RefreshGate`, behind an `NSLock`) becomes state on a coordinating actor.
- **The downloads** (`QueueFetcher` lanes, `FetchDeadline`) run on an actor with its own queue, or one per lane. `attemptCache`'s bare `UPDATE` moves inside a retried transaction, so contention waits instead of failing the download, as it did twice at 13:30:52.
- **The `NSLock`s** in `QueueFetcher`, `FetchDeadline`, `QueueFiller`, `SourceBench`, `PhotoStore` and `RunCommand` go with them, following the list in `Deadline.swift`'s TODO. `SystemPhotoLibrary`'s three are left for last, for the reason that TODO gives. *(The TODO was discharged on 2026-09-17 and replaced by a record of what did not convert; see* **Built: the last of the locks**.*)*
- **Every one of them, and actors rather than `Mutex`.** Syd, 2026-09-17: "I flatout don't want NSLocks", and asked whether an actor was wanted even where it makes synchronous code async — `PhotoStore.url(forPhoto:)` is the case — "I don't mind everything being async; I prefer it". So the answer is not a cheaper lock: the state moves onto actors and its callers await it. *(Four places turned out not to allow an actor at all — a `deinit`, and three PhotoKit callbacks. Those are `Atomic` and `Mutex`; see* **Built: the last of the locks**.*)*

### Built: the refresh and the fetcher

*2026-09-17, at Syd's "yes, start with the refresh and the fetcher". The first of four slices; the rest of the `NSLock`s follow.*

- **`QueueFetcher` is an actor.** Its round guard and the lanes' shared tally are actor state. The lanes themselves are `@concurrent nonisolated`, because under `NonisolatedNonsendingByDefault` an ordinary `nonisolated async` function would run on the actor and `concurrency` would mean one.
- **`QueueFiller` is an actor**, and so is `FetchDeadline`'s race between a fetch and its deadline.
- **`RefreshGate` is an actor**, and the per-source walk gives it back explicitly rather than in a `defer`, since that is now `await`.
- **Each source's refresh runs on a `Lane` of its own**, at `utility` — the blocking walk and its SQLite are off the shared pool.
- **One `Lane` type** replaces `RequestLane` and `CacheWalk`; the request path, the cache walk and the refresh all take one, differing only in label and quality of service.
- **The doorbells are `AsyncStream`s.** Syd, 2026-09-17: "AsyncStream for the doorbell". `Doorbell.ring()` yields from the notification callback — safe from any thread, no lock, no `Task` hop — and a task of its own turns rings into `Rang`, which the loop reads and clears at the top of a tick. Rings collapse, as the flag they replaced did: `bufferingNewest(1)`.
- **`Flag` and `Note` are gone.** The fetch path's pair became `FetchNote`, an actor; the two tests that used `Flag` hold their own state now.
- **Still holding a lock, for the slices after this one:** `PhotoStore`, `SourceBench`, `LibraryChanges`, `AgentErrors`, `LaunchTally`, `DarwinNotification`, `SourceStore.editing` (an `NSRecursiveLock`), `FillerBox`, and `SystemPhotoLibrary`'s three. `pgr_ctl`'s spike is not the agent and goes when it does.
- **Tests:** the suite passed twice; `RefreshGateTests`, `RefreshPassTests` and `LaneTests` (was `RequestLaneTests`) are async now.

### Built: `PhotoStore`, and a gate for the source list

*2026-09-17, at Syd's "yes, do slice 2". Committed as `3bf08ba`.*

- **`PhotoStore` is an actor**, and everything downstream of it is `async`: `status`, `bytesOnDisk`, `deal`, `residentURL`, `remove`, `clear`, `costOfClearing`, `nextQueuedToFetch` and `bytesHere` on `PhotoCache`, and the public source edits. 131 call sites across 24 files. Syd, told the size of it: "it will touch everything", then "push on".
- **`root` is `nonisolated let`.** It is set at init and never changes, so the paths that want only the directory do not hop onto the actor to ask.
- **`SourceStore.editing` is an `EditingGate`, not an actor.** Actors are re-entrant, so a second editor would be let in while the first was awaiting — exactly the overlap the `NSRecursiveLock` existed to prevent, and it could not survive the reconcile becoming a suspension. The gate keeps a FIFO queue of waiters and hands the turn on rather than dropping it. `EditingGateTests` fails on mutation of both halves: an `acquire()` that never waits, and a `release()` that resumes the last waiter instead of the first.
- **The Xcode project needed the concurrency setting at project level.** `SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT` was set on the app target alone, so `ConfinedDatabase` would not compile under Xcode at all — *sending 'self.database' risks causing data races*. SwiftPM has it package-wide and never saw it.
- **Keeping a resized copy became a task of its own**, since the write is `async` now and the resizer's work stays synchronous. The response goes out before the copy is on disk, which four tests had to learn to wait for.

### Built: the evictor, and awaiting nothing nobody needs

*2026-09-17, at Syd's "eviction actor".*

- **The rule it came from.** Syd: "you only need to use `await …` when you need the result, or you need the side effect", and "async code is all about getting stuff out of the way." Every standalone `await` in the agent and the kit was read against it. Two qualified, both `evictAfterWriting()`: after a fetch adopts its bytes, and after a copy is kept. The rest set state the next lines read — `store.walked()` gates eviction, `store.believe()` builds the index the caller returns, `store.discard()` must land before a removal is reported.
- **The database is the forcing function.** Syd's phrase, and it is the whole of why this is an actor rather than a `Task`: `Task { evictAfterWriting() }` does not compile, because `PhotoCache` is a struct holding a `Database` and one connection belongs to one isolation domain. Detaching the work means detaching a connection with it — which is what `CopyPlace` already does for the copy write, and what `ConfinedDatabase` does for a lane.
- **`Evictor`** is an actor on a `utility` serial queue, with a connection of its own opened at the first ring and kept. It consumes a `Doorbell`, so a burst of writes costs one pass — where awaiting gave the same outcome by a worse route, each writer waiting to discover that `PhotoStore.claimEviction()` was already taken.
- **`PhotoStore.evictionBell` carries the ring**, because the store is the one object every writer already shares: no closure threaded through `CopyPlace`, both endpoints and the fetch factory. Nil is the default, and a cache with nobody to ring evicts where it wrote.
- **`pgr_ctl` and the tests keep that inline path**, because they are the short-lived processes: a detached task dies at exit, and `pgr_ctl queue fill` would leave the cache over its ceiling until the agent next wrote something.
- **Measured, the first 42 minutes after installing:** 39 locks at or over 50 ms, worst 1621 ms, median 103 ms, and 5 of the 39 waited at all. Every long hold was its own `COMMIT` — held equals commit, waited nothing, one attempt — so what is left is the disk, not contention. The evictor's own writes logged two locks, 103 ms at worst. Nothing evicted between 19:22 and 19:59 while the machine was idle, and about forty passes in the six minutes after it came back: rings only come from writes.
- **`pgr_ctl photos-spike` is gone**, and five `NSLock`s with it. Syd: "we don't need PhotosSpike.swift anymore, right?", then "keep what makes pgr_ctl work, but otherwise, nuke it." `--album` stays, since `sources add` takes one; the album listing it carried does not come back — the app's picker and `GET /v2/photos/albums` are where identifiers come from. `Options.swift` became `PgrCtlOptions.swift`, which no longer collides with the agent's file of that name.
- **Tests wait on a task, not a clock.** Syd: "can you do `await Task { }.run()` instead of a timer?" `Evictor.run()` returns when the bell finishes, so the task running it is the handoff; `CopyPlace.keeping` hands back the task that writes a copy, and `KeptCopies.settle()` awaits it. `until` is gone from `photogorounddTests`. Two tests had been passing vacuously and were found by mutation: one counted evictions reported rather than passes made, and one could not tell a ring never answered from a pass that found nothing.

### Built: the last of the locks

*2026-09-17, at Syd's "start the last slice", then "AsyncStream for both" and "AsyncStream for LibraryChanges too".*

- **Mechanical, and they were most of it.** `SourceBench`, `LibraryChanges`, `FillerBox`, `RunCommand.Sizes` and `RunCommand.Gauge` are actors with the lock deleted. `FillerBox` lost two helpers whose only reason for existing was that "`NSLock` is unavailable from an async context"; `Sizes`' three lock-dancing computed properties are `private(set) var`s; `Gauge` already owned a connection, so it is the `Evictor` shape again. `QueueFiller.isShort` became `@Sendable () async -> Bool`, since what it asks are both actors now.
- **The three ledgers take their reports through an `AsyncStream`.** `AgentErrors`, `LaunchTally` and `LibraryChanges` are each written by synchronous `@Sendable` closures on whatever thread reached them — `Console.alert`'s recorder, `Logger.error(kind:)`, the endpoints' `evicted` and `lookedUp`, a refresh page of a hundred — and none of those can `await`. `Continuation.yield` is safe from any thread, never suspends, and keeps the order, which a `Task` per report would not. Every call site is unchanged.
- **`settle()` is how a reader waits**, and it is not a clock: it puts a `.barrier(CheckedContinuation)` through the same queue and waits its turn. The tests use it, and the dashboard fixture's `snapshot()` calls it. A `settle()` that returns immediately fails six expectations across three tests.
- **`LibraryChanges` going on the stream removed three `await`s** in `PhotoPool.finishUpsert`, `finishRemoval` and `SourceStore.remove`. Those two `finish` functions stay `async` all the same — but not for the database, which they never touch. They write into `inout` parameters the caller reads on the next line, and a `Task` cannot take an `inout`.
- **Four could not become actors, and the reasons differ.**
  - `DarwinNotification.Observation` is an `Atomic`. Its job is cancelling a token exactly once, usually from `deinit`, and a `deinit` cannot `await`. `exchange` claims the token and hands back what was there, which is the whole of the exclusion the lock gave.
  - `SystemPhotoLibrary`'s `ChunkSink`, `RequestHandle` and `ResumeOnce` are `Mutex`es. PhotoKit calls their handlers synchronously on a dispatch queue of its own, and the comment beside them records what happened when Swift inferred actor isolation into them: `dispatch_assert_queue` trips and the process goes down on the first chunk. An actor would also mean a `Task` per chunk, which would queue in memory the megabytes `ChunkSink` exists not to accumulate, and could reorder the writes.
- **The `TODO` in `Deadline.swift` is gone**, replaced by a record of those four exceptions, so the question is not re-opened from scratch.
- **What is left is not the agent:** `NSLock`s in the test doubles, and one in the wallpaper extension's `PaneHandler`.

## The deadline's own clock

*2026-09-18, at Syd's "ok, now, fix the deadline", after a morning of "app still not showing pictures".*

### What was measured

The agent was serving the app perfectly — thirty requests, every one a `200`. The app was discarding them, because `ServiceTiming.pictureReadLimit` is five seconds and the responses were arriving later than that:

```
total 10574ms · 9950 · 9243 · 8900 · 7420 · 7126 · 6324 · 5916
```

Twenty of those thirty gave up on their resize, and the giving up is where the time went — against a budget of **one second**:

```
resize gave up 5472ms · 3722ms · 3061ms · 2470ms · 1959ms · 1735ms
```

`Deadline.run` raced the work against `Task.sleep`, and `Task.sleep` waits on the cooperative pool. So the busier the agent became, the later its own timeouts fired, which is exactly backwards for a mechanism whose whole job is to bound something.

### What was built

- **A `DispatchSourceTimer` on a queue of its own.** Dispatch gives it a thread; nothing the agent is doing can delay it.
- **`FirstAnswer` is a `Mutex`, not an actor.** One of the two callers is now a timer handler, which cannot `await` its turn, and reaching an actor from it would have put the wait back where it was. The same reasoning as `SystemPhotoLibrary`'s three; see `Deadline.swift`.
- **The deadline reports itself when it overruns**, by half again or more: `DEADLINE: 5472ms for a 1000ms limit — the clock was late`. Because the diagnosis above is inference, not proof — see below.

### What could not be proved

**The failure was not reproduced in a test, and the test that claimed to was deleted.** It saturated the pool and asserted the limit held; it passed with the old implementation too — 0.207 s against 0.211 s for a 200 ms limit. A test that cannot tell the fix from the bug is worse than no test, and this is the third time this week that a test has been caught claiming coverage it did not have.

So the fix rests on the field measurement and on the principle — a timeout must not depend on the thing it is bounding — and the `DEADLINE:` line is what will settle it. If the lap was measuring something wider than this call, the line will never appear and the give-ups will still be long.

### What it exposed, which matters more

With the timer made punctual, six tests in `SilentLibraryTests` began failing in full parallel runs while passing alone: fake libraries that answer instantly, reported as silent. Their bounds were 50 ms, and they had only ever passed because the clock was starved alongside the work. **Two seconds was not enough either.**

The bounds are now 10 s for a library that answers, 100 ms where the subject *is* the bound firing, and 5 s where a library delivers three assets before it stalls. That is not a tidy-up; it is the measurement. **A task can wait seconds for a thread on the cooperative pool**, in a test process and in the agent, and that is the same starvation that makes a resize lose its turn.

`QueueFetcher`'s lanes are `@concurrent nonisolated` and do blocking work — a download that waits on PhotoKit holds a pool thread for as long as it waits. That is the first place to look, and it is now the open item at the top of this plan.

## Phase 7 — nothing that blocks runs on the cooperative pool

**Answered 2026-09-19 by measurement, and not built. The pool is not starved.** What follows is kept
in the order it was learned, because the reasoning that led here was wrong and the record of it is
the useful part: the case for Phase 7 is in *What is known* and *What runs there now*, and the
measurement that dismissed it is in *What the probe said* at the end.

### What is known

- **A task can wait seconds to start.** Measured 2026-09-18: with the deadline's clock made punctual, fake libraries that answer in microseconds were reported silent on a 50 ms bound, and on a 2-second bound, in full parallel test runs — while passing alone. Earlier, 2026-09-16: a 10 ms `Task.sleep` in `RequestBodyTests` resumed 1.2 to 1.96 s late for the same reason.
- **It is why a resize loses its turn.** The budget is a second; the resize has to be scheduled inside it. When the pool is starved the resize never starts, the original goes out instead, and the resize cache stays empty so the next request pays again.
- **It is not the resizer's doing.** `Resizer` has had its own serial queue since Phase 2, `Evictor` since Phase 5, the request lanes since Phase 3, and `ConfinedDatabase` its own thread. Those are not on the pool.

### What runs there now

- **`QueueFetcher`'s lanes**, deliberately: they are `@concurrent nonisolated` precisely so that several downloads run at once. A download that waits on PhotoKit or iCloud holds its thread for the whole wait, and `BlockingWork` was introduced earlier exactly because a blocked `copyItem` on a cooperative thread stopped the runtime — eleven of them did.
- **The work side of `Deadline.run`**, which is a `Task`, and everything else the agent starts with a bare `Task { }`.
- **`URLSession` completions and any `@Sendable` closure** that hops back through an `await`.

### What might be done, none of it decided

*Written before the measurement. The third option is what the evidence chose, by default rather than
by argument: there was nothing to fix.*

- **A lane per fetch**, as the refresh already has one per source. Bounded by how many lanes exist rather than by the pool's width, and a blocked fetch then costs one Dispatch thread rather than one of the runtime's few.
- **A bounded executor for fetching** — one serial queue with N lanes — so the concurrency is a number this project chose rather than the core count.
- **Leave it, and make the deadline the answer.** A punctual clock already means a starved resize is abandoned on time and the original goes out; the cost is the resize cache staying cold. That is the cheapest option and it is not obviously wrong.

### How it is measured

**Built 2026-09-18, before the fix.** `PoolWait` asks `await Task { ContinuousClock.now }.value` once a second — a task that does nothing but read the clock, so everything between asking and running is time the pool made it wait — and says a line a minute:

```
POOL: waited 2ms typical · 1842ms worst · 60 samples
```

The median says what an ordinary task pays; the worst says what a deadline has to survive, and an average would hide exactly the shape that breaks one. **Whatever Phase 7 turns out to be, the worst figure before and after is how it is judged.**

### What the field said before any of it

Nine hours of the agent serving 2,503 pictures on 2026-09-18, with the deadline's clock already moved off the pool that morning:

- **149 `DEADLINE:` lines.** Median overrun **2,017 ms** against a 1,000 ms limit; worst **197,544 ms**.
- **311 resize give-ups of 2,503 served**, 12.4%.
- Zero errors.

The timer was not the whole story, and saying so is the point of having put the probe in. `Deadline.report` measures from before the timer is scheduled to when `run` returns, so an overrun means the timer fired on time and *the awaiting task did not resume* — which is a thread, not a clock.

### What the probe said

**Installed 16:50 on 2026-09-18, read at 22:20 over 5h 25m and 2,257 deals.** Every one of some 325
windows: `0ms typical`. The worst single sample of the evening was 364 ms and the next 346 ms;
almost every window's worst was under 10 ms. In the windows that contained a late deadline, the
worst pool wait was 1–10 ms.

So the premise was wrong. The pool is not starved, and the work Phase 7 proposed — lanes for the
fetcher, a bounded executor — would have been built against a fault that measurement says is not
there. **This is what putting the probe in first was for**, and it is worth writing down that it
paid off by cancelling the phase rather than by proving it.

**What the give-ups actually were**, from the same five hours:

| | |
|---|---|
| deals served | 2,257 |
| `RESIZE: gave up` | 242 (10.7%) |
| of those, with a late deadline | **20** |
| `resize wait` (queue for the resizer) | median 0 ms, p90 0 ms, worst 611 ms |

**222 of the 242 were the budget firing on time.** The deadline was punctual, the resizer was never
queued, nothing waited for a thread — the renders simply took longer than the budget allowed. That
is not a concurrency fault at all, and it is the subject of the section below.

**One honest limit on the instrument.** `PoolWait` stamps `asked` *after* its own `Task.sleep`
returns, so a stall that delays the sampler's wakeup is invisible to `worst`. The sample count is
what catches those: 18 windows collected fewer than 56 of an expected 60, and two collected 17. Those
do line up with the overruns. But even reading those windows as badly as possible, the late
deadlines are 0.9% of deals.

## The budget was measuring its own wall

**The fault under the give-ups, found 2026-09-18 and fixed 2026-09-19.** `resizeBudget` was one
second, chosen in Phase 2a from a probe that measured healthy resizes at 0.10–0.24 s. The agent's own
`TIMING:` lines appeared to confirm it: renders had a median of 334 ms and a p99 of **997 ms**
against a 1,000 ms budget.

**That p99 was not a distribution. It was the shape of the wall.** `TIMING:` only exists on the path
that returns a picture, so the 10.7% that were cut recorded no duration at all. The data describing
the budget had been censored by the budget.

### What was measured

**`RENDER:` went in first**, on every render including the ones nobody was waiting for — the
abandoned ones run to completion anyway, because `CopyPlace.keeping` saves their bytes, so the
duration was already there and being thrown away. Then `resizeBudget` went to ten seconds for one
night so almost nothing would be cut. `pictureReadLimit` had to move to fifteen with it, because
`BoundOrderingTests` holds `serveWait + serveCheckBudget + resizeBudget` under it.

Overnight into 2026-09-19, **3,573 renders**, 16 of them abandoned — so the distribution is real and
not its left half:

| | |
|---|---|
| median | 357 ms |
| p90 | 927 ms |
| **p95** | **1,406 ms** |
| p99 | 4,489 ms |
| worst | **26,683 ms** |

Three checks before trusting it: only 16 were still cut; the slow ones are spread through the night
rather than clustered after the launch, so this is the decoder and not a cold page cache; and 324
renders (9.1%) exceeded a second, against the 10.7% give-up rate the old budget produced. Syd ran the
same query independently and got p95 1,395 ms over 3,584 renders.

### What it changed

**`resizeBudget` is 1.5 s, `pictureReadLimit` is back to 5 s.** Give-ups should fall from 10.7% to
about 5%, the 26-second monster is still cut, and 2 + 1 + 1.5 = 4.5 fits under five — so the agent
carried the whole change and no client needed reinstalling.

### What it killed

**Slow does not mean big.** The first night's lines had a 10.9 MB JPEG render in 124 ms and a 1.8 MB
one take 5,997 ms. Anyone tuning this by looking at file sizes will tune the wrong thing.

### What it left behind

`RENDER:` writes to the unified log only, not to the agent's console. Syd, 2026-09-19: "I don't plan
on running this diagnostic unless needed, so please don't pollute /tmp." One line per render is some
3,600 a day; the unified log is ring-buffered by the system and costs nothing until somebody asks.
Reading them back is fast only if the filtering happens in the predicate rather than in a pipe —
`subsystem == "com.sydpolk.photogoround" AND eventMessage CONTAINS "RENDER:"` takes 32 seconds
where the unfiltered form takes many minutes.

**And a measurement constraint worth knowing before planning another overnight run:** `logd` holds
about **9 hours** on this machine — 51 chunks, 499 MB, measured 2026-09-19. The render run was read
with roughly twenty minutes to spare.

## What this leaves stale elsewhere

*All three settled; checked when the plan closed, 2026-09-19.*

- ~~`PLAN.md`, *The resize cache is removed*: reversed by Phase 2b once it is designed.~~ *Done 2026-09-16 — that section now opens "Reversed, decided and built 2026-09-16".*
- ~~`PictureClient` and `AgentPicture` doc comments describing the box.~~ *Moot. These were stale only under "clients stop asking for a size", which Syd reversed the same day: the clients still send `w` and `h`, so the comments still describe what the code does.*
- ~~`Documentation/photogoroundd.md` may want a sentence saying no client in the project sends them.~~ *Moot, for the same reason — they all do.* The man page did need the resize budget corrected to 1.5 s, done 2026-09-19 and pinned by a test so the number cannot drift away from `ServiceTiming` again.

# References

- `PLAN.md` — Phase 1.5.2 (the renderer), *The resize cache is removed*, and the decode measurement at line 194.
- `Shared/Sources/PhotoGoRoundAgentAPI/Support/Deadline.swift` — the TODO listing every `NSLock`.
- `Shared/Sources/PhotoGoRoundAgentAPI/Support/PoolWait.swift` — the probe that answered Phase 7, and `Shared/Tests/PhotoGoRoundDisplayTests/PoolWaitTests.swift`.
- `Shared/Sources/PhotoGoRoundAgentAPI/Host/ServiceTiming.swift` — `resizeBudget` and `pictureReadLimit`, each carrying the measurement it was set from.
- `MacOS/Agent/Tests/BoundOrderingTests.swift` — the sum that keeps the budget honest, and what forced `pictureReadLimit` to move with it.
- `TODO.md`, *Next: the agent's own log file grows without bound* — found while deciding where `RENDER:` should write.
- `MacOS/Agent/Sources/ConfinedDatabase.swift` and `SystemPhotoLibrary.Album` — the existing pattern for keeping blocking work off the pool.
- `MacOS/Shared/Tests/PhotoGoRoundKitTests/RefreshWhileServingTests.swift` — the test that did not reproduce, and why.
- `MacOS/Shared/Tests/PhotoGoRoundKitTests/SilentLibraryServingTests.swift` — the one-second check budget.
- The thread sample, 2026-09-16 13:31:39, saved only in the session's scratchpad.
