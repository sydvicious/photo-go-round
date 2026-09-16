# Summary

Stop the agent going silent under load. The agent keeps resizing for its clients, one resize at a time on a `Resizer` actor of its own, and caches what it resizes again so the queue has less to do. It also gives every HTTP request its own actor on its own thread, holds the database's write lock only while it writes, and moves the refresh and the downloads onto actors of their own.

# Rationale

On 2026-09-16 the app and the screensaver lost the agent three times in one afternoon, and not because anything had crashed. A thread sample of the running agent showed every thread in Swift's shared pool stuck in blocking work: four resizing pictures, one refresh holding the write lock while reading pages off disk, and two waiting for that lock. With the pool full, nothing else in the process could run, so requests took 10 to 212 seconds against a client that gives up at five. Every surface depends on `/v1/next` answering, so this is the agent's first job to get right.

# Phases

- **Phase 1 — Reproduce it.** A failing test that fills the pool the way the sample did, before anything is fixed. **Built 2026-09-16; it failed as intended, and passes since the `Resizer`.**
  - `PictureEndpoint.resize` is a hook, so a test can make a resize hang the way the system decoder did.
  - `ServingUnderLoadTests`: more hanging resizes than the machine has cores, then a request with no size and `GET /v1/sources`, each of which must answer inside `ServiceTiming.pictureReadLimit`. Both took 6.05 s — they never ran until the resizes were let go.
  - A `LOCK:` log line for every transaction that holds the write lock too long, so the baseline is on record before anything changes. Built, with `LongLockTests`.
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
- **Phase 2b — The resize cache comes back.** Keep what the `Resizer` makes, so a picture already resized for a box is not resized again. Not designed yet. Syd, 2026-09-16: "We will pretty much resize each picture once if there is a small number of pics in the sources and everything fits in the cache, and save the expensive HEIC resizer resource."
  - Evicted oldest first, by each file's creation date or the same date kept in the database.
  - A resized copy stays when its original is evicted.
- **Phase 3 — One actor per request.** Each HTTP request runs on an actor whose executor is a serial dispatch queue of its own, and opens its database connection there.
  - Every route, not only `/v1/next`.
  - The async functions on the request path stay on that thread instead of hopping to the shared pool.
- **Phase 4 — The refresh locks only to write.** The walk stages what it found in temporary tables with no lock held, then applies additions and removals under the lock, 100 at a time.
  - Removing a source deletes its photographs 100 at a time too, before the source row goes.
- **Phase 5 — Refresh and downloads on their own actors.** Each gets its own executor and database connection, with no `NSLock`.
- **After each phase,** Syd installs the agent and reads the `TIMING:` lines during a refresh.

# Design Decisions

