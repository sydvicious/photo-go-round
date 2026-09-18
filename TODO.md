# TODO

Things to look into, deferred out of the phase list. Each one earns its own plan document if and when it is picked up; nothing here is designed yet.

## Passed over on 2026-09-16 — to fix, not to keep

Syd, 2026-09-16: "i have no deadlines, and I hate tech debt surprises. I won't remember any issues you mention and bypass, so let's not bypass them." Every issue Claude mentioned during the agent performance work and did not fix is here. Strike each through when it is fixed.

- **Flaky tests, below: how to fix them.** Syd, 2026-09-16: "we fixed flaky timing tests at Indeed by using await Task {}.run." *Claude's reading: a test awaits the work it depends on rather than racing it against a clock.*
- ~~**Flaky test: `ServeWaitTests` "A card whose fetch fails during the wait is passed over for the new head".**~~ *Fixed 2026-09-16. Reproduced by letting the background fetch finish before serving: `waited()` was 0. The fetch now starts from the request's own `waiting` event rather than after a 200 ms sleep, and the other photograph is fetched first, so the one wait is the head's; the test asserts the whole lookup list, `[.miss(.leftDuringWait), .hit]`. `waitsAndServes` had the same 300 ms race and got the same fix. Ten runs of the suite and three full Kit runs passed.* Failed once in a full parallel run (`fixture.waited() == 1`), passed in five reruns — and failed again the same way in a full run at about 20:15. It races a background fetch started after 200 ms against the serve wait.
- ~~**Flaky test: `RequestBodyTests`, eight tests at once, "timed out waiting for the listener to bind a port".** Failed once in a full run, passed on rerun alone and in the next full run.~~ *Fixed 2026-09-16. Measured over three full runs of the agent's tests: every listener was ready at the first check, but the 10 ms `Task.sleep` before that check resumed 1.2 to 1.96 s late on a cooperative pool other suites were holding, and the loop's two-second clock then gave up without looking again. The tests now await the listener's `onReady` (`BoundPort`), and the suite has a one-minute `.timeLimit` so a listener that never becomes ready still fails. Replies were measured too — 0.25 s at most — so the two-second reply watchdog stays. Five further full runs passed.*
- ~~**Flaky tests, new: `EndpointCacheTests` "`Accept` decides the format when a rendering is produced", "A served picture's record times every step it went through" and "The console line carries what the cache holds and how deep the queue is".** All three failed together in one full run of the agent's tests on 2026-09-16, about 21:50, and passed in the next seven. Each asks for a sized picture through an endpoint that uses the process's shared `Resizer` and the production one-second `resizeBudget`. **Reproduced:** with another resize holding `Resizer.shared` for 1.5 s, the `Accept` test is served the original PNG instead of a JPEG. *Claude's reading: in a full parallel run other suites' resizes share that one resizer, or the pool starves the budget's timer, and the request serves the original. That the observed failure was this is inferred from the assertions that failed, not captured.* *Proposed, not decided:* test fixtures not about the budget give their endpoint its own `Resizer` and a budget no run can reach, so they await the resize instead of racing a clock.~~ *Fixed 2026-09-16 at Syd's "yes, fix it that way": `awaitingResizes()` in `Tests/photogorounddTests/AwaitedResizes.swift` gives the fixtures in `EndpointCacheTests`, `DashboardEndpointTests`, `DealPacingTests` and `RequestLogTests` their own `Resizer` and a 600 s budget, and those suites a two-minute `.timeLimit`; the one dashboard test about the budget sets the production budget itself. A new test holding `Resizer.shared` for 1.5 s fails without the fixture change and passes with it. Five full runs passed.*
- **Some photographs change on every refresh.** After Phase 4 was installed, 2026-09-16 22:24, two refreshes 20 seconds apart each wrote about 17 pages of Favorites (source 5) with one or two "changed" rows apiece; the probe's refreshes before it showed the same. Nothing about those photographs changed in between, so a storage or byte size is probably read differently each walk — a Photos asset whose size flips between known and unknown, say. Each costs a short lock (0–4 ms) and a needless write. Not looked into; the `REFRESH:` line does not name which rows.
- ~~**Serving's own writes held the lock too long.**~~ *Answered 2026-09-17: the LaunchAgent's `ProcessType` was `Background`, and macOS throttles a background job's disk I/O. With `Adaptive`, no transaction has held the writer 50 ms. See the startup item below.* In the `LOCK:` lines read for Phase 4's probe, 2026-09-16, from the agent before that night's install: `Deck.markShown` held the writer 1,641 ms (22:04:13), `Deck.register` 802 ms (22:09:54) and `Deck.claim` 658 ms (22:03:24) — each one small write, not a refresh. These are held times, with 0 ms waited, so not queueing behind another writer.
  - **Looked into, 2026-09-16 about 22:35, at Syd's "look into serving's slow writes next".** Three hours of `LOCK:` lines: `register` (single-row `UPDATE consumer SET seen_at`) up to 2,238 ms, `markShown` (two single-row updates) up to 1,641 ms, `claim` (one) 658 ms, `PhotoQueue.append` 192 ms, `releaseResidency` 362 ms — none of which a one-row statement explains. **None since the Phase 4 install at about 22:22.** No triggers in the schema; `journal_mode = WAL`, `synchronous = NORMAL`, SQLite's default automatic checkpoint.
  - *Claude's guess, not measured:* the automatic checkpoint, which runs inside whichever commit takes the log past a thousand pages and does sync, charged to that commit's hold. Refresh's upserts wrote far more pages before Phase 4, which would also fit their stopping — equally unmeasured.
  - **Probe added:** the `LOCK:` line now splits out the commit, `LOCK: held 812ms · commit 790ms · waited 3ms · …`. A slow line with a commit near its hold is the checkpoint, or something else inside `COMMIT`; one with a short commit is the statements. Tested in `LongLockTests`. `Agent Performance Overhaul.md`, *The probe, before designing further*.
