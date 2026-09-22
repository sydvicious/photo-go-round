# Summary

**Closed 2026-09-22.** All six phases built and run on Syd's Mac, and installed
on a second Mac, Plex — Syd: "I was able to install on Plex successfully."
What it left open is in `TODO.md`.

Every build of `Photo-Go-Round.app` carries the agent, the wallpaper extension
and the screensaver inside its wrapper. At every launch it installs and restarts
its agent; a Release build also registers the wallpaper and links the
screensaver when they are not there. The Help menu installs or uninstalls any
piece in any build. Nothing is copied out of the bundle.

# Rationale

Until now a Mac got Photo-Go-Round only through Xcode: three `Install …`
schemes, each ⌘R'd by hand, in order. Nobody outside this checkout could install
it, and `pgr_install` was always called scaffolding — Syd, 2026-09-19: "the
application which installs on first launch will eventually replace
pgr_install." One app that installs itself is the smallest step towards
something that can be handed to another person. It also closes the accepted gap
in `Installing.md`, since the app that installs the agent is the one that asks
for Photos.

# Phases

- **Phase 1 — Measure how to embed.** *Built 2026-09-21.* First archive-only,
  then every build, once Syd moved it. See *Phase 1, measured* and *Embedding in
  every build, measured*.
- **Phase 2 — The wrapper.** *Built 2026-09-21.*
  - Server app in `Contents/Helpers/`, appex in `Contents/Library/Wallpaper/`,
    saver in `Contents/Resources/`, on every build.
  - `codesign --verify --deep --strict` passes; a build registers nothing.
- **Phase 3 — "Is it installed", in `PhotoGoRoundInstall`.** *Built 2026-09-21.*
  One pure judgement per product, tested without touching the system.
  - Agent: the job description is this bundle's, and loaded.
  - Saver: a symlink at its name, naming this saver.
  - Wallpaper: registered from this appex, since the appex last changed; and
    whether a running extension of this build is this app's.
- **Phase 4 — The app installs.** *Built 2026-09-21.*
  - `LaunchInstall.run`, in Syd's order: the agent, then nothing until it
    answers, then the wallpaper, then — Release only — the screensaver.
  - A Help menu: Install and Uninstall for Agent, Wallpaper and Screensaver.
  - The spinner and the lockout in both windows; a line per product in the
    `install` log category.
  - The per-user port; `pgr_install start`, `stop` and `--variant`;
    `Scripts/claude-agent.sh`.
- **Phase 5 — Documents.** *Built 2026-09-21.*
  - The port in `CLAUDE.md`, `README.md`, `Installing.md` and
    `photogoroundd.md`; `pgr_install.md` for the new commands; `CLAUDE.md`'s
    log categories name `install`.
  - `Installing.md` leads with *Installing from the app* — what a launch does,
    the Help menu, what each install lays down, Photos, the `install` log
    line, `Scripts/claude-agent.sh` — and keeps the schemes as the development
    route. Its rebuild section records the grey desktop and the re-register.
  - `README.md`'s install table leads with the app; its test count, which had
    drifted from 1,001, is gone rather than updated.