- **Long locks in the database are death.** Syd, 2026-09-16. Every write takes the lock for a bounded amount of known work and lets go; the rest of this list follows from it.
- **The agent keeps resizing for its clients, and caches the results again.** Syd, 2026-09-16, after the resize probe: "This finding reverses a couple of choices I have made, if we can get this to work: the agent will continue to do the resizing; the clients don't need to mess with this complication. we should start caching the resized images again to reduce the workload on the resize queue." The probe showed resizes are fast one at a time and nothing needs the main thread; the deathtrap was running many at once on the shared pool. *This reverses* three decisions below, kept as a record: clients resizing, the client logging decode failures, and the resize cache staying gone.
- ~~**Clients stop asking for a size and resize the original themselves; `/v1/next` serves originals.**~~ *Reversed 2026-09-16, see above.* Syd, 2026-09-16: "yes, clients resize; the agent serves originals", later narrowed by the dashboard decision below: the clients stop requesting `w` and `h`, except the dashboard.
- **`w` and `h` stay on `/v1/next`; the agent keeps its entire resizing mechanism.** Syd, 2026-09-16: "you still need the entire resizing mechanism; it just needs to perform better. and it will be much less commonly called". This reverses the earlier "Since we have no customers, we don't have to rename the API to remove the h and v parameters. We can just do it." The parameters stay, and the clients keep sending them.
- **Each HTTP request gets its own actor and thread.** Syd, 2026-09-16: "Each http request gets its own actor/thread." *Claude's reading: an actor whose `unownedExecutor` is a `DispatchSerialQueue`, as `SystemPhotoLibrary.Album` already has, so blocking SQLite calls wait on that request's thread and not on the shared pool.*
- **A refresh locks the database only while it writes, in pages of 100.** Syd, 2026-09-16, offering two ways: stage additions and removals in temporary tables and apply them all at once, or "lock-do 100 operations-unlock, repeat". Claude proposed both, staging first and then applying in pages; asked whether pages or one merge, Syd: "pages of 100". No single lock lasts as long as a whole album.
- **Refresh and downloads run on separate actors, not behind `NSLock`.** Syd, 2026-09-16: "the agent should run the refresh and downloads in separate actors (not using NSLock). It should only lock the database when adding or removing entries, so as not to lock the database for a long period of time."
- **A failing test comes before each fix.** The first test written for this, which sent one request at a time and resized nothing, did not reproduce the stall; the sample is what showed why.
- **The `TIMING:` lines stay.** They are how each phase is judged on the real machine.
- **A transaction that holds the write lock too long says so, on a `LOCK:` line.** Syd, 2026-09-16: "yes, add the LOCK: line." It catches a long lock coming back in daily use, which no test run will. *Claude's threshold: 50 ms, `Database.incidentalWait` — the patience SQLite gives a statement outside a transaction, so a lock held longer than that is one that makes those statements fail.*
- **A request runs to completion even if its client has hung up.** Syd, 2026-09-16: "we are not doing that. we don't do that at Indeed, and we serve billions of requests/month." No watching the connection and no cancelling the work.
- ~~**A picture the client cannot decode is discarded, and the client asks for another card at once.**~~ *Moot since 2026-09-16: clients keep receiving resized pictures the agent has already decoded.* Syd, 2026-09-16: "the client reports it or ignore the error and immediately requests another card", then "the client discards it. And what would the agent be doing anway? Client requests -> agent fetches and returns the bits -> client attempts to decode and fails. The agent has already moved on at that point." Nothing is reported. The agent's own render-failure retirement stays for the resizes it still does; Syd, 2026-09-16: "yes, keep the retirement".
- ~~**The dashboard's thumbnail is the one thing the agent still resizes.**~~ *Overtaken 2026-09-16: the agent resizes for everyone again.* Syd, 2026-09-16: "it needs to display in other browsers as well. so given that, we need to keep the resizing in the agent, but update all of the clients to not pass h,v EXCEPT the thumbnail in the dashboard." *Claude's reading: the thumbnail already has its own route, `/v1/dashboard/thumbnail`, with its size fixed in the agent, so the page itself needs no change.*
- ~~**A client logs every picture it cannot decode.**~~ *Moot since 2026-09-16, with the reversal above; the disallow-list idea stands as later work.* Syd, 2026-09-16: "The client needs to log when the decode fails. Later, we might keep track of which images in the client fail, and when a certain number of failures in a row happen, we have an endpoint to tell put the image on a disallow-list". The line names the card, the deal, the photograph and its source, from the `X-PGR-` headers the client already reads. The disallow-list is later work, outside this plan.
- **Resizing runs on an actor of its own, one resize at a time.** Syd, 2026-09-16: "since we have to keep resizing, please make sure that it itself is done in a separate actor", and after the thread sample at 16:40: "it looks like we will need a queue for the Renderer. I would not be surprised if resizing requires MainActor, and two cannot be resized at once." The probe answered both: nothing needs the main thread, and two at once work but HEIC stops getting faster past two. One `Resizer` actor for the process, its executor a serial dispatch queue. **Built 2026-09-16.**
- ~~**The one open risk: a resize that hangs holds up every sized request behind it.**~~ *Answered below.* Serial means one stuck decoder call stops all resizing, as an 89 s resize did at 17:02 on 2026-09-16.
- **Resized copies are evicted oldest first, by creation date, and outlive their originals.** Syd, 2026-09-16: "I suggest cache eviction is based on LRU of the files themselves, and don't bother with removing resized images if the original is evicted", then: "should be strictly based on creation date of the file, or an equivalent semantic in the database." So the order is when each copy was made, not when it was last served, and nothing needs to be recorded on a read. *Claude's reading: this is the eviction for the resized copies Phase 2b brings back; originals keep the eviction they have.*
- **If the resizer stalls, serve the original.** Syd, 2026-09-16, after three thread samples caught the resizer waiting inside Apple's HEIC decoder: "just serve the original image if the resizer stalls." Then, of the shape proposed — a one-second budget covering queue and resize, skipping queued resizes nobody is waiting for, a `RESIZE:` line, `Shuffle` applying orientation, and no render failure charged: "I like all of those choices." *The one-second number is Claude's*: `serveWait` 2 s + check 1 s + resize 1 s stays under `pictureReadLimit` 5 s.

# Background

- Already in place on 2026-09-16, and uncommitted: serving's source check has a one-second budget (`ServiceTiming.serveCheckBudget`), `/v1/next` writes a `TIMING:` line per request, and the agent's install waits for launchd to finish removing the old job.
- The refresh already writes in batches of 500 per transaction, and already records what a walk saw in a `TEMP` table (`walk_seen`).
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
- **The page moved to `Sources/photogoroundd/js/`** on the way — `dashboard.html`, `dashboard.css`, `dashboard.js` — copied into the agent's bundle by the `Photo-Go-Round Server` target's synced `photogoroundd` folder, excluded from the Swift package, and read from that folder when there is no bundle. Syd first said "put the files in app/js/", then: "these files should go in the same directory the agent sources are in, with a subdirectory /js".

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