- **The test run stalls the cooperative pool for up to two seconds.** Measured 2026-09-16 while fixing `RequestBodyTests`: a 10 ms `Task.sleep` resumed 1.2–1.96 s late in full parallel runs of the agent's tests. Not traced to which suites hold pool threads. The same shape as the agent's own pool starvation that afternoon, so the one lead from the flaky-test work that may matter outside the tests. Syd, the same evening, on flaky tests that expose no code problem: "are they really worth it?"
- **A test that asks the real Photos library: `SourceEndpointTests` "An album identifier that names nothing is refused at the door".** It posts a `photos_collection` source through the endpoint's default providers, which ask PhotoKit on whatever Mac runs the tests, under a time bound. It failed in two full runs while `ServingUnderLoadTests` froze the pool.
- ~~**The black screensaver, reported about 12:41.**~~ *Dropped — Syd: "don't worry about black screensaver."* "the screensaver is now service black". The log showed the saver put up a picture at 12:40:49 and its window closing 24 s later; nothing after. Never diagnosed.
- **Photos albums stay "not responding" for up to five minutes after the agent starts.** *Syd: "is worrying", then "diagnoising startup slowness requires its own sessions, so let's do those items later".* Left open, for its own session. At the 17:46 install both were marked unavailable at 17:46:14; Photos answered in 71 ms by 17:50; the label waits for the next scheduled refresh.
- ~~**The agent takes about two minutes from launch to listening after a restart.**~~ *Answered 2026-09-17: `ProcessType Adaptive` and Phase 6's launch index took the reboot-to-serving path from 3m52s–8m22s to about 70 s, of which ours is 1.9 s. What is left is launchd's own delay before starting the process, and about 19 s of macOS loading it.* *Syd: "is worrying", then "diagnoising startup slowness requires its own sessions, so let's do those items later".* Left open, for its own session. 12:37:56 → 12:39:58 and 16:31:12 → 16:34:34, each step logging tens of seconds apart. Not measured beyond that.
  - **Measured across a restart, 2026-09-17**, at Syd's "yes, restarting now". Rebooted 13:46, logged in about 13:47.
    - **13:49:52 the agent's process starts** — nearly four minutes after the reboot, over two after login. Before that, `launchd` answered "Could not find job with label com.sydpolk.photogoround.server" (13:47:35) and the app showed *Waiting for Photos*. The plist is in `~/Library/LaunchAgents` with `RunAtLoad`, and `ProcessType` is `Background`, which launchd is free to defer.
    - **13:50:28 the cache index is rebuilt**, 304 entries, 937 MB — about 33 of the 39 seconds between the process starting and the port opening. 100 ms a file is not a walk; the volume was probably still busy from the boot. Unmeasured either way.
    - **13:50:31 listening**, 13:50:56 first picture served.
    - **Photos was still not answering** at 13:51:05 ("library did not answer authorization within 10 seconds"), and served lines said sources were "unconfirmed" — the other item above.
  - **The listener opens after the cache index is rebuilt**, so nothing can connect for the length of that walk. Moving it earlier is the obvious fix and is not yet decided: serving before the index exists means the cache reports nothing held.
  - **Probe added 2026-09-17**, at Syd's "yes, add the startup timing lines": `STARTUP:` lines per step — `storage`, `open`, `migrate`, `cache index`, `wiring`, `listen`, then `sources` — each logged as it finishes, with a summary line at `listening` and at `ready`. `StartupTimes`, tested in `StartupTimesTests`. Read them after the next restart.
  - **With the `STARTUP:` lines, across a second restart, 2026-09-17.** Rebooted 13:57, logged in about 13:58.
    - **14:02:47 the process is exec'd** — 5m47s after the reboot. `backgroundtaskmanagementd` was still registering the launch item at 14:02:43, and `launchd` answered "Could not find job" to whoever asked at 14:02:42.
    - **14:04:36 the first line of our code runs** — 1m49s after exec, before `main` does anything. Nothing of ours is in that window: dyld and the launch-constraint check, with the whole machine paging in from a cold disk.
    - **Then 44.5 s to listening:** `storage 960ms · open 3656ms · migrate 424ms · cache index 39355ms · wiring 28ms · listen 51ms`. Sources took a further 610 ms.
    - **Boot to listening: 8m22s**, of which ours is the 44.5 s, and 39 s of that is the cache walk — 300 entries, 938 MB, the same walk that takes 137 ms warm. So it is the disk, not the walk.
  - **A fourth restart, 2026-09-17 15:37**, the first with everything installed: process at 15:37:47 (47 s after the reboot), first line of our code at 15:40:21 — **2m34s of pre-main** — then `storage 244ms · open 3182ms · migrate 353ms · cache index 16139ms · wiring 195ms · listen 207ms`, listening at 15:40:52. Boot to listening 3m52s.
  - **`ProcessType` changed from `Background` to `Adaptive`, 2026-09-17**, at Syd's "yes, change it to Adaptive". macOS throttles a Background job's disk I/O, which fits all three symptoms at once: the ~2 minutes of paging before `main`, the cache walk at 16–39 s against 137 ms warm, and one-row writes holding the lock for hundreds of milliseconds (`markShown` 715 ms at 15:41:08 with **commit 0 ms**, so the statements, not the checkpoint). `Scripts/install-agent.sh`.
    - **Measured after a restart, 2026-09-17 15:45.** Process at 15:47:04, first line of our code at **15:47:20.9 — 17 s of pre-main**, against 1m49s to 2m34s with `Background`. Then `storage 0ms · open 955ms · migrate 0ms · cache index 8900ms · wiring 18ms · listen 14ms`, listening at 15:47:32: **9.9 s of ours**, against 20–44 s. Boot to listening **2m27s**, against 3m52s to 8m22s.
    - **And no `LOCK:` line at all** in the twenty minutes since — no transaction held the writer 50 ms, where the same window before had them constantly, up to 70 s. So serving's slow one-row writes were the I/O throttle too, not the commit and not the statements themselves. `TODO.md`'s *Serving's own writes held the lock too long* is answered by this.
    - **What remains launchd's:** it still waited about two minutes before starting the process.
  - **Across four restarts:** launchd's delay before the process is 24 s to 5m47s; the pre-main window is 1m49s to 2m34s every time; ours is 20–44 s, and the cache walk is nearly all of it.
  - **A third restart, 2026-09-17 15:29**, with Phase 3 installed: process at 15:29:53 — **24 s after the reboot**, against 5m47s the time before, so launchd's delay varies widely; first line of our code at 15:32:11, **2m18s of pre-main**; then `storage 791ms · open 4791ms · migrate 2617ms · cache index 29909ms · wiring 228ms · listen 168ms`, listening at 15:32:55 and serving the app from 15:33:26. The cache walk is the only part of it that is ours to remove.
  - **The warm baseline, 2026-09-17 13:55:24**, the same build launched with the machine quiet, at Syd's "you might want to capture what startup looked like here": `STARTUP: listening after storage 0ms · open 6ms · migrate 0ms · cache index 137ms · wiring 1ms · listen 2ms · total 148ms`, then `sources 48ms`, `ready … total 197ms`. The index walk was 299 entries, 935 MB — the same walk that took about 33 s after the reboot at 13:49, so roughly 240 times slower with the disk still busy from the boot.
