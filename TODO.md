# TODO

Things to look into, deferred out of the phase list. Each one earns its own plan document if and when it is picked up; nothing here is designed yet.

**This file holds only what is left.** An item is deleted when it is done, not struck through and not annotated as fixed — Syd, 2026-09-19: "`git log` and the plans tell me what has been done, so let's remove things as they get done", and "cleaning it up every once in a while keeps me sane". The record of finished work lives in the commit history and in `Plans/`; a TODO that also carries it stops being readable as a list of what remains.

**When a plan closes, check what it was holding.** Anything it left as later work moves here before the plan is marked done, or it disappears with it.

## Passed over on 2026-09-16 — to fix, not to keep

Syd, 2026-09-16: "i have no deadlines, and I hate tech debt surprises. I won't remember any issues you mention and bypass, so let's not bypass them." Every issue Claude mentioned during the agent performance work and did not fix is here. **Delete each one when it is fixed** — Syd, 2026-09-19: "cleaning it up every once in a while keeps me sane." Git has what was removed.

- **Flaky tests, below: how to fix them.** Syd, 2026-09-16: "we fixed flaky timing tests at Indeed by using await Task {}.run." *Claude's reading: a test awaits the work it depends on rather than racing it against a clock.*
- **The flaky build problem — caught and named 2026-09-19.** It is not a flaky *test*: it is `pgr_ctl`'s **testable** build failing to compile. `WallpaperCommands.swift:36` reports `cannot find type 'Deployment' in scope` and then `cannot find type 'BuildVariant'`, with `import PhotoGoRoundAgentAPI` present on line 3 of that file. Everything downstream of it — the whole run — is then reported as a test failure, which is why it read as flakiness for three days.
  - **Build-order dependent.** `xcodebuild clean test` passes every time; incremental `xcodebuild test -scheme "Package Tests"` failed on the second of six consecutive runs over an unchanged tree. The full log is at `~/.claude/build/flaky/run2.log`.
  - **The same shape as `Build Plan.md`'s 2026-09-16 finding**, where `pgr_ctl` linked when built alone and failed when built after `Photo-Go-Round Server` in the same folder. That one was fixed by declaring the package product dependency, which *is* declared here — so this is a second instance with a different cause, not a regression of the first.
  - **The leading suspect is a second builder.** Syd, 2026-09-19: "There is another agent working on the fact that the wallpaper agent wasn't changing pictures" — in this same working copy. `WallpaperCommands.swift` was being edited by it while these runs happened, and two builders sharing intermediates invalidate each other's, which `CLAUDE.md` already says of Syd's own Xcode. A source file rewritten under an incremental compile would produce exactly this.
  - **To settle it:** run the loop again when nothing else is working in the checkout. If it stops failing, the answer is contention and there is no defect to chase. If it still fails, the suspicion is the `-enable-testing` variant of `PhotoGoRoundAgentAPI` being rebuilt under the compile that needs it — unmeasured.
  - It is a build problem wearing a test problem's clothes, and the two above it are the timing-flaky tests proper.