- **Phase 6 — On Syd's Mac.** *Done 2026-09-22.* A Debug run from Xcode, then a
  Release archive in `/Applications`, launched fresh and over itself.
  - *Debug launch, 2026-09-21 22:48, from a clean uninstall:* agent not
    installed → bootstrapped from the app's `Contents/Helpers`, answering 1.2 s
    later on 23172, which is 23000 plus the hash of Syd's short name. Wallpaper
    and saver left to the menu. Help → Install Wallpaper registered from
    `Contents/Library/Wallpaper` in 0.4 s; Help → Install Screensaver laid the
    link into the bundle.
  - *The extension and the saver, sandboxed, reached 23172* — `consumer=
    system-wallpaper` and `consumer=screensaver`, both served 200. Both showed
    photos.
  - **Allow Access killed the agent, 22:53:59: `last exit reason =
    OS_REASON_TCC`.** `tccd` took the request with `subject=
    Sub:{com.sydpolk.photogoround}` — the app, with the agent only the
    responsible process — and found `usage description: (null)`. An agent
    inside an app's bundle is asking on the app's behalf, and the app carried no
    `NSPhotoLibraryUsageDescription`. It does now, in all three configurations,
    with the agent's own words. So the grant is the app's, and Syd's old one,
    recorded against `…server`, did not apply. The two copies' designated
    requirements were identical; the path is what moved the attribution.
  - *After the fix, the same night:* Allow Access prompted, the grant took, and
    the collections appeared. Syd: "that fixed the problem."
  - **The wallpaper went grey after the next ⌘R.** Measured: at 22:58:35,
    while Xcode was still building, `pkd` logged "remove all extension
    instances" for `…wallpaper.debug.extension`, because its bundle changed on
    disk; `WallpaperAgent` took the interruption, computed "lifecycle action
    nothing", and never started it again. The launch seven seconds later found
    nothing running, so the running-extension test had nothing to compare.
    **Fixed the same night, Syd: "yes, make that change":** every build now
    also registers again when its own registration is older than the appex —
    `Standing.stale`. Help → Install Wallpaper brought it back meanwhile.
  - **Grey again after the next ⌘R, 23:03: the rebuild dropped the
    registration itself**, not only the running extension — `pluginkit -m`
    listed nothing, and the launch found "not installed", which a Debug build
    left to the menu. **Fixed, Syd: "yes, re-register it in any build":** a
    launch now registers again when nothing is registered and
    `WallpaperAgent`'s store still names this extension as the choice. The store
    is `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`,
    private; the choice was at `AllSpacesAndDisplays / Desktop / Content /
    Choices / [0] / Provider`, and under `SystemDefault` the same.
  - *Confirmed on the next ⌘R, 23:09:17:* "not installed", then "not
    registered, but it is the chosen wallpaper", registered in 0.14 s,
    `WallpaperAgent` restarted. Syd: "wallpaper came back on its own".
  - *Debug taken off by the Help menu, 23:44:* Uninstall Screensaver removed
    the link and stopped `legacyScreenSaver`; Uninstall Wallpaper unregistered
    `…wallpaper.debug.extension` and restarted `WallpaperAgent`; Uninstall
    Agent booted out `….server.debug` and removed its plist.
  - *Release archive, first launch from `/Applications`, 23:45:19:* agent not
    installed → bootstrapped from `/Applications/Photo-Go-Round.app/Contents/
    Helpers`, answering 2 s later; wallpaper not installed → registered from
    `Contents/Library/Wallpaper` in 0.1 s, `WallpaperAgent` restarted; saver
    not installed → linked into `/Applications/…/Contents/Resources`.
  - **Adding 26 albums from the Release app said "The request timed out",
    23:46; the agent added all 26 anyway** — `201 POST /v2/sources` at 23:46:42,
    then "nothing new; 26 already listed" on the second Done. The panel's
    session had `AgentSession`'s defaults: a 15-second gap between packets,
    under its 20-, 30- and 120-second limits, and a 60-second whole answer
    under the 120. The agent sends nothing until it is done, so the gap was
    the bound. **Fixed:** `AgentSession.make(above:)`, used by the panel with
    its longest limit; `AgentSessionTests` failed first, then passed. A
    transport failure now logs a `panel:` line; it had logged nothing.
    *Not fixed:* why the add took more than fifteen seconds on an agent a
    minute old — `TODO.md`'s slow-Photos-after-startup item.
  - *No Photos prompt for the Release app*, Syd noticed. Its designated
    requirement is the Debug app's — identifier `com.sydpolk.photogoround`,
    the same Apple Development certificate — so the grant from the Debug run
    applies; the add reading all 26 albums is consistent with that.
  - *Release archive replaced in `/Applications` and launched over the first
    install, 23:56:30:* agent same → restarted, answering in 1 s; saver same,
    left alone — the link into `/Applications` survived the app being replaced;
    wallpaper "not installed" → registered, `WallpaperAgent` restarted.
    **Replacing the app dropped the extension's registration, as a rebuild
    does**, so a Release launch over itself always re-registers — Syd's
    "unregister, re-register, tickle", by the "not installed" rule.
  - *Confirmed, 2026-09-22:* Syd, "app, screensaver, wallpaper, and dashboard
    all show the pics" from the Release app in `/Applications`.
  - *Clean install, 2026-09-22 00:09:* every agent uninstalled, the app moved
    out, Release storage moved to the Trash, both Photos grants reset with
    `tccutil`. First launch: agent bootstrapped and answering in 1.5 s;
    wallpaper "not registered, but it is the chosen wallpaper" → registered;
    saver linked. System Settings, open across the install, listed the saver
    only once reopened — now in `Installing.md`. Allow Access raised the
    prompt, naming the app; after choosing albums the app, the wallpaper and
    the screensaver all showed photos.