- ~~**`appintentsmetadataprocessor` prints "warning: Metadata extraction skipped, no AppIntents.framework dependency found"** in the `Photo-Go-Round Server` build. A tool's warning rather than a source warning, and never looked at.~~ *Syd: "fix that warning". Fixed: `LM_SKIP_METADATA_EXTRACTION = YES`; `Build Plan.md`, *The targets*.*
- ~~**Test runs write to the real unified log** under `com.sydpolk.photogoround`, as `swiftpm-testing-helper`, so a `log show` for the agent's lines shows test output mixed in.~~ *Syd: "fix that test logging". Fixed: `Log.subsystem` is `com.sydpolk.photogoround.tests` in `swiftpm-testing-helper`, `xctest`, or a process with `XCTestConfigurationFilePath`; the app, the saver and the wallpaper extension name `Log.subsystem` instead of the string. A full run afterwards left 0 lines under the agent's subsystem and 7,994 under `.tests`. `TestLoggingTests`.*
- ~~**`Build Plan.md` does not record the `pgr_ctl` target's `PhotoGoRoundDisplay` dependency**~~ *Done: `Build Plan.md`, *The targets*.*, added 2026-09-16 after that target failed to link when built after the agent. *Syd: "update build plan".*
- **Two Phase 2b choices built beyond what was decided, awaiting Syd:** ~~`pgr_ctl cache clear` clears resized copies in every scope~~ *kept — Syd: "pgr_ctl cache clear nukes everything. Why wouldn't it?"*; eviction runs every maintenance interval (30 s) rather than after each copy is written. *Syd: "since you are keeping track of the cache in the database, you should evict when you know the total size is too big, and not any other time."* `Agent Performance Overhaul.md`, *The resize cache, proposed*, *Built*.
  - **Syd, 2026-09-16: "ditch the timer. pgr_ctl will just call the method to do eviction (you do have one of those, right?), and will do nothing if everything fits in the cache."** The method is `PhotoCache.evictIfNeeded()`; `pgr_ctl cache evict` already calls it, and it already returns without evicting when originals and copies together fit under the ceiling. So `pgr_ctl` does not change. The timer is the `.maintenance` heartbeat in `RunCommand`, on `maintenanceIntervalSeconds`, and eviction is all it runs.
  - **Syd, 2026-09-16: "So, after you write any file to the cache, run evict()."** Asked whether the free-space guard noticing low disk space only at such moments was acceptable. *Claude's reading:* eviction runs after every file written to the cache — an original adopted by a fetch (`PhotoCache`, `store.adopt`) and a resized copy saved (`PictureEndpoint.keep`, the dashboard's thumbnail) — and at no other time: not at launch, and not when `cacheByteCeiling` changes, which Claude had proposed; the free-space guard is checked then too. `maintenanceIntervalSeconds` goes, with its row in `Documentation/photogoroundd.md`. Not built.
  - **Syd, 2026-09-16: "you might temporarily exceed the space, but that's fine".** The cache may sit over its ceiling between a write and the eviction after it, and over the free-space floor until the next write.
  - **Built 2026-09-16, at Syd's "yes, build it".** `PhotoCache.evictAfterWriting()` runs after a fetch adopts an original and from `PhotoCache.keep`, which both endpoints now keep copies through (`CopyPlace` carries what they need onto the resizer's thread). An eviction that finds another running in the process is skipped, not waited for (`PhotoStore.claimEviction`). The agent's reporter — dashboard tally, console line, `cacheChanged` — moved from the maintenance pass to a `PhotoCache.evicted` hook. Gone: the `.maintenance` heartbeat, `runMaintenance`, `maintenanceIntervalSeconds`. Docs: `photogoroundd.md` (the ceiling paragraph, `evictions`, the preference row) and `pgr_ctl.md` (`cache evict`; and `sources remove`, which still said a source's bytes waited for a maintenance sweep — stale since removal began deleting them at once). Tests: four new in `ResizedCopiesTests`, two in `DashboardEndpointTests`, each caught its own mutation; `ResidencyTests` "eviction releases the originals it took" rewritten, since its fetches now evict before its own call could. *`Agent Performance Overhaul.md`'s bullet marked reversed.*
  - ~~**Still saying "maintenance" in `PLAN.md`, not changed — Syd's to decide:** the dashboard section and the preferences table.~~ *Syd: "yes, update PLAN.md". Done 2026-09-16: *Eviction* gained a "When it runs" paragraph; the dashboard's *Evictions*, its ceiling paragraph, the connection-per-request paragraph, the preferences table and the wedged-Photos TODO's refresh-walk bullet now say eviction follows each write, with the maintenance wording dated.*

## Two in five sized requests give up on their resize

Measured 2026-09-17, over three hours of ordinary use with the app and the wallpaper running: of 640 pictures served, **245 gave up after the one-second budget and sent the original**, and 394 were resized in time. That is steady state, not the cold minute after a restart.

- **What it costs:** a wasted second per request, an unresized picture at the client, and no copy in the resize cache — so the same photographs pay it again.
- **Not yet known:** whether the HEIC encode is genuinely that slow per picture, whether resizes are queueing behind each other on the one `Resizer`, or whether a one-second budget is simply too tight for a 3,000-pixel original. `ServiceTiming.resizeBudget` is the number; `Agent Performance Overhaul.md`, *When the resizer stalls*, is why it exists.
- **A `TIMING:` line already separates `resize wait` from `render`**, so the queueing question can be answered from the log rather than by guessing.
- **Not the cause, checked:** `IOSurface creation failed: e00002c2` (`kIOReturnBadArgument`) from Apple's HEVC encoder — 77 bursts in the same three hours, only 26 of them within two seconds of a give-up. Noise from the encoder's own setup; nothing of ours calls it, and pictures come out either way.

## Track RAM usage

Syd, 2026-09-17: "I also want a task setup every this you ask me to reboot the agent where you record how much ram it is using first. Basically I want a running tally to make sure that there are no leaks from the agent, the screensaver agent, or the wallpaper extension."

- **Planned in `Plans/Track RAM Usage.md`**, drafted the same day. How it is recorded is not decided — Syd: "We will brainstorm on how later."
- **The rule as given:** before asking Syd to reinstall or reboot anything, sample each process's memory first, and keep the numbers where a trend can be read.
- **First samples, 2026-09-17 16:18:** the agent 113 MB after 9 minutes; the wallpaper extension 53 MB after 9 minutes. The screensaver was not running.

## A fixed service port

Syd, 2026-09-17: "Perhaps we had better actually pick a port and hardcode it. this dynamic port stuff is causing problems."

- **Phase 1 built and installed 2026-09-17.** Three numbers, one per build variant — release 9427, Syd's Debug 9428, an agent's build 9429 — chosen by a compile-time condition, and a refused port is fallen back from rather than failed on. `Plans/Service Port Plan.md`.
- **Still open:** Phase 2, the clients trying the fixed port first — which is the half that removes the *waiting for the agent* window. Then what the discovery dance leaves behind, and what a second user's agent binds.
- **What prompted it:** across five reboots the agent took a different port each time (56333, 58192, …), and the app showed *waiting for the agent* until it re-read the published value.
- **Also noticed in the same window, not acted on:** for about a minute after a restart every request logged `RESIZE: gave up after 1000ms`, so the app was served originals while the HEIC encoder was cold. That is Phase 2a working as designed; worth knowing it lasts a minute.

## `pgr_ctl` in Xcode

Syd, 2026-09-16: "add a target for pgr_ctl to the Xcode project".

- **The target is already there:** `pgr_ctl` in `app/Photo-Go-Round.xcodeproj`, which `Build Plan.md`, *The targets*, records, and which gained its `PhotoGoRoundDisplay` dependency on 2026-09-16.
- **What is missing is a shared scheme.** `app/Photo-Go-Round.xcodeproj/xcshareddata/xcschemes/` has Install Agent, Install Screen Saver, Install Wallpaper Extension, Photo-Go-Round, Photo-Go-Round Wallpaper and Photo-Go-Round Wallpaper Host, and no `pgr_ctl`. Whether Syd's Xcode shows an automatic one is not known; `README.md` tells him to `swift run pgr_ctl` instead.
- *Not decided:* whether it is only a shared scheme to build and run it, or also an install — `Build Plan.md`, *The install phases*, lists `pgr_ctl` among the two products with no dev install yet.

## Build and install as separate steps, so ⌘B builds and ⌘R runs

Syd, 2026-09-16: "we should think about separating build and install for everything, so command-b builds and command-r runs. but that can go in TODO.md; we don't need to do that now".