- **Some photographs change on every refresh.** After Phase 4 was installed, 2026-09-16 22:24, two refreshes 20 seconds apart each wrote about 17 pages of Favorites (source 5) with one or two "changed" rows apiece; the probe's refreshes before it showed the same. Nothing about those photographs changed in between, so a storage or byte size is probably read differently each walk — a Photos asset whose size flips between known and unknown, say. Each costs a short lock (0–4 ms) and a needless write. Not looked into; the `REFRESH:` line does not name which rows.
- **The test run stalls the cooperative pool for up to two seconds.** Measured 2026-09-16 while fixing `RequestBodyTests`: a 10 ms `Task.sleep` resumed 1.2–1.96 s late in full parallel runs of the agent's tests. Not traced to which suites hold pool threads. The same shape as the agent's own pool starvation that afternoon, so the one lead from the flaky-test work that may matter outside the tests. Syd, the same evening, on flaky tests that expose no code problem: "are they really worth it?"
- **A test that asks the real Photos library: `SourceEndpointTests` "An album identifier that names nothing is refused at the door".** It posts a `photos_collection` source through the endpoint's default providers, which ask PhotoKit on whatever Mac runs the tests, under a time bound. It failed in two full runs while `ServingUnderLoadTests` froze the pool.
- **`PhotosSourceEditingTests` fails under machine load, against a fake library.** 2026-09-21, load average 21–28 from something else on the Mac: five of its tests failed in each of three full runs (seven in one, with two walk-stall tests), each taking ~11 s, and all 18 passed alone in 5 s. They fail because `SourceStore.validationLimit` (5 s) expires, so the source is recorded rather than refused. An untouched copy of `HEAD` passed once and failed `SourceEndpointTests` once in the same window, so it is load, not a change. A test that races a wall clock against the pool — the same shape as the item above.
- **Every configuration's screensaver has the same principal class, `PGRScreenSaverView`.** Found 2026-09-21: with the Debug saver loaded, a `(Claude)` saver shown in the same host ran Debug's code, on Debug's port, against Syd's running agent — the Objective-C runtime keeps the first class of a name in a process. So the three configurations' savers install side by side but cannot run side by side, which `CLAUDE.md`'s table implies they can. The class is named by `@objc(PGRScreenSaverView)` in `MacOS/Screensaver/Sources/PGRScreenSaverView.swift` and `NSPrincipalClass` in the saver's `Info.plist`; each configuration needs its own.
- **Restructure the tests so none fails on wall-clock time.** Syd, 2026-09-21: "some of the tests need to be restructured not to fail on wall clock time." Started and set aside the same day; nothing changed yet.
  - **Why they lose under load:** `Deadline.run` times on a `DispatchSourceTimer` since 2026-09-18, so its limit expires on time even when the pool is starved — while the work it bounds, a fake that would answer at once, waits for a pool thread. The timer was made robust for the agent; for a test that expects the answer, that is what makes it lose.
  - **The likely shape of the fix:** production bounds such as `SourceStore.validationLimit` become injectable, so a test expecting an answer passes a bound it cannot reach, and a test about silence uses a fake that never answers — which then fails only one way whatever the clock does. The "await the work, don't race it" idea above is the same thing.
  - **Scope:** about 55 test files mention a sleep, a clock, a `Duration` or a timeout (`grep -E "Task\.sleep|ContinuousClock|Deadline|\.seconds\(|\.milliseconds\(|timeout|within:"` over every `Tests` folder). Many test the bounds themselves (`DeadlineTests`, `ServeWaitTests`, `PoolWaitTests`) and need a different treatment from those that only happen to sit behind one. Classify first; known losers so far are `PhotosSourceEditingTests` (five tests), the two walk-stall tests, and `SourceEndpointTests` above.
  - **Another, 2026-09-22:** `SilentLibraryTests`, *A stalled walk leaves the source unavailable, not emptied* and *A walk that stalls part way is bounded, and keeps what it received*, failed once in a full `Package Tests` run, the suite taking 10 seconds. The suite alone passed three times out of three in 5 seconds, and the next full run passed.
- **Photos albums stay "not responding" for up to five minutes after the agent starts.** *Syd: "is worrying", then "diagnoising startup slowness requires its own sessions, so let's do those items later".* Left open, for its own session. At the 17:46 install both were marked unavailable at 17:46:14; Photos answered in 71 ms by 17:50; the label waits for the next scheduled refresh.
  - **The same shape, 2026-09-21:** adding 26 albums to a Release agent about a minute old took more than fifteen seconds — `201 POST /v2/sources` at 23:46:42, the panel's session having given up first. The session is fixed (`AgentSession.make(above:)`); why the add was that slow is not looked into.

## Examine the cache size

**`cacheByteCeiling` is 1 GB and has never been measured.** `PLAN.md` says so itself: "the default
byte ceiling is explicitly a starting point to be replaced by measurement." The sweep that was going
to do that (5 / 10 / 25 / 50 / 100 GB) was **cancelled** on 2026-09-06, and nothing replaced it.

**What the cache is for, so the next measurement asks the right question.** Syd, 2026-09-19: "the
cache is basically there so that when a card is asked for, it will have been rendered because our
deck is essentially a 20 image lookahead. For small libraries, having the renders/cards reused is a
happy benefit. We will never have everything cached for a large enough library, and that's ok."

So the criterion is **does the lookahead always have its bytes ready**, not a hit rate. Reuse is a
bonus at the small end and is expected to be zero at the large end. A low hit rate on a big library
is the design working, not a fault.

- **Measured 2026-09-19, three hours:** 1,295 pictures served, 1,294 fresh renders — so reuse on
  this 9,185-photograph library is essentially nil, exactly as the above predicts. The cache sat at
  997.8 MB of its 1,000 MB, 276 originals, turning over about 50 MB an hour across 41 evictions.
  *Recorded so nobody later reads that ratio as a defect and optimises for a hit rate that was never
  the point.*