# Design Decisions

- **What a launch does.** Syd, 2026-09-21:
  - Every build: install the agent if it is not, and restart it — "restart the
    agent on every app launch". "The agent has to be up and running first", so
    nothing else happens until it answers on `/v1/dashboard`.
  - Every build: register the wallpaper again when the extension running is not
    this app's — "we are going to have to detect whether or not the wallpaper
    agent that is running matches the one in the app bundle". And when its
    registration here is older than the appex, since a rebuild leaves nothing
    running — "yes, make that change". And when it is not registered at all but is
    still the chosen wallpaper — "yes, re-register it in any build".
  - Release only: "install wallpaper if not installed", and "lay down the
    screensaver symlinks if not there".
- **The Help menu always installs.** Syd, 2026-09-21: "the menu always
  installs". Uninstall removes this build's copy, never another configuration's,
  and "uninstalling unregisters".
- **Every build carries all three.** Syd, 2026-09-21: "the binaries are always
  in the app bundle and you can always install/uninstall via the menu."
- **Nothing is copied out of the app bundle.** Syd, 2026-09-21: "the binaries
  should NOT be copied out of the app bundle." The agent's plist points into the
  bundle, the saver is a symlink into it, and the extension is registered where
  it sits — Syd: "registering the extension from inside the app is what I
  meant."
- **A build never registers the extension.** Syd, 2026-09-21: "only if you say
  'install wallpaper'". So the appex sits in `Contents/Library/Wallpaper`, where
  LaunchServices does not look.
- **An app replaced at the same path needs little.** Syd, 2026-09-21: the
  wallpaper unregistered, registered again and `WallpaperAgent` tickled; the
  screensaver "nothing needs to change"; the agent stopped and started.
- **The port is a base per build variant plus a hash of the user name.** Syd,
  2026-09-21: "If there is a collision, let the agent pick one, and we fall back
  to the existing mechanim." Bases 20000, 23000 and 26000, 3000 wide, FNV-1a of
  the short name. *The numbers and the hash are Claude's.*
- **Claude's agent is Syd's to run.** Syd, 2026-09-21: "it's ok to leave a
  script that sets up the launchdaemon for the claude agent and ask me to
  instsall/uninstall/start/stop it." `Scripts/claude-agent.sh`; a per-user
  LaunchAgent, not a daemon. Launching a Claude-built app would install it too,
  so Claude never launches one.
- **The separate build and `Install …` schemes stay.** Syd, 2026-09-21: "we
  still need the separate build/installer targets." `pgr_install` is the
  development installer and shares `PhotoGoRoundInstall` with the app.
- **"Is it installed" is by path and time, never by version number.** A rebuild
  keeps its version. *Claude's choice.*
- **A replaced appex is caught by `ctime`, not by code hash.** The public API
  reports the file's hash, not the running code's. Measured 2026-09-21.
  *Claude's choice.*

# Background

- **The embed was dropped on 2026-09-15** — Syd: "yes, drop the embed." —
  because every build or run of the app registered the extension. Embedding
  outside `Contents/Extensions` keeps that decision.
- **`PLAN.md` already said the app installs the agent on first launch**
  (2026-09-10). This plan is that, widened to all three products.
- **The app is not sandboxed**, so it can write `~/Library/LaunchAgents` and
  `~/Library/Screen Savers` and run `launchctl` and `pluginkit`.

# Detailed discussions

## Decisions reversed on the way, 2026-09-21

The plan changed shape several times in one day, each time on Syd's word. What
the Design Decisions said before, in order, so the reversals stay readable:

> - **What a launch does — Syd, 2026-09-21, superseding the launch bullets
>   below.** *Under discussion; not built.*
>   - First time, all variants: "Pick a port and write out a preference";
>     "Install and launch agent at that port". Release only: "install
>     wallpaper", "install screensaver".
>   - Existing install: "Read the saved port"; "If the agent is not installed
>     install it"; "Start the agent on the saved port"; "if the wallpaper is
>     running reinstall it"; Release: "install wallpaper if not installed and
>     running", and "lay down the screensaver symlinks if not there".
>   - **"If the wallpaper is running reinstall it" becomes "if the one running is
>     not this app's".** Syd, 2026-09-21: "we are going to have to detect whether
>     or not the wallpaper agent that is running matches the one in the app
>     bundle". *Claude's reading:* the extension process — not macOS's
>     `WallpaperAgent` — matches when it runs from this app's appex and started
>     after that appex's executable last changed, the same `ctime` test the agent
>     gets. Syd, the same day: "it's not a disaster to unregister and reregister
>     the wallpaper extension on every app launch though." *Claude's reading:*
>     the test is preferred, and re-registering on every launch is the
>     acceptable fallback if the test cannot be made reliable.
>   - **The agent is restarted on every launch.** Syd, 2026-09-21: "yes, restart
>     the agent on every app launch", and, of Claude's worry about an agent that
>     had exited cleanly: "why do we care how it exited? It's not supposed to
>     exit". *Replaces "a loaded job that is not running is current".*
>   - **The port: a base per build variant, plus a hash of the user name.** Syd,
>     2026-09-21: "use three different base addresses based on build variants,
>     and then add a hash of the user name to it to come up with the port. If
>     there is a collision, let the agent pick one, and we fall back to the
>     existing mechanim." So the fixed 9427/9428/9429 go, and "pick a port and
>     write out a preference" is this number, published as the agent publishes
>     today. *Claude's to settle:* the bases and range, below the kernel's
>     ephemeral range at 49152, and a hash that is stable across processes —
>     not Swift's `Hasher`, which is seeded per process.
>   - Claude's own agent: Syd, 2026-09-21, "it's ok to leave a script that sets
>     up the launchdaemon for the claude agent and ask me to
>     instsall/uninstall/start/stop it". *Claude's reading:* a per-user
>     LaunchAgent like the others, not a daemon, and the script is Syd's to run.
> - **Every build embeds; only Release installs by default.** Syd, 2026-09-21:
>   "the difference between Claude/Debug and Release is the Release installs the
>   binaries by default, and the other two don't, but the binaries are always in
>   the app bundle and you can always install/uninstall via the menu."
>   *Supersedes the two bullets below, the same day; they stay until the change
>   is built.*
> - **Only an archive embeds, in any configuration.** Syd, 2026-09-21: "All
>   versions of the app will see if the other bits are in its bundle, and if they
>   are not already installed will install them. The only way for that to happen
>   is if you Archive the build." A Debug archive installs the Debug identities.
>   *Revised the same day from "only a Release build embeds".*
> - **An ordinary build, ⌘B or ⌘R, in any configuration, carries nothing.** Syd,
>   2026-09-21: "archived only is fine." So running the app from Xcode installs
>   nothing, and Claude can still build and run it.
> - **The app installs what it carries, not what its configuration says.** No
>   configuration check in code: a wrapper with nothing in it installs nothing,
>   which is what makes Debug inert.
> - **Install only when it differs.** Syd, 2026-09-21: "only when it differs."
>   A relaunch of an unchanged app changes nothing on the system.
> - **"Differs" is by content or path, not by version number.** A rebuild keeps
>   its version, so a version check would miss it. *Claude's choice.*
> - **An agent replaced under itself is caught by `ctime`, not by code hash.**
>   The public API reports the file's hash, not the running code's; the kernel's
>   is private. Measured 2026-09-21. *Claude's choice.*
> - **The separate build and `Install …` schemes stay.** Syd, 2026-09-21: "we
>   still need the separate build/installer targets." `pgr_install` is the Debug
>   installer and shares `PhotoGoRoundInstall` with the app.
> - **The agent's binary stays in the app bundle; its plist goes to
>   `~/Library/LaunchAgents`.** Unchanged from `PLAN.md`, 2026-09-10.
> - **Nothing is copied out of the app bundle.** Syd, 2026-09-21: "the binaries
>   should NOT be copied out of the app bundle." For the agent, installing is
>   only a LaunchAgent plist pointing into the bundle; the saver and the
>   wallpaper "should lay down symlinks back to the app bundle". *Replaces "the
>   saver is copied out", the same day.*
> - **A build never registers the extension; only "Install Wallpaper" does, and
>   uninstalling unregisters.** Syd, 2026-09-21, asked whether every Debug build
>   may register it: "only if you say 'install wallpaper'", then "and
>   uninstalling unregisters". So the appex sits in `Contents/Library/Wallpaper`,
>   where LaunchServices does not look. See *Embedding in every build, measured*.
> - **The wallpaper needs no symlink: it is registered from inside the app.**
>   Syd, 2026-09-21: "registering the extension from inside the app is what I
>   meant." Only the saver gets a symlink, in `~/Library/Screen Savers`.