- **Today a build installs.** The `Install Agent`, `Install Screen Saver` and `Install Wallpaper Extension` schemes build an aggregate target whose script installs, so ⌘B on one of them boots out the agent, replaces the saver, or registers the extension. `Build Plan.md`, *Design Decisions*: "Installing is a build phase, not a script's job" — this would revise it.
- *Claude's reading, not decided:* ⌘R — a scheme's Run action, or a pre-action on it — does the install and starts what it installed, and ⌘B only builds.
- **Xcode registers every host app it builds**, install or not, so ⌘B alone still registers the wallpaper extension. `Wallpaper Plan.md`, *Debug builds under their own identity*, is what keeps that from replacing the chosen wallpaper.

## A section of our own for the screensaver in System Settings

Syd, 2026-09-16: "Is there a way to have a custom section for our screensaver?" — asked while the wallpaper's development builds were being put in one *Photo-Go-Round* section in the Wallpaper pane.

- **Not looked into.** What is known, from the wallpaper work: the `.saver` is listed by System Settings itself, and `WallpaperAgent` hosts it as `ScreenSaverWallpaper` with provider `com.sydpolk.photogoround.saver`. The wallpaper extension's section *did* appear in the Screen Saver list on 2026-09-15, so an extension on `com.apple.wallpaper` can put a section there — `Wallpaper Plan.md`, *The real extension, inside the app*, the Screen Saver list notes.
- *Claude's reading, not measured:* a custom section probably means the screensaver answering the pane as an extension, as the wallpaper does, rather than as a `.saver` bundle.

## The tag line: "Your photos, shuffled"

Syd, 2026-09-16: "change the tag lines for both wallpaper and screensaver to "Your photos, shuffled"."

- **The wallpaper's** is the pane item's `localizedDescription` in `app/wallpaper-extension/Sources/PaneModels.swift`, now "Photographs from your library, shuffled".
- **The screensaver has none in its sources.** A search for the wallpaper's wording and for "your library" and "your photo" under `app/` finds no description for the `.saver`; where System Settings would show one for it is not known.

## Statistics about resized copies, where they belong

Syd, 2026-09-16: "put statistics about the cached resized picture where appropriate".

- **Today nothing counts them apart.** `PhotoCache.status()` folds copies into `bytesOnDisk` with the originals, so `pgr_ctl cache status` and the dashboard show one total. No count of copies, no bytes for copies alone, no hits or misses on the copy lookup, and eviction's tally does not say how many of what it took were copies (`LaunchTally.Evictions`). *Already there:* a request's `TIMING:` line names its stage `resized copy`, `render` or `resize gave up`, so one request says which it was; nothing adds them up.
- *Claude's candidates, not decided — where each would go is Syd's:*
  - **`pgr_ctl cache status`**: copies held and their bytes, beside originals.
  - **The dashboard's cache panel** and `/v1/dashboard`: the same, and copy hits against resizes since launch — the number that says whether the resize cache is saving the resizer anything.
  - **Evictions**: copies and originals taken, separately.
- Anything added to the dashboard or `pgr_ctl` is documented in `Documentation/photogoroundd.md` or `pgr_ctl.md`, and tested.

## The dashboard's "Served since launch" list

Syd, 2026-09-17: "why is `system-wallpaper` gray? And you should only show tags you actually find; we will never have raw `wallpaper` again."

- **Why it is gray.** `dashboard.js` keeps `const named = ["wallpaper", "screensaver", "app"]`. Those three are always drawn, at zero if nothing asked; every other tag found in the answer is appended with class `minor`, and `dashboard.css` has `tr.minor td { color: var(--muted) }`. So the grey means "a tag I was not expecting", which is a distinction nobody asked for.
- **`wallpaper` is dead.** The extension identifies itself as `system-wallpaper`; nothing sends the bare tag any more, so the row is a permanent zero.
- **What to do**: draw the tags actually present, and drop the `named` list and the `minor` styling with it. Whether the order stays fixed or becomes the count is Syd's.
- Wherever the consumer tags are written down — `Documentation/photogoroundd.md` — says the same set.

## An Options button for the screensaver

Some savers show one in System Settings. `ScreenSaverView` provides it through `hasConfigureSheet` and `configureSheet`, both of which `PGRScreenSaverView` currently answers `false` and `nil`.

- **The blocker to establish first is where a setting would be written.** The Phase 1 spike found the saver cannot even *read* the agent's preference domain from inside `legacyScreenSaver`'s sandbox — `UserDefaults(suiteName:)` returns a suite that opens cleanly and is empty. It certainly cannot write one. *Answered 2026-09-16: through the agent, over HTTP. See* Settings inside the wallpaper extension and the screensaver bundle *below.*
- **The available route is the agent.** Every other client changes things over HTTP; a settings endpoint does not exist yet. See `PLAN.md`, *The database is private to the service*.
- **Whether the sheet is presented at all is untested.** `hasConfigureSheet` is queried — it appears in the call sequence on `FB9835060` — so the button probably shows. Whether the sheet displays is unknown, and the preview instance being 0x0 is a reason to check rather than assume.
- **What would go in it** is also open: dwell, fit, an upscale cap. All are `PLAN.md`'s *Beyond 0.1* today, and *Everything user-settable is a user default* is held back with them.
- **Parked until there is a real setting**, which means until *Settings endpoints* below exists. A sheet with nothing configurable in it is a button that disappoints.
- When it is built, it can hold what needs no persistence even before then: agent status, the port and whether it was found through the suite or the file, the version, and the same pointer to the app's Settings panel that the empty state now shows.

## The icon in System Settings

The saver's tile in the Screen Saver pane is the system's generic placeholder — a blue swirl. Confirmed by screenshot 2026-09-09, with Photo-Go-Round selected under **Other**.

- The convention is `thumbnail.png` and `thumbnail@2x.png` in `Contents/Resources`, with `COMBINE_HIDPI_IMAGES` disabled so the two are not merged. No `Info.plist` key is involved.
- **Unverified on macOS 27** — the reference is older than Sonoma's System Settings rewrite.
- Blocked on there being an app icon at all, which does not exist yet.
- **Distinct from the large preview at the top of the pane, which is fine.** That one is a live instance of the saver showing the real library — the same screenshot has a photograph in it. Only the tile is generic. *An earlier version of this note called that preview a captured still; it is not, and the correction is in `Screensaver Plan.md`, `The preview is live, and it is an ordinary instance`.*
- So the two are supplied differently: the preview draws itself, and the tile is an image the bundle has to carry. Nothing we do to the saver's drawing will change the tile.

## Sandboxing, and whether the App Store is reachable

`PLAN.md`'s *Platform and distribution* says Developer ID direct, on the grounds that "a sandboxed app cannot install a `.saver` bundle, so App Store distribution and a screensaver are mutually exclusive." That is the decision to re-examine rather than the answer.