- **Against the real criterion the cache is passing, and it was checked rather than assumed.** Over
  the same three hours every serve said *is here* — 1,285 of them, with no miss on the serve path.
  (Two said *unconfirmed*, which is the source not answering whether the photograph still exists, not
  a cache miss.) 20 queued cards at roughly 3.6 MB apiece is about 72 MB of lookahead inside a
  1,000 MB ceiling, so eviction is working a long way from the cards that matter.
- **The likely answer is that 1 GB is too big, not too small.** Syd, 2026-09-19: "with this framing,
  1 GB is certainly too big." The lookahead needs about 72 MB and the cache is holding 276 originals
  to serve 20 — an order of magnitude of disk spent on photographs the deck is not about to deal.
  **This inverts the cancelled sweep**, which explored 5 / 10 / 25 / 50 / 100 GB on the assumption
  that bigger bought a better hit rate; under the staging-area framing the interesting range is
  *below* where it starts.
- **Deferred to its own plan.** Syd, 2026-09-19: "further discussions can be deferred until we fix
  this in a separate plan." Nothing here is designed, and the tension to settle there is the small
  library against the large one — the same ceiling has to leave reuse intact where reuse happens and
  not hoard where it cannot.
- **It needs no new code to measure.** `RENDER:` against `served status=200` gives the reuse rate,
  the eviction lines give the churn, and the `SERVE:` lines say whether a dealt card ever arrived
  without its bytes.

## The `NSLock`s outside the agent

Syd, 2026-09-17: "I flatout don't want NSLocks." Phase 5 of the agent performance overhaul took the
agent and the kit from sixteen to **zero**, with four documented exceptions that could not be actors.
What it did not touch is everything else, and the plan closed 2026-09-19 still holding this.

- **One in shipping code:** `MacOS/Wallpaper/Sources/PaneHandler.swift:524`, a `static let
  lock`. The only one left in anything that runs on a person's Mac.
- **Twenty-eight in test doubles**, across `MacOS/Shared/Tests/PhotoGoRoundKitTests`, `MacOS/Agent/Tests`,
  `Shared/Tests/PhotoGoRoundDisplayTests` and `MacOS/Desktop/Tests` — the recording spies that collect what a
  `@Sendable` closure was called with. `Mutex` is the like-for-like replacement; most are four-line
  classes.
- **Not urgent, and worth saying why it is here at all:** none of these is a measured problem. The
  agent's were removed because a lock held across an `await` is a stall nobody can see, and these
  are neither on the serving path nor in the agent. This is a consistency item.

## A disallow-list for images that will not decode

Syd, 2026-09-16: "The client needs to log when the decode fails. Later, we might keep track of which
images in the client fail, and when a certain number of failures in a row happen, we have an
endpoint to tell put the image on a disallow-list."

Moved here 2026-09-19 when `Plans/Agent Performance Overhaul.md` was closed — it was the one piece of
that plan deliberately left as later work, and closing the plan would have buried it.

- **What exists already.** A client that cannot decode what it was given discards it and asks for
  another card — decided 2026-09-16, "the client discards it… The agent has already moved on at that
  point" — and logs a line naming the card, the deal, the photograph, its source, the byte count and
  the content type. The line was written so this work could start from it: it already names
  everything a client would need to report.
- **What it costs today, known and accepted:** a bad file stays in the deck, and every time it is
  dealt it spends one request and one failed decode on the client.
- **Undecided, and all of it:** the count, the threshold, the endpoint, and whether the list is the
  agent's existing `render_failures` retirement or something beside it. *Claude's note: the two are
  not obviously the same thing — `render_failures` retires a photograph the **agent** could not
  resize, and this would retire one **clients** cannot decode. A file the agent resizes happily may
  still arrive unusable, and a file the agent cannot resize is sent as an original the client may
  decode fine.*
- **The agent's retirement stays either way.** Syd, 2026-09-16: "yes, keep the retirement."

## Shared schemes for `pgr_ctl` and `pgr_install`

Syd, 2026-09-16: "add a target for pgr_ctl to the Xcode project".