## Why Archive, and what that costs

*Superseded 2026-09-21 by embedding in every build; kept as the record.*

*Copy only when installing* (`runOnlyForDeploymentPostprocessing = 1`) runs a
copy phase only when `DEPLOYMENT_POSTPROCESSING` is on, which is Archive and
`xcodebuild install`. Ordinary builds in any configuration skip it. That gives
the archive-only embed without a script phase, which the project has none of
since 2026-09-19 and should keep having none of.

**What it costs:** a build run with ⌘R from Xcode is not an archive, so it
carries nothing and installs nothing, in any configuration. **Accepted 2026-09-21** — Syd: "archived only is fine." The
alternatives, kept because they were weighed:

1. **Embed in every configuration and strip after the copy when not Release.**
   Needs a script phase, which the project has none of. And Xcode may register
   the appex with `pkd` before the strip runs; Phase 1 would measure that.
2. **A separate Release-only app target** that embeds unconditionally. A second
   app target to keep in step with the first, for one configuration.

Neither is attractive; Archive is the route unless Phase 1 shows it fails.
If it does, the question goes back to Syd rather than falling to one of these.

**Target dependencies are not conditional either.** The app will depend on the
server, the saver and the extension in every configuration, so a Debug build of
the app builds all three. Building the extension alone produces a bare appex,
which `Build Plan.md` measured on 2026-09-15 does not register. So the extra
builds cost time and nothing else. Phase 1 confirms it.

## Phase 1, measured

Measured 2026-09-21 by archiving the `Photo-Go-Round` scheme in `Claude` into
`~/.claude/build/photo-go-round`, with `pluginkit -m -A -v` recorded before.

- **An ordinary build embeds nothing.** A clean `Claude` build of the app
  produced a wrapper of `Info.plist`, `MacOS`, `PkgInfo` and `_CodeSignature`
  only. `pkd` unchanged. It does build the server, the saver and the appex
  beside it, as expected — target dependencies are not conditional.
- **An archive embeds all three and registers nothing.** `Contents/Helpers/Photo-Go-Round Server.app`,
  `Contents/Extensions/Photo-Go-Round Wallpaper.appex`,
  `Contents/Resources/Photo-Go-Round Screensaver (Claude).saver`. `pkd`
  unchanged, so there was nothing to unregister. `codesign --verify --deep
  --strict` passes. No warnings.
- **Four things the first attempts got wrong, each fixed:**
  - **The saver's product reference is named `… (Debug).saver` whatever the
    configuration**, so a `Claude` archive failed looking for it. The embed uses
    its own file reference, `Photo-Go-Round Screensaver$(SAVER_NAME_SUFFIX).saver`.
  - **The archive also held a loose `Photo-Go-Round Server.app`**, beside the
    app, because the Server target installed itself. `SKIP_INSTALL = YES` on it
    in all three configurations, as the other embedded targets already had.
  - **Archive validation warned that the server has no app category.**
    `LSApplicationCategoryType` is `public.app-category.photography` in
    `agent/Info.plist`.
  - **Archive validation warned the appex was embedded outside the app**, with
    `dstSubfolder = Product` and `$(CONTENTS_FOLDER_PATH)/Extensions`: `Product`
    resolves against `BUILT_PRODUCTS_DIR`, which under Archive is not where the
    app is installed. All three phases now use wrapper-relative destinations —
    `dstSubfolder = Contents` with `Helpers` or `Extensions`, and
    `dstSubfolder = Resources`. The existing `Photo-Go-Round Wallpaper Host`
    phase still uses the `Product` form, and is never archived.

## Embedding in every build, measured

Measured 2026-09-21, after Syd moved embedding from archive-only to every
build, with `pluginkit -m -A -v` recorded before.

- **Every macOS app Xcode builds is registered with LaunchServices, and nothing
  turns it off.** Swift Build's `ProductPostprocessingTaskProducer` adds
  `lsregister -f -R -trusted` on the product whenever the build components
  include `build` and the platform is `macosx`; no build setting is consulted.
  LaunchServices then registers whatever sits in `Contents/Extensions` with
  `pkd`. That is the mechanism behind "building the wallpaper host registers
  it".