- **Answer this first, because it ends the item if it is no:** is there any App Store-legal mechanism in 2026 for an app to deliver a screensaver? If not, the rest is moot and the note stands.
- **The agent is the harder half, not the saver.** It is unsandboxed by design: it opens SQLite and the cache directly, binds a localhost listener, holds the Photos TCC grant, and registers as a LaunchAgent through `SMAppService`. Sandboxing it means an App Group container for the database and cache, `com.apple.security.network.server` for the listener, `network.client` for everything that asks, and re-testing every path that touches a file. *2026-09-10: it registers as a per-user plist in `~/Library/LaunchAgents`, not through `SMAppService`.*
- **`pgr_ctl` is not a constraint here.** It is a debugging tool and need not ship at all, so a sandboxed build simply leaves it out and it keeps the direct database access that is the rig's whole premise. The consequence worth knowing is that the shipped configuration would then be one nothing exercises from a terminal — a fact to hold, not a problem to solve.
- Worth noting the widget already forces part of this: an app extension is sandboxed on macOS whether we like it or not, which is why the agent serves over HTTP rather than sharing a store.
- **The wallpaper's files would move.** They are in `~/Library/Application Support/com.sydpolk.photogoround.wallpaper.{dev|prod}/` for now; Syd, 2026-09-10: "we will probably have to move it if we want to sandbox." See `Wallpaper Plan.md`, *The file on disk*.
- **The animated-preview item that was here is withdrawn, 2026-09-09: we already have one.** It said that if the App Store were unreachable, private API would be on the table for getting a fully animated preview like Apple's own savers have. The premise was a wrong reading — the pane runs an ordinary live instance of our saver and it animates and cycles photographs. Nothing needs reverse-engineering. The general point survives in a smaller form: shipping Developer ID direct means no review, so private API is not disqualifying if some *other* need for it appears.

## Installing by launching the app

Installing Photo-Go-Round should be the whole of installing Photo-Go-Round. **Needs its own plan document.**

- **The agent half is already designed** and not built: `app/mac/FEATURES.md`, *The app brings its own agent* — `photogoroundd` inside the app bundle at `Contents/Library/LoginItems/`, registered with `SMAppService.agent(plistName:)`. See also `PLAN.md`, *An installer is probably unnecessary*. **Changed 2026-09-10:** the agent installs as a per-user plist in `~/Library/LaunchAgents`, with the binary left in the app bundle — "this needs to support multiple users on the same machine."
- **The saver half is not designed at all.** An unsandboxed Developer ID app can copy `Photo-Go-Round Screensaver.saver` into `~/Library/Screen Savers` itself, which is what `Scripts/make-saver-bundle.sh --install` does today by hand. *The bundle was `Photo-Go-Round.saver` until 2026-09-15.*
- **Selecting it is probably not ours to do.** Installing a screensaver and making it the user's screensaver are different acts, and the second one is theirs.
- **Updating is the part that bites.** `legacyScreenSaver` caches the loaded bundle for the life of its process and System Settings caches its list, so replacing an installed saver means killing both — the script already does this, and an app doing it silently to a running screensaver needs thought.
- **Decide which deployment a shipped app runs in.** The app and the saver both ask for `.development` today; a shipped one must not.
- **The window needs Install Agent and Launch Agent buttons.** Syd, 2026-09-09. They are what the empty state should offer when nothing is being served, rather than words.
- **The empty state's agent wording is a placeholder that is wrong in one of the two places it appears.** It reads "Open the Photo-Go-Round application to start it", which is right on the screensaver and absurd in the window, because the window *is* the application. The buttons above are what the window should show instead. Until then the text stands, knowingly.
  - **Changed 2026-09-16.** Syd: "fix the wording. it's stupid." Now "Waiting for Photos" with nothing underneath, in the window, the screensaver and the About box. Launchd starts the agent at login, so "open the app to start it" was wrong on the screensaver too, and an agent still starting up is not "not running". The buttons are still what would go underneath.
- **A missing agent and a wedged one are one state to the user** — implemented 2026-09-09, one message on screen and the distinction kept in the log. The buttons inherit that: whatever they offer has to cover both starting an agent that is not there and dealing with one that is running and not answering.
- **The first run has a race nothing has exercised.** The saver finds the port by reading `~/Library/Preferences/<domain>.plist` directly, because the sandbox will not hand it the domain. On a genuinely first launch that file may not exist yet, and `cfprefsd` buffers writes, so there is a window after the agent starts where the saver still says nothing is running. It self-heals on the next request; whether that is acceptable as somebody's first impression is a first-launch decision. See `Screensaver Plan.md`, *Not yet decided*.

## A menu-bar app for shipping

Syd, 2026-09-10: *"make a menubar app for final shipping of this. The full desktop app is useful, but we are probably not going to ship it."* **Needs its own plan document.**

- **The window stays**, as the development instrument it already is — `PLAN.md`, *The Mac app as instrument panel*. It just probably is not what ships.
- **Everything that currently hangs off the app needs a home in it**: the Settings panel for sources, the Install Agent and Launch Agent buttons from *Installing by launching the app* above, the wallpaper's pause control, and the About box.
- **The empty state's wording points at "the Photo-Go-Round application"**, which would then mean the menu-bar item.
- **It may be the wallpaper's host, or sit beside a separate wallpaper binary.** `Wallpaper Plan.md` Phase 2 expects the wallpaper to be its own binary, installed per user in `~/Library/LaunchAgents`; a menu-bar app is the other common shape for a rotator. Which one runs the wallpaper is decided there.
- How it starts at login — a login item, or a per-user LaunchAgent like the agent — is open.
- `app/mac/FEATURES.md` already sketches *A menu bar app* — a status item, and an item that brings the window up — and is where this starts.

## A wallpaper bundle, so the wallpaper runs without the app

Syd, 2026-09-14: *"we need a TODO in the app to setup a wallpaper bundle like the screensaver bundle so the wallpaper will work without the app running and so that the user can run it without running the app."*

- **Already planned as `Wallpaper Plan.md` Phase 2, *Its own binary*, and not designed.** What is settled there: a per-user plist in `~/Library/LaunchAgents`, with the binary staying inside the app bundle, the same shape as the agent.
- **"Like the screensaver bundle"** suggests the same pieces: an Xcode target, and a `Scripts/make-wallpaper-bundle.sh --install` beside `make-saver-bundle.sh` and `make-agent-bundle.sh`.
- **The loop does not move.** `Wallpaper` is in `PhotoGoRoundDisplay` precisely so a second host is new code around it rather than a move; `AppDelegate` is the whole of the app's host today. *2026-09-16: the loop is removed, not moved. The wallpaper is the extension, `app/wallpaper-extension`, which runs without the app; this item is answered by it. `Wallpaper Plan.md`, *The app's loop, removed*.*
- **Its settings already live where a separate process can read them.** The *Also set wallpapers* checkbox and the *Shuffle All* choice are in `com.sydpolk.photogoround.wallpaper.{dev|prod}`, not in the app's domain. The checkbox is to stay "until we have a standalone wallpaper binary" (`app/mac/FEATURES.md`, *Time between pictures*), so what the Wallpaper panel offers once this exists is open. *Answered 2026-09-16: the checkbox is gone, and the panel offers the *Shuffle All* row, which times the extension.*
- **Two hosts must never run the loop at once.** If the app and the bundle both run it, each display is asked for twice, and two cards are spent where one is shown. Handing the loop over has to be designed, not left to chance.
- **Open, from `Wallpaper Plan.md`:**
  - whether it is a bare executable or an `LSUIElement` bundle;
  - whether it has a menu-bar item, which is where a pause control would go;
  - how it is installed, updated, started, and stopped once quitting the app no longer stops the wallpaper;
  - whether the menu-bar app (*A menu-bar app for shipping* above) hosts it instead.

## Metrics in the database

Serve counts and timings belong in the deck, not only in the unified log. **Needs its own plan when it is picked up.**