- **The target is already there:** `pgr_ctl` in `Photo-Go-Round.xcodeproj`, which `Build Plan.md`, *The targets*, records, and which gained its `PhotoGoRoundDisplay` dependency on 2026-09-16.
- **Decided 2026-09-19: no install.** Syd: `pgr_ctl` is a copy or a symlink into `~/bin`, and Archive is the route for anything shipped. `Build Plan.md`, *The install phases*.
- **What is left is one shared scheme each, for `pgr_ctl` and `pgr_install`.** Neither has one, so Xcode autocreates them per user and nobody else gets the settings — which is how the agent's scheme came to launch with `-NSDocumentRevisionsDebugMode` and refuse to start. Every other target has one now, including the three `Install …` schemes.
- `Package Tests` is the exception to where they live: `.swiftpm/xcode/xcshareddata/xcschemes/`, because a scheme whose targets are the package's is a package scheme. `pgr_ctl` and `pgr_install` are Xcode targets, so theirs go in `Photo-Go-Round.xcodeproj/xcshareddata/xcschemes/` with the rest.
- Set `debugDocumentVersioning = "NO"` in both, as every other scheme now does.

## A section of our own for the screensaver in System Settings

Syd, 2026-09-16: "Is there a way to have a custom section for our screensaver?" — asked while the wallpaper's development builds were being put in one *Photo-Go-Round* section in the Wallpaper pane.

- **Not looked into.** What is known, from the wallpaper work: the `.saver` is listed by System Settings itself, and `WallpaperAgent` hosts it as `ScreenSaverWallpaper` with provider `com.sydpolk.photogoround.saver`. The wallpaper extension's section *did* appear in the Screen Saver list on 2026-09-15, so an extension on `com.apple.wallpaper` can put a section there — `Wallpaper Plan.md`, *The real extension, inside the app*, the Screen Saver list notes.
- *Claude's reading, not measured:* a custom section probably means the screensaver answering the pane as an extension, as the wallpaper does, rather than as a `.saver` bundle.

## The tag line: "Your photos, shuffled"

Syd, 2026-09-16: "change the tag lines for both wallpaper and screensaver to "Your photos, shuffled"."

- **The wallpaper's** is the pane item's `localizedDescription` in `MacOS/Wallpaper/Sources/PaneModels.swift`, now "Photographs from your library, shuffled".
- **The screensaver has none in its sources.** A search for the wallpaper's wording and for "your library" and "your photo" under `MacOS/` finds no description for the `.saver`; where System Settings would show one for it is not known.

## Statistics about resized copies, where they belong

Syd, 2026-09-16: "put statistics about the cached resized picture where appropriate".

- **Today nothing counts them apart.** `PhotoCache.status()` folds copies into `bytesOnDisk` with the originals, so `pgr_ctl cache status` and the dashboard show one total. No count of copies, no bytes for copies alone, no hits or misses on the copy lookup, and eviction's tally does not say how many of what it took were copies (`LaunchTally.Evictions`). *Already there:* a request's `TIMING:` line names its stage `resized copy`, `render` or `resize gave up`, so one request says which it was; nothing adds them up.
- *Claude's candidates, not decided — where each would go is Syd's:*
  - **`pgr_ctl cache status`**: copies held and their bytes, beside originals.
  - **The dashboard's cache panel** and `/v1/dashboard`: the same, and copy hits against resizes since launch — the number that says whether the resize cache is saving the resizer anything.
  - **Evictions**: copies and originals taken, separately.
- Anything added to the dashboard or `pgr_ctl` is documented in `Documentation/photogoroundd.md` or `pgr_ctl.md`, and tested.

## Cached files broken down by source, in the dashboard

Syd, 2026-09-19: *"add a panel in the dashboard breaking down how many files have been cached broken down by source"*. Nothing is designed.

- **Today it is one number.** *Photos in the cache* and *Cache on disk* both come from `PhotoCache.status()`, which counts resident entries and bytes across the whole cache; `pgr_ctl cache status` shows the same totals. Nothing is per source.
- **The cache already knows the source.** A cache path is the source, then `.original`, then the photograph's own identity, and every `CACHE:` line names `(source N)` — so the breakdown is there on disk and in the log, and nothing adds it up.
- **Open, and Syd's:** files, bytes, or both; sources named by title (*Photos › Favorites*) or by id; and whether referenced photos are in it, since they are not copied and not budgeted.
- **Related:** *Statistics about resized copies, where they belong*, which wants the same panel to split originals from copies. If both land it is one table — a row per source, a column per thing counted — rather than two panels.
- Anything added to the dashboard or `pgr_ctl` is documented in `Documentation/photogoroundd.md` or `pgr_ctl.md`, and tested.

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