**Later, and not in this plan: a disallow-list.** Syd's sketch: the client counts failures per image, and after some number in a row calls an endpoint that puts the image on a disallow-list. The log line is written so that work can start from it — it already names the card a client would report. The count, the threshold and the endpoint are decided then. Whether that list is the agent's existing `render_failures` retirement or something beside it is part of that decision.

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

### Staging

1. **Walk with no lock.** Every photograph the provider produces goes into a `TEMP` table (`walk_found`, holding external ID and the fields an insert needs). `TEMP` tables live in the connection's own temporary database, so writing them never takes the main file's lock.
2. **Diff with no lock.** Under WAL a reader never blocks the writer. `SELECT … FROM walk_found WHERE NOT EXISTS (… photo …)` gives the additions, and the reverse gives the removals; both go into their own `TEMP` tables. All the index reading happens here, unlocked.
3. **Apply in pages under the lock.** `BEGIN IMMEDIATE`, insert or delete up to 100 rows by primary key from the staged tables, commit, repeat. Each lock covers only writes whose rows are already known.

A refresh of Favorites with nothing added or removed, as on 2026-09-16, takes no write lock at all.

### Pages of 100, or one merge

Syd offered both. One `INSERT INTO photo SELECT … FROM walk_additions` is the fewest locks, and for a refresh with a handful of changes it is milliseconds. For a first walk of a hundred-thousand-photograph library it is one lock covering a hundred thousand inserts, which is the long lock this overhaul exists to remove. Pages bound the worst case; the cost is more commits. **Decided 2026-09-16: pages of 100.** Syd: "pages of 100".

### Removing a source

The same rule reaches past the refresh. `SourceStore.remove(id:)` deletes the source row inside one `BEGIN IMMEDIATE`, and the foreign key cascades to every photograph and queue entry it had. For Favorites that is one lock covering 8,547 photograph deletes and their index updates, taken while every surface is asking for pictures. So removal deletes the source's photographs in pages of 100 first, then the row with nothing left to cascade. The count it reports is read before the first page, as it is now read before the delete.

A refresh landing a page for that source between removal's pages is the case the current single transaction exists to prevent: its rows would be deleted without being counted. With pages, removal keeps deleting until the source has no photographs left, and the final row delete cascades anything that arrived after the last page. What that costs is a count that can fall short by whatever a concurrent refresh added — a log number, not a photograph. Once the row is gone, the refresh's next page fails the foreign key, which `refresh` already reads as "the source was removed" and stops.

### What moves with it

- `onChange` callbacks for additions and removals fire as each page commits, not as each photograph is found.
- The "enumerated to nothing but was not empty" guard reads the count from `walk_found` before anything is removed.
- The removal of cached bytes for photographs that went (`bytes?.remove(photoUUID:)`) follows each removal page.
- A source removed mid-walk is still the foreign-key failure that `refresh` handles today; with staging it surfaces at apply time rather than during the walk.

## Refresh and downloads on their own actors

- **The refresh** runs as one actor per source being walked, each with its own serial queue and database connection. `RunCommand.refreshing` (`RefreshGate`, behind an `NSLock`) becomes state on a coordinating actor.
- **The downloads** (`QueueFetcher` lanes, `FetchDeadline`) run on an actor with its own queue, or one per lane. `attemptCache`'s bare `UPDATE` moves inside a retried transaction, so contention waits instead of failing the download, as it did twice at 13:30:52.
- **The `NSLock`s** in `QueueFetcher`, `FetchDeadline`, `QueueFiller`, `SourceBench`, `PhotoStore` and `RunCommand` go with them, following the list in `Deadline.swift`'s TODO. `SystemPhotoLibrary`'s three are left for last, for the reason that TODO gives.

## What this leaves stale elsewhere

- `PLAN.md`, *The resize cache is removed*: reversed by Phase 2b once it is designed.
- `PictureClient` and `AgentPicture` doc comments describing the box.
- `Documentation/photogoroundd.md` stays accurate about `w`, `h`, `Accept` and `X-PGR-Pixels`; it may want a sentence saying no client in the project sends them.

# References

- `PLAN.md` — Phase 1.5.2 (the renderer), *The resize cache is removed*, and the decode measurement at line 194.
- `Sources/PhotoGoRoundAgentAPI/Support/Deadline.swift` — the TODO listing every `NSLock`.
- `Sources/photogoroundd/ConfinedDatabase.swift` and `SystemPhotoLibrary.Album` — the existing pattern for keeping blocking work off the pool.
- `Tests/PhotoGoRoundKitTests/RefreshWhileServingTests.swift` — the test that did not reproduce, and why.
- `Tests/PhotoGoRoundKitTests/SilentLibraryServingTests.swift` — the one-second check budget.
- The thread sample, 2026-09-16 13:31:39, saved only in the session's scratchpad.