- **The 2026-09-08 overnight run is the argument.** The screensaver's own per-photograph line is `.info`, which is memory-only, so it had evaporated by morning; the run could only be counted because the *agent's* serve line happens to be `.notice`. `Log.swift` says this outright — "state transitions worth reconstructing after the fact must be `.notice` or higher" — and the count that mattered was on the wrong side of it. The saver's line is still `.info` today.
- Raising that line to `.notice` is the cheap alternative and a poor one: ~3,400 lines a night of something entirely routine, burying the lines that are not.
- **There are hooks already.** The `consumer` table carries a `seenAt` heartbeat, and `pgr_ctl` already runs the deck's statistical checks — so there is a place to write and a rig to read with.
- Worth recording: serves per consumer per interval, latency, cache hit or miss, non-200s, and what the queue depth was at the time.
- **The cost is a migration and a write on the serve path**, which is the hot path — 3,034 serves in nine hours from one surface, and every surface shares it.

## The dashboard over HTTPS

Syd, 2026-09-14: *"add a TODO item to have the dashboard accessible via https"*. Nothing is designed. `PLAN.md`, *The agent's dashboard*, is what exists.

- **The listener is loopback only, and that is marked settled.** `HTTPListener.start` sets `requiredInterfaceType = .loopback`, because "nothing off this machine has any reason to reach this listener." Loopback traffic never leaves the machine, so HTTPS there protects nothing on the wire. **So first decide what this is for.** If it is to reach the dashboard from another machine, that reverses the loopback decision, and the reversal gets recorded in `PLAN.md`.
- **One listener serves everything.** The dashboard's routes sit beside `/v1/next`, the source routes, and `/v2/photos`. Either TLS covers every client, and `PictureClient`, `pgr_ctl`'s `InspectCommands`, and the screensaver's port discovery all change, or the dashboard gets a second listener of its own.
- **The certificate is the hard part.** `NWProtocolTLS.Options` needs a `sec_identity`. A self-signed one gets a browser warning unless it is trusted in the keychain, and the agent takes a new port on every launch. Where the identity comes from, where it is stored per deployment, and who trusts it are all open.
- **Anything off the machine needs authentication too.** The same listener accepts `POST`, `PATCH`, and `DELETE` on sources. Encryption alone would let anyone on the network change them.
- The About box builds its link as `http://localhost:<port>/dashboard` (`DashboardLink`, pinned by `DashboardLinkTests`), and the agent prints the same address at launch. Both follow whatever is decided.

## Settings endpoints, and preferences as a black box

The agent should answer for its own configuration over HTTP, and its preference domain should stop being something clients read or write. Syd, 2026-09-09: *"We need to add settings endpoints anyway; the agent's preferences should be a black box."* **Needs its own plan.**

- The shape is already set by `PLAN.md`'s *The database is private to the service* — this is the same argument applied to the other durable store. `GET` and `PATCH` alongside `/v1/sources`, and no client touching the domain.
- **One thing has to be designed rather than assumed: how a client finds the agent.** `ServicePort` reads `servicePort` out of the domain, and from inside the screensaver's sandbox reads the `.plist` as a file, precisely because a client cannot ask the agent where the agent is. Sealing the box without answering that breaks every surface at once. Either the port stays a deliberate hole in it, or discovery moves to some other mechanism.
- **It reverses a stated position and that should be recorded in `PLAN.md` when it happens.** *Preferences* there treats `defaults write` as a first-class interface — "two rules follow from `defaults write` being a first-class interface" — and that is what a black box takes away.
- `pgr_ctl` keeps its direct access, as the rig rather than a client. Same exception it already holds for the database.
- The screensaver's Options sheet is the first thing that needs this, and the reason it is parked above.

## Settings inside the wallpaper extension and the screensaver bundle

Syd, 2026-09-16: *"explore putting settings directly into both the wallpaper extension and the screensaver bundle."* Today settings change only in the app or through `pgr_ctl`. Nothing is designed.

- **The wallpaper half is already Syd's named next stage.** 2026-09-15: "The next stage would be to put a sources panel and timing slider directly into the extension." `Wallpaper Plan.md`, *The real extension, inside the app*.
- **The saver half is *An Options button for the screensaver* above**, and inherits everything open there.
- **The two routes into System Settings are unlike each other.** The saver's is public: `hasConfigureSheet` and `configureSheet`, a sheet of our own. The wallpaper's is the private one the extension already uses: the pane draws whatever the extension answers to `WallpaperAgent`'s `provideSettingsViewModels`, and the extension can call back with `updateSettingsViewModels`, read from Phosphene and not yet called by us. Whether those view models can carry a slider or a list, rather than a section and its items, is unknown and the first thing to find out.
- **The extension should have read-write to its own preferences.** Syd, 2026-09-16. Its own domain is `com.sydpolk.photogoround.wallpaper.{dev|prod}`, where the *Shuffle All* choice lives. Today it reads that domain through `temporary-exception.shared-preference.read-only`, and `Rotation.swift` says a slider "replaces the reading, not the writing". That line goes when this is done.
- **The screensaver should have read-write to its preferences.** Syd, 2026-09-16. **The obstacle is that the saver has no entitlements of its own.** It runs inside `legacyScreenSaver`, under the host's sandbox, and the host names no exception for our domains; that is why the suite reads empty and the port is read from the `.plist` as a file. `Screensaver Plan.md`, *The question the entitlements do not answer*.
  - **Decided, 2026-09-16: over HTTP to the agent.** Syd: "the saver can use http to the agent to read and write prefs." So the saver's half waits on *Settings endpoints* above.
  - Open: where the agent keeps the saver's preferences — its own domain, or a saver domain of their own the way the wallpaper has one.
  - Not taken: `ScreenSaverDefaults`, which is writable but lands in the host's container where the app and `pgr_ctl` would not see it; and an App Group suite, which needs the saver embedded in the app's bundle.
- **Sources are the agent's either way.** They are in the database, not a preference domain, so a sources panel in either surface goes through `/v1/sources`.
- **One design, or two.** Whether both surfaces share one settings model, or each keeps its own, is open. The saver's dwell and the wallpaper's *Shuffle All* interval are different settings today.
- **What becomes of the app's Settings window** once a surface configures itself: whether it keeps the same controls. The app and the extension would both write the wallpaper domain, so the last write wins, and each has to notice the other's change.

## Design the wallpaper

`PLAN.md` Phase 7. **Needs its own plan document.** **Planned in `Wallpaper Plan.md`, 2026-09-10**, which settles most of what is below; the entries are left as they were written, with corrections marked. A good deal of it is already argued there and should be read before anything is designed: *Wallpaper mechanics and their limits*, and *Wallpaper is asserted continuously, never set once*.

- **What is already settled there**: `NSWorkspace.setDesktopImageURL(_:for:options:)` per `NSScreen`, with fill mode in the options dictionary; the wallpaper is an invariant that is re-asserted rather than set once, because macOS reverts it on its own; reassert on wake, screen-parameter changes, Space changes, session activation and agent launch; do not fight a user who sets their own; log every correction; and rotation on a `DispatchSourceTimer` checking wall-clock so it survives sleep. *2026-09-10: the fill colour is left to System Settings; putting files back is limited to launch, display and Space changes for now; the timer became per-display stored change times.*
- **The empty state is different from every other surface's**: leave the existing desktop alone. An empty deck is not a reason to vandalise somebody's desktop.