## Three empty-state messages, each for its own cause

Syd, 2026-09-21, after a `(Claude)` screensaver with no agent anywhere showed "Waiting for Photos": show **"No agent running"** when there is no agent running, **"No Photos available"** when there are zero photos in the database, and **"Waiting for Photos"** otherwise. **Capitalized as a sentence, except "Photos"**, which keeps its capital everywhere — Syd, the same day: "Initial capitals, small everywhere else, except for 'Photos'". So today's "No Photos Available" becomes "No Photos available".

- **Today `Shuffle.Trouble.words` maps `.noAgent` and `.silent` both to "Waiting for Photos"**, `Shared/Sources/PhotoGoRoundDisplay/Shuffle.swift`. That follows two earlier decisions, which this one revises: 2026-09-09, "to the user, 'no agent' and 'stuck agent' are the same thing", and 2026-09-16, when "Open the Photo-Go-Round application to start it" became "Waiting for Photos". So `.noAgent` gets its own words; `.silent` — accepted the connection, never answered — stays "Waiting for Photos".
- **"No Photos Available" is not "zero photos in the database" today.** `.noPhotos` is said after three empty answers in a row (`emptyAnswersBeforeSaying`), which a library with photos but nothing servable yet also produces. Saying it only for an empty database needs the agent to tell the client its count, which no endpoint the surfaces use does now.
- The words appear in the window, the screensaver and the About box; all three read `Trouble.words`.

## Installing by launching the app

What is left after `Plans/Release App Installer.md`, which built the app as the installer on 2026-09-21: every build carries the agent, the extension and the screensaver, installs and restarts its agent at launch, and a Release launch registers the wallpaper and links the saver.

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
- `MacOS/Desktop/FEATURES.md` already sketches *A menu bar app* — a status item, and an item that brings the window up — and is where this starts.

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

## `Photo-Go-RoundTests` is not in the default test run

Carried out of `Plans/Xcode - Separate Build and Run.md` when it closed, 2026-09-19.