- **So the appex is embedded in `Contents/Library/Wallpaper` instead.** A clean
  `Claude` build put it there and left `pkd` unchanged.
- **`pluginkit -a` registers it from there anyway**, in two seconds, and
  `pluginkit -r` removes it, back to the recorded baseline. Measured twice.
  *Unmeasured:* whether the Wallpaper pane shows and runs it registered from
  there — the same bytes as from `Contents/Extensions`, but that is Syd's to
  look at.
- **Xcode warned about the placement** — "an ExtensionKit extension and must be
  embedded in the parent app bundle's Extensions directory". The embed uses its
  own file reference typed `wrapper.cfbundle` rather than the product's
  `wrapper.extensionkit-extension`, which describes it truly — a bundle the app
  carries, not the app's extension — and the validation does not run.
  `SKIP_EMBEDDED_FRAMEWORKS_VALIDATION` would also have silenced it, for every
  embed. The deep signature check still passes.
- **The three copy phases no longer have *Copy only when installing*.**
- **A symlinked screensaver loads.** Syd, 2026-09-21: a link in
  `~/Library/Screen Savers` to the `(Claude)` saver inside a Claude-built app
  was listed, and its preview showed "Waiting for Photos" — the saver's own
  empty state, with no agent running. The link pointed into `~/.claude`, not
  `/Applications`; a sandbox that reads a home folder's bundle is expected to
  read `/Applications` too, but that is not yet measured.
  - **The first try was void.** The Debug saver was installed and loaded, and
    every configuration's saver has the principal class `PGRScreenSaverView`,
    so the host ran Debug's code against Debug's agent. Uninstalling first
    stopped the hosts and cleared it. `TODO.md` has the class-name defect.

## "Differs", product by product

*Partly superseded 2026-09-21: the saver is a link now, not compared by
signature, and the agent is restarted on every launch rather than judged by the
age of its process. The measurements below still stand.*

*Built 2026-09-21* as `Standing` and a `standing(of:)` on each of
`AgentInstall`, `SaverInstall` and `WallpaperInstall`, answering `.current`,
`.missing` or `.differs(why)`. Every fact comes through an injected closure, as
the modules' `plan` already did, so `StandingTests` asks nothing of the Mac. The
`why` is for the log line Phase 4 writes.

**Agent.** Three ways to differ, checked in order:

1. **The plist is not the one this bundle would write.** Decoded as a
   `JobDescription` and compared whole, not just the program path — so a job
   an older app wrote, with `Background` where it is now `Adaptive`, differs
   too. A different program path is named in the reason: that is another copy
   of the app.
2. **launchd does not have the job loaded.**
3. **The running process started before its binary last changed.** The plist
   points into the app, so replacing the app leaves the plist exactly right
   under an agent still running the old binary.

A job loaded and not running is current: it exited cleanly, which is somebody's
choice, and an app launch is not a reason to start it. Any fact that cannot be
read leans towards installing — a reinstall costs a restart; a miss leaves old
code running.

**How the third is measured changed on the way, 2026-09-21.** The plan said to
compare the running process's executable with the carried one. Measured with a
probe in Claude's scratch space — a signed binary running, then replaced under
it:

- `SecCodeCopyGuestWithAttributes` for the pid, with or without
  `kSecCSDynamicInformation`, reported the **replacement's** code hash. It reads
  the file now at the path, not the code that is running. Useless for this.
- `csops(CS_OPS_CDHASH)` kept the original's — the kernel's own record. But it
  is not in the public SDK, and Syd has named app-store-friendly apps as a
  future, so it was not used.
- **The binary's `ctime` against the process's start time** worked, and is
  public: `stat` and `sysctl(KERN_PROC_PID)`. Copying or moving a file into
  place sets its `ctime` to that moment, and no copy can preserve it. A binary
  given a 2020 modification date and moved over the running one read as
  changed; so did `ditto` over it in place. Modification dates would have
  missed the first: they survive a Finder copy.

The false positive is something touching the binary's inode after the agent
started — a `chmod`, an extended attribute — and it costs one needless restart.

**Saver.** The code signature's hash (`kSecCodeInfoUnique`) of each bundle, not
a SHA-256 of the executable as first planned. The code directory seals the
executable, `Info.plist` and `CodeResources`, which seals everything else, so
one hash covers the whole bundle. Either side unsigned or unreadable differs.
On a difference `SaverInstall.apply` copies, replacing only the bundle of its
own name, and stops `legacyScreenSaver` and `ScreenSaverEngine`.