**What is genuinely open, and the first one is the interesting one:**

- **Wallpaper needs a *file path*, and no other surface does.** Every consumer so far is handed bytes over HTTP and draws them; `setDesktopImageURL` takes a URL the system reads, and keeps reading, for as long as that image is the desktop. So this surface needs a stable file on disk that outlives the request — the cache has one, but the cache is a staging area the deck is free to evict.
- **Decided, 2026-09-09: it writes its own, one file per display, in the container.** The wallpaper fetches an image per display and writes each to its own file — **deployment-scoped, alongside the database**, rather than at any hardcoded path. So `<container>/wallpapers/` : `~/Library/Containers/com.sydpolk.photogoround/wallpapers/` in production, `.build/pgr-container/wallpapers/` in development, and wherever `--container` or `PGR_CONTAINER` points when either is given. **Location reversed 2026-09-10:** "the app should not need to see the agent's container." The files live in `~/Library/Application Support/com.sydpolk.photogoround.wallpaper.{dev|prod}/`. One file per display, named by its UUID, scoped by deployment and never swept — all of that stands.
  - **It takes the cache's eviction out of the question entirely** — the wallpaper owns the bytes it is displaying, so nothing the deck does to the cache can pull the desktop out from under it.
  - **The file name carries the display's UUID**, which is the identity the deck already keys a consumer on and the same one `PictureLayerView.identifier(of:)` produces.
  - **Being deployment-scoped is the point, not a detail.** The database, cache and preference domain already move together so a development run cannot touch a real library; a hardcoded path would have let a development agent overwrite the wallpapers a production one was displaying.
  - `HostEnvironment` already vends `databaseURL` and `cacheRoot`; this is a third of the same kind, and resolving it there rather than at the call site is what keeps the deployment split honest. *Reversed with it: `HostEnvironment` gains nothing, and the wallpaper resolves its own directory from the deployment.*
  - **The files must outlive the process that wrote them.** macOS keeps reading whatever the desktop image URL points at, so anything that tidies them up blanks the desktop — they are not cache and must not be swept like it.
- **Who owns the loop.** Phase 7 says "scheduled by the server". The agent is unsandboxed and already holds the bytes, so it can call `NSWorkspace` itself — but that makes the agent a consumer of its own queue rather than purely a server, which is a shape change worth arguing rather than assuming. The alternative is a client like every other surface, which then hits the file-path problem above from the wrong side of the wire. **Answered 2026-09-10: a client.** Syd: "The agent's job is just to serve pictures." The file-path problem goes away because the client owns its files.
- **Its rate is nothing like the screensaver's.** Hours rather than ten seconds, against a shared queue that a long screensaver session can roll the whole library through — `PLAN.md` already accepts that the wallpaper therefore sees a near-random sample rather than a slow walk, and that is worth confirming still reads as correct once it is running.
- **Per-Space is a known hole**: the call sets the current Space on that screen only, and there is no public API to enumerate Spaces. The mitigation on record is re-applying on `activeSpaceDidChangeNotification`. *2026-09-10: re-applied at launch and on display and Space changes.*
- **A pause control** is named in `PLAN.md` as the obvious way to stop us reasserting; where it lives — Settings panel, menu bar — is not decided. *2026-09-10: the app's* Also set wallpapers *checkbox is the first way to stop it; whether a separate pause is still wanted is open in `Wallpaper Plan.md`.* *2026-09-16: the checkbox is gone with the app's loop; choosing another wallpaper in System Settings is how the extension stops.*

## What System Settings › Wallpaper needs from us

Syd, 2026-09-10: *"Add a TODO.md item to see what we need to do in System Settings -> Wallpapers."* Nothing is known yet; these are questions to answer by looking, on macOS 27, since the pane was rewritten in Sonoma.

- **What the pane shows once we have set a file** — our picture as a custom photo, the file's name, something else — and whether anything it offers would quietly undo us.
- **Its own rotation.** If the pane is set to change the picture on a schedule, `WallpaperAgent` rotates on its own and the two would fight. Whether setting a URL turns that off, or the user has to.
- **The fill colour.** The wallpaper uses the colour chosen here: where it lives in the pane on 27, and whether it is per display or per Space. See `Wallpaper Plan.md`, *The fit*.
- **Showing on all Spaces.** Whether the pane has such an option on 27, and whether it reaches a file set through `setDesktopImageURL`. If so it could do more for the per-Space hole than re-applying on every Space change.
- **Dynamic and Aerial wallpapers.** What happens when one is selected and we set a still over it, and whether it comes back on its own — a candidate for the reversions `PLAN.md`'s *Wallpaper is asserted continuously* describes.
- ~~**What the user should be told**, if anything, when *Also set wallpapers* is ticked.~~ *Gone with the checkbox, 2026-09-16.*
- Whatever this turns up goes into `Wallpaper Plan.md` before its Phase 1 is built, since several of these could change what Phase 1 does.

## Removing every source leaves the window showing a photograph

Observed 2026-09-09. Remove all sources and the agent does the right thing — it has nothing to serve and answers `204`. The window keeps the last photograph up indefinitely, and the Settings panel is meanwhile showing the empty list correctly.

- **Quitting and relaunching shows *No Photos Available* immediately**, which narrows this to one line of state. A fresh `Shuffle` starts with `shown` nil, takes its three empty answers, and says so; the old process was only holding the photograph because `shown` is never cleared once it has been set. So the agent is genuinely answering `204`, the cache is not involved, and nothing needs to be discovered — the window is showing a value it already has no reason to keep.
- **The rule doing this is deliberate**, and it is the deck's first duty: *a picture already showing is never taken down*. `Shuffle` keeps `shown` through an empty answer so a slow or absent agent never blanks a surface. It is why the screensaver survives a wake, and it should not be weakened generally.
- **It is already a known shortcoming**, in the general form: `PLAN.md`, *Deferred: retracting a photo already on screen*, and *Known shortcomings* item 6 — 0.1 ships accepting that a photograph can linger on a surface after it is gone.
- **But this case is worse than the one that was accepted, and for a reason worth writing down.** The deferred case is a photograph deleted somewhere else, where the client cannot know. Here the person removed the sources *themselves*, in this app, through this app's own panel — and one window of it is showing an empty list while another shows a photograph from a source that no longer exists. Nothing is stale except the screen, and the process that made the change is the process still displaying the old answer.
- **It therefore does not need the revocation protocol to fix.** `FEATURES.md` already draws this distinction under *One window telling another is not a doorbell*: a change *this app just made* is narrower than a change the agent announces, and the picker already tells its own windows. The empty state exists now, so the window has somewhere to go.
- Open: what "the sources went away" should look like. Straight to *No Photos Available* is honest and abrupt. It also wants deciding whether removing the *last* source is special or whether any change that empties the pool should do it.

## The empty state is sized for the view, not for how it is shown

Observed 2026-09-09 in the System Settings preview: the words are legible and the line underneath them is not.