`xcodebuild test -scheme "Package Tests"` runs the package's five test targets — 1,001 tests — and not the app's bundle. `Photo-Go-RoundTests` was in the test plan when Xcode created it and was taken out: it is the app's own suite, it wants a running agent, and a plain run of it fills the log with `panel: read failed — Photo-Go-Round's agent is not running`.

- **It is still runnable**, through the `Photo-Go-Round` scheme, which has it as a testable. Nothing is lost except that nobody runs it by habit.
- **What to decide** is whether it belongs in the same plan behind a filter, in a second plan of its own, or nowhere — Syd skips GUI tests, and this is the suite closest to being one. `TODO.md`, *No GUI testing* is the standing position.
- `Package Tests.xctestplan` is the file, and a test plan can hold more than one configuration if that turns out to be the shape.

## Settings are the only data a user would miss

Syd, 2026-09-19, while deciding what a clean slate could throw away: *"the only thing in my data that would be actually missed by users if it disappeared is the settings"*. **Needs its own plan if it is picked up.**

- **Everything else is derived.** The database re-enumerates from the sources, the cache refetches, the deck's shuffle position is not precious. Proven the same day: the whole library, cache and both containers were deleted and rebuilt from four sources in minutes.
- **So backup, migration and upgrade have one thing to protect** — the preference domains — and may treat the container and the cache as disposable. That is a much smaller problem than backing up a library.
- **It is also what makes a version upgrade safe to test**: throwing away storage costs time, not data, as long as the domains survive.
- Where they live is now `com.sydpolk.photogoround[.debug|.claude][.dev]`, plus the surfaces' own `.screensaver.*` and `.wallpaper.*` domains. `BuildVariant.swift`, and `Plans/Xcode - Separate Build and Run.md`.
- **Not decided:** whether anything should export them, and whether the app should offer it.

## A private support page at `/private`

Syd, 2026-09-19: *"there should be a not-user-documented URL to have an HTML page with all of the command available there"*, and *"this is part of supporting existing users"*. Indeed's "Poodlepants" is what he is describing. `Plans/Private REST API.md` went further than he asked for and is his to keep or delete.

Settled in conversation the same day, before he stopped the design:

- **`pgr_ctl` is not reimplemented over the API and stays standalone.** He retracted his own *"all of the commands that pgr_ctl supports should be reflected in the agent's REST API"* once it was clear that direct access is what makes it work with the agent down — which is when it is wanted. Same exception it already holds in *Settings endpoints* above.
- **Eleven of fifteen command families**: `status`, `sources`, `refresh`, `pool stats`, `queue peek|fill`, `deck stats`, `cache status|evict|clear`, `get|set`, `wallpaper get|set`, `notify`. Dropped: *"ditch shuffle-test, log, register. Keep the cache clear."*
- **A typed URL runs the command**, and `/private` is *"just a button to press which would navigate to the typedURL"*. No forms and no confirmation page.
- **Two namespaces.** `/v2/…` stays RESTful for the app; `/private/…` is the GET-invocable support surface and *"does not have to be completely API-formal"*. `/v2` grows when a client needs it, not for symmetry.
- **Open, and accepted:** a mutating GET can be fired by any page in any browser on the Mac with `<img src="…">`, and no `Origin` check helps. Bounded by what the commands can do.
- **Open, undecided:** `pgr_ctl cache clear` prompts with how much would be cleared, and a GET that just does it has nowhere to put that.

## Settings inside the wallpaper extension and the screensaver bundle

Syd, 2026-09-16: *"explore putting settings directly into both the wallpaper extension and the screensaver bundle."* Today settings change only in the app or through `pgr_ctl`. Nothing is designed.

**This is the next thing after the wallpaper, and it lives here rather than in a plan.** Syd, 2026-09-19: "the next phase is putting the options directly in the system settings panel", and that it "belongs in *Settings inside the wallpaper extension and the screensaver bundle*" — because the same work covers the screensaver's configure sheet too, so neither surface's plan owns it. `Wallpaper Plan.md` Phase 2 is met and that plan does not carry a phase for this.

- **The wallpaper half is what goes first**, and Syd named it twice. 2026-09-15: "The next stage would be to put a sources panel and timing slider directly into the extension." `Wallpaper Plan.md`, *The real extension, inside the app*.
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

## What System Settings › Wallpaper needs from us

Syd, 2026-09-10: *"Add a TODO.md item to see what we need to do in System Settings -> Wallpapers."* Nothing is known yet; these are questions to answer by looking, on macOS 27, since the pane was rewritten in Sonoma.

- **What the pane shows once we have set a file** — our picture as a custom photo, the file's name, something else — and whether anything it offers would quietly undo us.
- **Its own rotation.** If the pane is set to change the picture on a schedule, `WallpaperAgent` rotates on its own and the two would fight. Whether setting a URL turns that off, or the user has to.
- **The fill colour.** The wallpaper uses the colour chosen here: where it lives in the pane on 27, and whether it is per display or per Space. See `Wallpaper Plan.md`, *The fit*.
- **Showing on all Spaces.** Whether the pane has such an option on 27, and whether it reaches a file set through `setDesktopImageURL`. If so it could do more for the per-Space hole than re-applying on every Space change.
- **Dynamic and Aerial wallpapers.** What happens when one is selected and we set a still over it, and whether it comes back on its own — a candidate for the reversions `PLAN.md`'s *Wallpaper is asserted continuously* describes.
- Whatever this turns up goes into `Wallpaper Plan.md` before its Phase 1 is built, since several of these could change what Phase 1 does.

## Removing every source leaves the window showing a photograph

Observed 2026-09-09. Remove all sources and the agent does the right thing — it has nothing to serve and answers `204`. The window keeps the last photograph up indefinitely, and the Settings panel is meanwhile showing the empty list correctly.

- **Quitting and relaunching shows *No Photos Available* immediately**, which narrows this to one line of state. A fresh `Shuffle` starts with `shown` nil, takes its three empty answers, and says so; the old process was only holding the photograph because `shown` is never cleared once it has been set. So the agent is genuinely answering `204`, the cache is not involved, and nothing needs to be discovered — the window is showing a value it already has no reason to keep.
- **The rule doing this is deliberate**, and it is the deck's first duty: *a picture already showing is never taken down*. `Shuffle` keeps `shown` through an empty answer so a slow or absent agent never blanks a surface. It is why the screensaver survives a wake, and it should not be weakened generally.
- **It is already a known shortcoming**, in the general form: `PLAN.md`, *Deferred: retracting a photo already on screen*, and *Known shortcomings* item 6 — 0.1 ships accepting that a photograph can linger on a surface after it is gone.
- **But this case is worse than the one that was accepted, and for a reason worth writing down.** The deferred case is a photograph deleted somewhere else, where the client cannot know. Here the person removed the sources *themselves*, in this app, through this app's own panel — and one window of it is showing an empty list while another shows a photograph from a source that no longer exists. Nothing is stale except the screen, and the process that made the change is the process still displaying the old answer.
- **It therefore does not need the revocation protocol to fix.** `FEATURES.md` already draws this distinction under *One window telling another is not a doorbell*: a change *this app just made* is narrower than a change the agent announces, and the picker already tells its own windows. The empty state exists now, so the window has somewhere to go.
- **Decided 2026-09-19: straight to *No Photos Available*.** Syd: "when all sources have been removed, *No Photos Available* is the right answer." So the picture comes down. The abruptness is the point — the person just emptied the library themselves, and a surface still showing a photograph from it is lying about what is there.
- **Still to settle when it is built:** whether removing the *last source* is the trigger, or any change that empties the pool. *Claude's reading, not decided: the pool emptying is the honest condition — it covers a source going offline and a source whose photographs were all deleted, and it needs no special case for "last". The risk is that a source briefly reporting nothing would blank a surface that a source-removal test would not.*
- **What it must not become** is a general retraction. The deferred case in `PLAN.md` — a photograph deleted somewhere else — stays deferred; this is only the case where this app made the change and therefore knows. do it.

## Always show "No Photos Available" when it is true

Observed 2026-09-09, in all three views: on a first launch with no pictures, the surface is blank for several seconds before *No Photos Available* appears. `Shuffle` says nothing until it has had three consecutive empty answers three seconds apart — about ten seconds — because one `204` is a queue turning over rather than an empty library.

**Decided 2026-09-19.** Syd: "Always show *No Photos Available* when it is true that no photos are available." It is a rule about honesty, not about timing: the surface says what is so, as soon as it is so. **No third state** — the *Launching…* / *Loading photos* wording this item used to propose is dropped. And nothing is painted before it is known, because a surface claiming an empty library while the queue is merely turning over would be saying something false.

- **The whole difficulty is knowing that it is true**, and the ten-second delay is what knowing currently costs. Three empty answers three seconds apart is a guess dressed as certainty; it is slow *and* it can still be wrong.
- **The agent is not guessing, and that is the opening.** *Claude's reading, not decided:* this item has said since 2026-09-09 that it "needs no change to the wire" because "the service cannot tell a cold start from an empty library; both are `204`" — but that is a fact about today's wire, not a necessity. The agent knows whether the pool is empty, whether any source is configured, and whether it is still filling. If a `204` said which, every surface could show the truth on the first answer with no streak, no delay, and no flash on a healthy launch.
- **`PLAN.md`'s *The empty state* wants updating when this is built.** It names three cases and asks for the third, the transient cold start, to "say something like *Loading photos*". That is the state now dropped.
- **What becomes of the `Shuffle` streak** depends on the above: it exists only to turn repeated `204`s into confidence, so an answer that carries its own reason would retire it.

## Build for arm64 only

Syd, 2026-09-15: "don't build arch:x86_64 at all". And the scope of it, the same day: "there is a difference between dev and shipping the product. At this point, macOS 27 supports intel, and if I ever ship this to the public, I will build for it. But for dev purposes, I don't want to waste the time or disk space." **So this is about development builds. Whether a shipping build is universal is Syd's, and undecided.**

**Still open:** whether anything else produces x86_64 — Xcode's own builds go through `ONLY_ACTIVE_ARCH` and were not checked after `Scripts/make-saver-bundle.sh` began passing `-destination "platform=macOS,arch=arm64"` on 2026-09-15, and the local package targets were not checked at all.

- **What builds x86_64 today — measured 2026-09-15 with `lipo -archs` on products under `~/.claude/build/photo-go-round`, before `Scripts/make-saver-bundle.sh` began passing that destination:**
  - Several Debug builds of `Photo-Go-Round.saver` and `Photo-Go-Round.app` from `xcodebuild` are `x86_64 arm64`, although the project sets `ONLY_ACTIVE_ARCH = YES`.
  - Some other Debug builds of the same targets are `arm64` alone, so it depends on how `xcodebuild` was invoked. Which invocation gave which is not recorded.
  - `Scripts/make-wallpaper-extension-probe.sh` built `arm64` alone: its `swiftc` target came from `uname -m`. *Retired 2026-09-15.*
  - `swift build` builds the host's architecture.
  - On Plex the same day, `Scripts/make-saver-bundle.sh` printed `xcodebuild: WARNING: Using the first of multiple matching destinations:`, listing `My Mac` twice, once `arch:arm64` and once `arch:x86_64`. Its `-destination "platform=macOS"` matches both.
- **What is left, if anything still builds x86_64:**
  - `ARCHS = arm64` in the project's build settings — not set, since it would follow a release build too;
  - the wallpaper probe script's `$(uname -m)`, which would build x86_64 on an Intel Mac, and is the right answer for a dev build there.
- **Check the local packages too.** The C++ hardening setting in the project did not reach the local package targets (`PLAN.md`, *Builds with no warnings*), so an architecture setting may not either. Verify with `lipo -archs` on every product after a clean build, not by reading settings.

## Retire the `photogoroundd` name

Syd, 2026-09-22: ditch it as a target and as a name; the agent has a better name now — `Photos-Go-Round Server`.

- *Claude's reading:* this is the package's `photogoroundd` executable product and target, its `.swiftpm` scheme, `photogorounddTests`, and `EXECUTABLE_NAME = photogoroundd` in the Server target. The documentation uses the name too: `Documentation/photogoroundd.md`, and mentions in `Installing.md`, `pgr_ctl.md`, `pgr_install.md` and `README.md`.

## The screensaver preview is black when first selected

Syd, 2026-09-22: the preview in System Settings is black when the screensaver is first selected.

## An option in `uninstall.sh` to delete the user data

Syd, 2026-09-22: add an option to `uninstall.sh` that deletes all of the user data — the database, the preferences, and the like. It deletes them only when the option is given.

- *Claude's note:* `Scripts/scrub-dev.sh` already deletes the development libraries and, with `--preferences`, their preferences, and it refuses production on purpose. This option would reach production storage too, which is what separates it from the scrub.

## Tests for the wallpaper extension's and screensaver's own code

Syd, 2026-09-22: yes, add it. Nothing tests the code in `MacOS/Wallpaper/Sources` or `MacOS/Screensaver/Sources` — `Rotation`, `LastPicture`, `AgentPicture`, the pane models, `DisplayShuffles`, the saver view. What is tested is around them: `PhotoGoRoundDisplay`, the wallpaper's entitlements, the installs, and `pgr_ctl`'s wallpaper commands.

- *Claude's note:* that code is compiled only into the extension and saver targets, so the package tests cannot reach it. Either the logic moves into a library the package tests link, or the two get Xcode test targets of their own. Not GUI tests.

## Removing a wallpaper build leaves its Launch Services record

Syd, 2026-09-22: add it. A deleted build of the wallpaper extension stays listed in System Settings › Wallpaper, because Launch Services keeps a record of it after its files are gone. Found that day: "Photo-Go-Round Wallpaper (Claude)" was listed with no `pkd` registration and no process, from an archive build under `~/.claude/build` that no longer existed; about 40 more such records turned up, one of them from Syd's DerivedData. `lsregister -u` on each missing path cleared them, and the pane entry went.

- **`CLAUDE.md`'s cleanup after building `Photo-Go-Round Wallpaper Host`** runs `pluginkit -r` and deletes the host app. It needs `lsregister -u` on the host app before deleting it.
- **`Scripts/uninstall.sh --wallpaper`**, through `pgr_install uninstall`, unregisters from `pkd` and stops the extension, but leaves Launch Services records behind.

## The package test command needs a workspace git does not track

Syd, 2026-09-22: add it. Since the reorganization put `Photo-Go-Round.xcodeproj` beside `Package.swift`, `xcodebuild test -scheme "Package Tests"` picks the project, and through the project the scheme finds no test bundles — "There are no test bundles available to test", with or without `-project`. Pointing the test plan's targets at `container:.` did not help. What works is `-workspace .swiftpm/xcode/package.xcworkspace`, now the command in `CLAUDE.md`.

- **That workspace is generated and ignored.** `.gitignore` excludes both `.swiftpm/xcode/package.xcworkspace/` and `*.xcworkspacedata`, so a fresh clone does not have it. *Claude's reading, not tested:* Xcode writes it when it opens the package, so the documented command would fail on a fresh clone until that has happened once.