**Wallpaper.** Current when a registration of this identifier comes from this
very appex — usually so already, since LaunchServices registers an embedded
extension for an app in `/Applications`. Registered only from elsewhere
differs and names where; not registered is missing. On either,
`WallpaperInstall.apply` removes what `plan` judged dead and registers this
one. Another configuration's identifier never counts as this one's.

## Two copies of the app

If two copies of one configuration exist — one in `/Applications`, one on a
disk image — each launch rewrites the agent's plist to point at itself, and
re-registers the wallpaper when the running extension is the other's. The last
one launched wins. The saver link is left pointing at whichever copy laid it
down, since a Release launch links it only "if not there"; the Help menu's
Install moves it. Not guarded against.

## What happens at launch, in order

`LaunchInstall.run`, built 2026-09-21:

1. **The agent.** Missing, or described differently from how this bundle would
   write it: installed (bootout, plist, bootstrap). Otherwise restarted with
   `launchctl kickstart -k`. Every build.
2. **Wait for it to answer**, up to thirty seconds, polling `/v1/dashboard` on
   this build's port. One that never answers fails the other two with that
   reason, and they are not installed. An app that carries no agent waits for
   nothing.
3. **The wallpaper.** Every build: if an extension of this build's identifier
   is running from another appex, or started before this appex last changed,
   it is registered again — unregistered, waited on until `pkd` drops the
   record, registered, `WallpaperAgent` restarted. A Release build also
   registers it when it is not registered here, or was registered before the
   appex last changed.
4. **The screensaver, Release only.** Linked into `~/Library/Screen Savers` if
   nothing is at its name. A copy or another copy's link is left, and logged.

Each step runs off the main actor, on a Dispatch thread, because it blocks; the
windows show the spinner with what is being done and disable the controls until
it finishes. One product's failure is logged and does not stop the next.

**The mismatch test was preferred over re-registering on every launch**, which
Syd allowed ("it's not a disaster"). A re-registration restarts
`WallpaperAgent`, and the desktop picture is redrawn; the test keeps that to
launches where something changed. If the test proves unreliable on his Mac, the
fallback is one line.

**Unmeasured:** that a sandboxed saver and extension get the same `NSUserName()`
the agent does, which the port depends on; that `ps -o comm=` gives an
extension's full path, as it does an agent's; that `kickstart -k` restarts the
agent within the thirty seconds on his Mac.

The Photos prompt comes from the app as it does today. Installing the agent
from the same launch closes the gap `Installing.md` accepts: the app that
installs the agent is the app that asks.

## Logging

Each product logs at least one line per launch, whatever was done: what was
found, and what was done about it. Category `install`, subsystem
`com.sydpolk.photogoround`. "saver: already there, left alone" is the line that
answers "did the app touch my saver?" later.

## Uninstall

The Help menu's Uninstall removes this build's copy only —
`Uninstall.plan(variants: [BuildVariant.current])` — so a Debug app never takes
a Release agent down. `pgr_install uninstall` and `Scripts/uninstall.sh` still
remove every configuration's by default; `--variant` narrows them.

Two defects fixed on the way, 2026-09-21: an installed saver is found without
following a link, so one pointing into a deleted app is still removed; and the
extension process is stopped by its bundle path, not its name, which every
configuration shares.

## Claude's constraints while building this

**Claude never launches a built app**, in any configuration: since 2026-09-21
every launch installs and restarts its agent, which bootstraps a launchd job on
Syd's Mac. Claude's own agent is installed, started, stopped and removed by
`Scripts/claude-agent.sh`, which Syd runs when asked.

Measurements that register with `pkd` use the `Claude` identity, from
`~/.claude/build/photo-go-round`, and unregister afterwards; `pluginkit -m -A`
is recorded before and compared after.

# References

- `Plans/Build Plan.md` — *The embedding question, answered 2026-09-15*
- `Plans/Xcode - Separate Build and Run.md` — the `Install …` schemes and `PhotoGoRoundInstall`
- `Plans/PLAN.md` — the agent installs in `~/Library/LaunchAgents`, 2026-09-10
- `Documentation/Installing.md` — *The gap this leaves, which is accepted*
- `Documentation/pgr_install.md`
- Xcode build setting `DEPLOYMENT_POSTPROCESSING`; copy phase "Copy only when installing"