- **`EmptyStateView` fits the font to its own bounds**, which is right for a window and for a full screen and wrong here. The settings preview is a view of 1800x1169 that the pane then scales down into a thumbnail a few hundred points wide, so a font sized for 1800 points arrives at a fraction of that.
- **The view cannot tell.** Nothing in `NSView` reports that an ancestor is scaling it, and the frame it is given is the pre-scale one. `convertToBacking` reports the backing scale, not a parent's transform.
- Worth checking before designing anything: whether the window's `backingScaleFactor` or the layer tree's accumulated transform exposes the reduction, and whether the pane scales the *view* or renders it and scales the image.
- The blunt alternative is to stop fitting to the width and use a size relative to the *display* rather than the view, which is what `PLAN.md`'s *The empty state* originally asked for — "a `CATextLayer` sized relative to the screen, on the order of an eighth of the width". That trades a preview that reads for a window that may not.
- Also worth deciding while in there: the second line is 0.34 of the first, which is a ratio picked by eye and never tested at small sizes.

## Nothing is on screen for the first ten seconds of an empty library

Observed 2026-09-09, in all three views. On a first launch with no pictures, the surface is blank for several seconds before *No Photos Available* appears.

- **The delay is deliberate and the blankness is not.** `Shuffle` says nothing until it has had three consecutive empty answers three seconds apart — about ten seconds — because one `204` is a queue turning over rather than an empty library, and saying so and taking it back reads as a flicker that tells nobody anything. But during the streak both `shown` and `trouble` are nil, so there is literally nothing to draw.
- **`PLAN.md` asked for this and it was deferred.** *The empty state* names three cases and says the third — "photos exist but none are cached yet", the transient cold start — "should say something like 'Loading photos' so a first run does not look broken."
- **It needs no change to the wire.** The service cannot tell a cold start from an empty library; both are `204`. But `Shuffle` already counts the streak, so *not yet sure* and *certain* are distinguishable on this side: show the launching words from the first empty answer and replace them at the threshold.
- **Do not show it instantly.** A healthy start returns a photograph in a couple of hundred milliseconds, so anything drawn immediately would flash on every launch. It wants a short beat before it appears — which is a third timing to pick, alongside the dwell and the empty interval.
- Open: the wording. Syd asked for "Launching…"; `PLAN.md` suggested "Loading photos". Also whether it covers the interval before the *first* answer of any kind arrives, including the no-agent case, or only empty ones.

## Where the `-Xcc` module cache comes from

A directory named `-Xcc` appeared inside `app/Photo-Go-Round.xcodeproj`, holding ~2,400 clang module-cache files and tens of megabytes. It is `.gitignore`d as of 2026-09-09, so it will not be committed; the note is only so nobody re-derives this from scratch.

- **The screensaver install script is not the cause**, though it was the obvious suspect. Measured: forcing a full recompile through `Scripts/make-saver-bundle.sh` writes **zero** files into it. Building the app target with the same `SYMROOT`/`OBJROOT` overrides writes zero as well.
- **The cause is not currently reproducible.** The directory was created at 09:30:22 on 2026-09-09, during a batch of `xcodebuild` runs, and nothing since has written to it.
- **Two false verdicts were reached before the right measurement.** The first compared directory mtimes after a build that had nothing to compile; the second compared directory mtimes again, which do not change when files are written *inside* a directory. Only counting recently-written files under the tree answers the question.
- Worth checking if it returns: whether it correlates with a change to the package graph rather than with any one build, since it appeared shortly after `Console` was made a library product.

## Build products out of the repo

Syd, 2026-09-10: *"all build products you produce should be in ~/.claude/build, not in the repo"*, and *"any that I am expected to produce should be in DerivedData somewhere."* The first is in effect for Claude already; the second is not met by the scripts.

- **What writes into the checkout today:**
  - `Scripts/make-saver-bundle.sh` defaults to `./build/xcode`.
  - `Scripts/make-agent-bundle.sh` defaults to `./build`, and runs `swift build` into `./.build`.
  - `Scripts/photogoroundd` runs `swift build` into `./.build`.
- **The catch: `.build` also holds the development library**, which is data, not a build product: `.build/pgr-container` and `.build/pgr-cache`. `MacHostEnvironment.buildDirectory` finds it by walking up from the executable to a directory named `.build`, and a binary with no `.build` above it — anything Xcode built — falls back to the source tree `#filePath` names.
- **Only the agent and `pgr_ctl` open it.** The app and the saver use `MacHostEnvironment` for the preference domain alone, which does not depend on `.build` — and Syd, 2026-09-10: "the app should not need to see the agent's container." So what can split is the agent and the rig: moving one's build and not the other's would have `pgr_ctl` reading one library while the agent serves another.
- **What has to be designed**: where development storage lives once no build does, and how every process finds the same place without a `.build` to walk to. `--container` and `PGR_CONTAINER` already exist for moving it by hand; the question is the default.
- `Scripts/scrub-dev.sh` hardcodes `$REPO/.build/pgr-container`, `$REPO/.build/pgr-cache` and a `pgrep` on `$REPO/.build/…photogoroundd`, and follows whatever is decided.
- The `build/` and `.build/` lines in `.gitignore` can go once nothing writes there.

## Build for arm64 only

Syd, 2026-09-15: "don't build arch:x86_64 at all". And the scope of it, the same day: "there is a difference between dev and shipping the product. At this point, macOS 27 supports intel, and if I ever ship this to the public, I will build for it. But for dev purposes, I don't want to waste the time or disk space." **So this is about development builds. Whether a shipping build is universal is Syd's, and undecided.**

**Done 2026-09-15: `Scripts/make-saver-bundle.sh` passes `-destination "platform=macOS,arch=arm64"`.** A clean build through it gives a saver that `lipo -archs` reports as `arm64`, and the "multiple matching destinations" warning is gone. It is the only script that runs `xcodebuild`. The project's build settings were deliberately left alone, so a release build can still be universal.

**Still open:** whether anything else produces x86_64 — Xcode's own builds go through `ONLY_ACTIVE_ARCH` and were not checked after this change, and the local package targets were not checked at all.

- **What builds x86_64 today — measured 2026-09-15 with `lipo -archs` on products under `~/.claude/build/photo-go-round`, before the change:**
  - Several Debug builds of `Photo-Go-Round.saver` and `Photo-Go-Round.app` from `xcodebuild` are `x86_64 arm64`, although the project sets `ONLY_ACTIVE_ARCH = YES`.
  - Some other Debug builds of the same targets are `arm64` alone, so it depends on how `xcodebuild` was invoked. Which invocation gave which is not recorded.
  - `Scripts/make-wallpaper-extension-probe.sh` built `arm64` alone: its `swiftc` target came from `uname -m`. *Retired 2026-09-15.*
  - `swift build` builds the host's architecture.
  - On Plex the same day, `Scripts/make-saver-bundle.sh` printed `xcodebuild: WARNING: Using the first of multiple matching destinations:`, listing `My Mac` twice, once `arch:arm64` and once `arch:x86_64`. Its `-destination "platform=macOS"` matches both.
- **What is left, if anything still builds x86_64:**
  - `ARCHS = arm64` in the project's build settings — not set, since it would follow a release build too;
  - the wallpaper probe script's `$(uname -m)`, which would build x86_64 on an Intel Mac, and is the right answer for a dev build there.
- **Check the local packages too.** The C++ hardening setting in the project did not reach the local package targets (`PLAN.md`, *Builds with no warnings*), so an architecture setting may not either. Verify with `lipo -archs` on every product after a clean build, not by reading settings.
