# TODO

Things to look into, deferred out of the phase list. Each one earns its own plan document if and when it is picked up; nothing here is designed yet.

## An Options button for the screensaver

Some savers show one in System Settings. `ScreenSaverView` provides it through `hasConfigureSheet` and `configureSheet`, both of which `PGRScreenSaverView` currently answers `false` and `nil`.

- **The blocker to establish first is where a setting would be written.** The Phase 1 spike found the saver cannot even *read* the agent's preference domain from inside `legacyScreenSaver`'s sandbox — `UserDefaults(suiteName:)` returns a suite that opens cleanly and is empty. It certainly cannot write one.
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
- **The saver half is not designed at all.** An unsandboxed Developer ID app can copy `Photo-Go-Round.saver` into `~/Library/Screen Savers` itself, which is what `Scripts/make-saver-bundle.sh --install` does today by hand.
- **Selecting it is probably not ours to do.** Installing a screensaver and making it the user's screensaver are different acts, and the second one is theirs.
- **Updating is the part that bites.** `legacyScreenSaver` caches the loaded bundle for the life of its process and System Settings caches its list, so replacing an installed saver means killing both — the script already does this, and an app doing it silently to a running screensaver needs thought.
- **Decide which deployment a shipped app runs in.** The app and the saver both ask for `.development` today; a shipped one must not.
- **The window needs Install Agent and Launch Agent buttons.** Syd, 2026-09-09. They are what the empty state should offer when nothing is being served, rather than words.
- **The empty state's agent wording is a placeholder that is wrong in one of the two places it appears.** It reads "Open the Photo-Go-Round application to start it", which is right on the screensaver and absurd in the window, because the window *is* the application. The buttons above are what the window should show instead. Until then the text stands, knowingly.
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

## Metrics in the database

Serve counts and timings belong in the deck, not only in the unified log. **Needs its own plan when it is picked up.**

- **The 2026-09-08 overnight run is the argument.** The screensaver's own per-photograph line is `.info`, which is memory-only, so it had evaporated by morning; the run could only be counted because the *agent's* serve line happens to be `.notice`. `Log.swift` says this outright — "state transitions worth reconstructing after the fact must be `.notice` or higher" — and the count that mattered was on the wrong side of it. The saver's line is still `.info` today.
- Raising that line to `.notice` is the cheap alternative and a poor one: ~3,400 lines a night of something entirely routine, burying the lines that are not.
- **There are hooks already.** The `consumer` table carries a `seenAt` heartbeat, and `pgr_ctl` already runs the deck's statistical checks — so there is a place to write and a rig to read with.
- Worth recording: serves per consumer per interval, latency, cache hit or miss, non-200s, and what the queue depth was at the time.
- **The cost is a migration and a write on the serve path**, which is the hot path — 3,034 serves in nine hours from one surface, and every surface shares it.

## Settings endpoints, and preferences as a black box

The agent should answer for its own configuration over HTTP, and its preference domain should stop being something clients read or write. Syd, 2026-09-09: *"We need to add settings endpoints anyway; the agent's preferences should be a black box."* **Needs its own plan.**

- The shape is already set by `PLAN.md`'s *The database is private to the service* — this is the same argument applied to the other durable store. `GET` and `PATCH` alongside `/v1/sources`, and no client touching the domain.
- **One thing has to be designed rather than assumed: how a client finds the agent.** `ServicePort` reads `servicePort` out of the domain, and from inside the screensaver's sandbox reads the `.plist` as a file, precisely because a client cannot ask the agent where the agent is. Sealing the box without answering that breaks every surface at once. Either the port stays a deliberate hole in it, or discovery moves to some other mechanism.
- **It reverses a stated position and that should be recorded in `PLAN.md` when it happens.** *Preferences* there treats `defaults write` as a first-class interface — "two rules follow from `defaults write` being a first-class interface" — and that is what a black box takes away.
- `pgr_ctl` keeps its direct access, as the rig rather than a client. Same exception it already holds for the database.
- The screensaver's Options sheet is the first thing that needs this, and the reason it is parked above.

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
- **A pause control** is named in `PLAN.md` as the obvious way to stop us reasserting; where it lives — Settings panel, menu bar — is not decided. *2026-09-10: the app's* Also set wallpapers *checkbox is the first way to stop it; whether a separate pause is still wanted is open in `Wallpaper Plan.md`.*

## What System Settings › Wallpaper needs from us

Syd, 2026-09-10: *"Add a TODO.md item to see what we need to do in System Settings -> Wallpapers."* Nothing is known yet; these are questions to answer by looking, on macOS 27, since the pane was rewritten in Sonoma.

- **What the pane shows once we have set a file** — our picture as a custom photo, the file's name, something else — and whether anything it offers would quietly undo us.
- **Its own rotation.** If the pane is set to change the picture on a schedule, `WallpaperAgent` rotates on its own and the two would fight. Whether setting a URL turns that off, or the user has to.
- **The fill colour.** The wallpaper uses the colour chosen here: where it lives in the pane on 27, and whether it is per display or per Space. See `Wallpaper Plan.md`, *The fit*.
- **Showing on all Spaces.** Whether the pane has such an option on 27, and whether it reaches a file set through `setDesktopImageURL`. If so it could do more for the per-Space hole than re-applying on every Space change.
- **Dynamic and Aerial wallpapers.** What happens when one is selected and we set a still over it, and whether it comes back on its own — a candidate for the reversions `PLAN.md`'s *Wallpaper is asserted continuously* describes.
- **What the user should be told**, if anything, when *Also set wallpapers* is ticked.
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
