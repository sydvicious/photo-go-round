# Summary

The desktop picture: one photograph per display, changed every thirty minutes, sized to fit, with the rest filled in the colour set in System Settings. It is a client of the agent like every other surface, hosted by the Mac app first and moved to a binary of its own later. Subordinate to `PLAN.md`, which places this in Phase 7.

# Rationale

The wallpaper is the other half of the original complaint: Apple's picker chokes on a large folder and falls back to the Golden Gate image unprompted. With the screensaver showing photographs overnight, the wallpaper is the last Mac surface that still depends on Apple's broken selection. It is also the first surface that needs a *file* rather than bytes, and the first that runs with nobody watching it for hours at a stretch. Both are worth getting right while it is small.

# Phases

- **Phase 1 — The wallpaper in the app.** A loop that asks the agent for a picture for each display, writes it to that display's file, and makes that file the desktop. The app starts it at launch.
  - First, find out whether leaving `.fillColor` out keeps the fill colour set in System Settings, or whether it has to be read with `desktopImageOptions(for:)` and passed back.
  - Also first, find out whether setting the same URL again with new contents redraws the desktop. The answer decides between one file per display and two alternating files.
  - Aspect fit in the System Settings fill colour, every thirty minutes, and the desktop left alone when there is nothing to give it.
  - Store the time each display's picture changed, in the wallpaper's own preference domain, and change a display only once that time is thirty minutes old — at launch as much as at any other moment.
  - Put each display's file back at launch and when displays or Spaces change.
  - An *Also set wallpapers* checkbox in the app; the loop runs only while it is ticked.
  - Before any of it is built, look at what System Settings › Wallpaper needs from us — TODO.md.
  - The agent's served line names the display as well as the consumer, so each display's changes can be counted from the agent's side.
  - **Exit gate:** the app is left open for an evening, every display changes every thirty minutes, and the agent's log shows `consumer=wallpaper` twice an hour per display.
- **Phase 2 — Its own binary.** The same loop in a process of its own, installed per user as a plist in `~/Library/LaunchAgents`, with the binary staying inside the app bundle. Designed when Phase 1 has run; see *Its own binary*.

# Design Decisions

*Syd's, 2026-09-10, in his words where he gave them*

- **"Make it change every 30 minutes."**
- **"we should store (per display) a preference storing the time the picture was changed for that display. And the image should not be changed before the time interval (initially 30 minutes) if it has previously been saved, even if the binary was just started up."** The interval is measured per display from that stored time, across launches, not from when the process started.
- **"give the wallpaper its own domain. Actually two, one for prod and one for qa"** — corrected at once: **"I meant 'prod' and 'dev'."** One domain per existing deployment, and the agent's domain is not touched; Syd: "the agent won't care about this preference."
- **The names: "com.sydpolk.photogoround.wallpaper.{dev|prod}"** — `com.sydpolk.photogoround.wallpaper.dev` and `com.sydpolk.photogoround.wallpaper.prod`.
- **"Same aspect rules as screensaver."** Shrink or expand with the aspect ratio kept, never cropped: `scaleProportionallyUpOrDown`, clipping off. `PLAN.md`'s *One display mode in v1* already names the wallpaper and the screensaver together.
- **"use the System Settings fill color for now. We may add selecting background color as an option later."** Apple's wallpaper does not default to black, so the space around the photograph is filled with whatever colour the user chose there, not one we pick.
- **"We will add options for both screensavers and wallpapers in addition to sources later."** Nothing in this plan is a preference — *with one exception added the same day, the* Also set wallpapers *checkbox below.*
- **"The agent's job is just to serve pictures."** The wallpaper is a client and the agent does nothing for it but answer `GET /v1/next`.
- **"the agent needs to log when a card is served to a wallpaper, as opposed to a screensaver, or the app."** Already true: every served line carries `consumer=`, and the wallpaper asks as `wallpaper`. See *What the agent logs*.
- **"yes, add display= to the served line."** Built with Phase 1, not ahead of it: "don't make the agent change yet."
- **"yes, put the stored files back at launch."** A launch that is not due fetches nothing, but sets each display's stored file again — so a desktop macOS reverted, or that changed while the app was closed, is ours again at once rather than at the next change.
- **"add an option to the app: a checkbox which says 'Also set wallpapers'."** The wallpaper runs only while it is ticked. See *The* Also set wallpapers *checkbox*.
- **"Add a TODO.md item to see what we need to do in System Settings -> Wallpapers."** TODO.md, *What System Settings › Wallpaper needs from us*.
- **"The app runs it."** For now. **"I am pretty sure that the wallpaper process will end up its own binary"**, **"which will call the agent for the image."**
- **"build it in the app first."**
- **"the agent MUST be installed in ~/Library/LaunchAgents; this needs to support multiple users on the same machine"** — **"at least the database and plist"**, and **"the binary stays in the app bundle."** The wallpaper binary follows the same shape when it arrives.
- **The app is not sandboxed, and that stays true for this work.** Whether it can be is TODO.md's *Sandboxing, and whether the App Store is reachable* — "but not for now."
- **"the app should not need to see the agent's container."** And of the app not seeing the agent's `--container`: **"it's not a gap; it's a design decision."** The wallpaper's files live somewhere of its own.
- **"let's put it in Application Support for now; we will probably have to move it if we want to sandbox."** `~/Library/Application Support/com.sydpolk.photogoround.wallpaper.{dev|prod}/`, named like the wallpaper's preference domains and resolved from the deployment by the wallpaper itself; `MacHostEnvironment` gains nothing.

*Decided before this plan*

- **One file per display, named by the display's UUID**, scoped to the deployment, outside the cache, and never swept. TODO.md, *Design the wallpaper*, 2026-09-09. *That entry put the files in `<container>/wallpapers/`; Syd reversed the location on 2026-09-10 — see the bullet above. The rest of it stands.*
- **An empty library leaves the existing desktop alone.** `PLAN.md`, *The empty state*.

*Proposed by Claude, not decided*

- **The loop lives in `PhotoGoRoundDisplay`**, with the app as its host, so that moving it into its own binary later means writing a new host rather than moving the code.
- **One rule for when to change: which displays are due?** Asked at launch, on wake, and when the loop's sleep ends, after which it sleeps until the next display is due. This replaces a separate rule for launch, one for wake and one for the timer. *Replaces two proposals Syd's stored-time decision overturned: changing the picture at launch, and a wake check against a "last complete round" held only in memory.*
- **Each display's file URL is stored beside its change time**, so a launch that is not due still knows which file each display is showing.
- **A change time in the future, or one whose file is gone, counts as due.**
- **It retries after a minute when a display got nothing**, rather than waiting the full half hour.
- **It puts each display's file back when screens or Spaces change, and otherwise does not fight macOS reverting it.** Launch is the third occasion, by Syd's decision above. *Wallpaper is asserted continuously* is later work.
- **At launch, before putting each file back, it compares the stored file with what `desktopImageURL(for:)` reports and logs any difference.** That is a record of how often the desktop changes while the app is closed, whether macOS reverted it or somebody chose another picture — the evidence *Wallpaper is asserted continuously* says is missing.
- **It asks at each display's native pixel size, as consumer `wallpaper`, with the display UUID.** That gives one consumer row per display, which is the identity the deck already uses.
# Background

`PLAN.md` Phase 7 is one line — "per-screen `NSWorkspace.setDesktopImageURL`, scheduled by the server." `PLAN.md`'s *Wallpaper mechanics and their limits* and *Wallpaper is asserted continuously, never set once* were written before *The service is the interface*. TODO.md's *Design the wallpaper* settled where the files go and left open who runs the loop, which is now answered.

Everything a client needs already exists. `PictureClient` asks the agent at a size and a display. `PictureLayerView.identifier(of:)` turns an `NSScreen` into the UUID the deck keys on. `ConsumerKind.wallpaper` and `Log.wallpaper` were both defined long ago and have no callers yet.

**No surface opens the agent's container.** The app and the saver use `MacHostEnvironment` for its preference domain alone, which is how they find the port; only the agent and `pgr_ctl`, the rig, touch the database and the cache. The wallpaper keeps it that way.

The app is unsandboxed (`ENABLE_APP_SANDBOX = NO` in both configurations), so it can write under `~/Library/Application Support` and call `NSWorkspace` without an entitlement.

**Code was written before this plan and stopped.** On 2026-09-10, a draft of Phase 1 was written and then halted at Syd's direction, because the design had not been read as a plan. It is uncommitted, unbuilt and untested; see *The draft already written*.

# Detailed discussions

## How the design arrived here

Recorded in order, because one step of it was a wrong turn of a kind this project has seen before.

1. Syd asked for wallpapers: every thirty minutes, the screensaver's aspect rules, options later.
2. Claude asked who runs the loop, and recommended the agent. The recommendation rested on `PLAN.md` Phase 7's "scheduled by the server", on the agent being the only process that is always running, and on the agent already holding the bytes.
3. Syd agreed, then reversed it before anything was built: "hang on. that's wrong. the app runs it. The agent's job is just to serve pictures." **The error is worth naming: Phase 7's line predates *The service is the interface*, and Claude weighed it as a current decision instead of checking it against the rule written after it.** It is the same failure as sources-in-the-database, where two stated invariants collided and nobody noticed.
4. Syd asked how wallpaper-changing binaries are actually built on macOS. The answer is below under *How wallpaper binaries are made on macOS*. Syd pointed out that per-user agents in `~/Library` can assume a logged-in session, and that this is where the agent is going.
5. "build it in the app first."
6. Syd, while code was being written: the agent must be installed in `~/Library/LaunchAgents` to support several users on one Mac — the database and the plist per user, the binary in the app bundle.
7. Syd stopped the build: "we should be making a separate plan for wallpapers rather than plunging forward. I don't agree that the 'design in settled' until I can read a good plan and give feedback."
8. Reviewing this plan, Syd pointed out that Apple's wallpaper does not default to black, and decided: "use the System Settings fill color for now. We may add selecting background color as an option later."
9. Syd replaced the proposal to change the picture at launch: "we should store (per display) a preference storing the time the picture was changed for that display. And the image should not be changed before the time interval (initially 30 minutes) if it has previously been saved, even if the binary was just started up."
10. Syd added a TODO item for a menu-bar app as what finally ships: "The full desktop app is useful, but we are probably not going to ship it."
11. Asked where the change times live, Syd: "the agent won't care about this preference", then "give the wallpaper its own domain. Actually two, one for prod and one for qa", corrected to "I meant 'prod' and 'dev'."
12. The domains' names, Syd: "com.sydpolk.photogoround.wallpaper.{dev|prod}".
13. Syd moved the files out of the agent's container: "the app should not need to see the agent's container." What this plan had called a known gap — the app not seeing the agent's `--container` — "it's not a gap; it's a design decision."
14. Claude proposed `~/Library/Application Support/com.sydpolk.photogoround.wallpaper.{dev|prod}/` for the files; Syd raised an alternative: "I guess the wallpapers could be put in their own container in ~/Library/Containers."
15. Syd chose: "let's put it in Application Support for now; we will probably have to move it if we want to sandbox."
16. Syd: "the agent needs to log when a card is served to a wallpaper, as opposed to a screensaver, or the app." It already does, through `consumer=`; it does not log the display, which Claude proposed adding.
17. Syd: "yes, add display= to the served line." Claude read that as a go-ahead to change the agent and began; Syd stopped it before any file changed: "don't make the agent change yet."
18. The plan had asked whether a launch that is not due should put each display's stored file back, on the grounds that it would override anything the user set meanwhile. Syd asked what the problem was; the honest answer was that the next change overrides it within thirty minutes regardless. He noted that a new display gets a new UUID and so a new clock, which the plan already covers; the case in question was the same display with a different picture. Syd: "yes, put the stored files back at launch."
19. Syd asked for the other planning documents to be brought into line with this one, and while that was under way added two things: "add an option to the app: a checkbox which says 'Also set wallpapers'. Add a TODO.md item to see what we need to do in System Settings -> Wallpapers."

## Where the loop runs

**Not in the agent.** The agent serves pictures and does nothing else. A wallpaper loop inside it would make it a consumer of its own queue, give it AppKit, and give it a second job, which is exactly what the agent's `main.swift` argues against: "A service that also answers questions is a service with two jobs, and the second one grows."

**In the app, for now.** The obvious cost is that the wallpaper changes only while the app is open. That is accepted because Phase 2 removes it.

**Why the code goes in the display library rather than the app target.** The loop needs `PictureClient`, `PixelSize` and the display identifier, all of which are already in `PhotoGoRoundDisplay`. If the loop lived in `app/mac/Sources`, Phase 2 would begin by moving it, which is what Phase 2 of `Screensaver Plan.md` had to do for `Shuffle` and `PictureLayerView`. That library already has one AppKit file behind `#if canImport(AppKit)`; the wallpaper's `NSScreen` and `NSWorkspace` code would be a second, and the loop above it would compile anywhere.

**How the app hosts it.** It needs a place that runs once the application has finished launching and lives as long as the app. The app is a SwiftUI `App` with no delegate today, so the smallest host is an `@NSApplicationDelegateAdaptor` whose `applicationDidFinishLaunching` starts the wallpaper. A property on the `App` struct would work but gives no clean moment at which `NSScreen.screens` is known to be ready.

## The *Also set wallpapers* checkbox

Syd, 2026-09-10: "add an option to the app: a checkbox which says 'Also set wallpapers'."

- **Ticked, the wallpaper runs; unticked, it does not.** Unticking stops the loop and leaves the desktop showing whatever it has — the same rule as an empty library, since taking our picture down would mean choosing a replacement for the user. Ticking starts it, and the due rule decides what happens: a display whose stored time is under thirty minutes old gets its stored file back and nothing new.
- **It is the plan's one preference.** Everything else waits for "options … later".
- **Where it is stored — Claude's proposal:** the wallpaper's own domain, `com.sydpolk.photogoround.wallpaper.{dev|prod}`, beside the change times. The agent does not read it, and the Phase 2 binary would read the same key, so moving the wallpaper out of the app does not move the setting.
- **Where it sits — Claude's proposal:** the Settings window, which is the app's one existing place for options, until the menu-bar app exists. It is listed in `app/mac/FEATURES.md` as an app feature.
- **What it defaults to is open.** "Also" reads as opt-in, which is off; on means nobody has to find it. Listed under *Not yet decided*.
- **It is the first way to stop the wallpaper**, which is what the pause control was for. Whether a separate pause is still wanted is folded into that item below.

## How wallpaper binaries are made on macOS

Answered from general knowledge, not from anything measured on this machine or on macOS 27. The Sonoma rewrite of the wallpaper settings is the part most likely to have moved.

- **The hard requirement is the logged-in GUI session.** `setDesktopImageURL` works through the window server and Apple's wallpaper process on the user's behalf, so the caller must be in that user's Aqua session. A LaunchDaemon, which is system-wide and running before anyone logs in, cannot set wallpaper. Whether the process is a login item or a LaunchAgent is a question of packaging, not of what it can do.
- **Third-party rotators generally ship as menu-bar apps launched as login items** (examples from memory: Irvue, Unsplash Wallpapers, Satellite Eyes), calling `setDesktopImageURL` on a timer. The menu-bar item gives a pause control somewhere to live.
- **A per-user LaunchAgent works just as well.** A plist in `~/Library/LaunchAgents` is loaded into the user's `gui/<uid>` domain at login, which is the Aqua session unless `LimitLoadToSessionType` says otherwise — so that key must be left out. launchd starts the process and can restart it with `KeepAlive`.
- **There are no per-user daemons.** launchd reads `~/Library/LaunchAgents` for each user. Daemons come only from `/Library/LaunchDaemons` and `/System/Library/LaunchDaemons`.
- **Since macOS 13 the user is told.** Anything in `~/Library/LaunchAgents` appears under System Settings › General › Login Items › *Allow in the Background*, and the system posts a notification when one is added. It still runs; the user can see it and switch it off.
- **Apple's own rotation is no help.** "Change picture every 30 minutes" in System Settings is done by the system's `WallpaperAgent`, and the animated wallpapers use a private extension point. There is no hook into either.

## Its own binary

Held for Phase 2 and not designed here. What has been said about it:

- It is its own process, and it calls the agent for the image.
- It is installed per user, as a plist in `~/Library/LaunchAgents` — the same shape as the agent. The binary stays in the app bundle, and the plist's `ProgramArguments` points into it.
- It runs in the user's GUI session, which is what lets it call `NSWorkspace`.

Open when Phase 2 is designed: whether it is a bare executable or an `LSUIElement` bundle, whether it carries a menu-bar item (the pause control needs a home), and how the app installs, updates and removes the plist. The app's quit no longer ends the wallpaper at that point, so stopping it becomes a real question.

**The shipping app is probably a menu-bar app, not the full desktop app.** Syd, 2026-09-10: "The full desktop app is useful, but we are probably not going to ship it." That makes a menu-bar app a possible host for the wallpaper, alongside a separate binary, and the natural place for the pause control. Recorded in TODO.md, *A menu-bar app for shipping*. Which of the two runs the wallpaper is Phase 2's decision.

## Several users on one Mac

Nothing in Phase 1 is shared between users, and nothing needs to be:

- Each user's app finds its agent through that user's preference domain, which holds the port that user's agent published. Two users' agents take two different ephemeral ports.
- Each user's wallpaper files are under that user's own `~/Library/Application Support`.
- The desktop being set is the desktop of the session the app is running in.

**Two users never share a checkout.** Syd, 2026-09-10: "I will never have two users on the same machine share repo folders." So `.build/pgr-container` being per checkout rather than per user never puts two users' development data in one place.

## The file on disk

**Why a file at all.** Every other surface is handed bytes and draws them itself. `setDesktopImageURL` takes a URL that the system reads, and keeps reading, for as long as that picture is the desktop. The cache has files, but it is a staging area the deck is free to evict, and a desktop pointing into it would go blank the moment the deck moved on.

**Not in the agent's container.** Syd, 2026-09-10: "the app should not need to see the agent's container." TODO.md's 2026-09-09 entry had put the files in `<container>/wallpapers/`, and this plan first followed it, with `MacHostEnvironment` giving out a `wallpaperRoot` beside `databaseURL` and `cacheRoot`. That made the wallpaper the one surface that had to resolve the agent's storage, and it inherited a mismatch this plan then called a known gap: an agent started with `--container` would store its library in one place while the app, which cannot see that flag, wrote wallpapers under the default. **It is not a gap; it is a design decision** — the app does not see the agent's container, so there is nothing for the two to agree on.

**Where: `Application Support`, for now.** Syd, 2026-09-10: "let's put it in Application Support for now; we will probably have to move it if we want to sandbox." `~/Library/Application Support/com.sydpolk.photogoround.wallpaper.dev/` and `…wallpaper.prod/`: one directory per deployment, named exactly like the wallpaper's preference domains, so the two things the wallpaper owns sit under one name each. Claude proposed it, for these reasons:

- **It is the wallpaper's own storage**, and `Application Support` is where an unsandboxed process keeps files it owns and needs to keep. Not `Caches`, which the system may purge — and a purged file is a blank desktop.
- **It does not depend on `.build`.** Development storage currently sits in the checkout's `.build`, found by walking up from the executable; TODO.md, *Build products out of the repo*, is about moving builds out of there. A directory resolved from the deployment alone survives whatever that decides.
- **It is resolved by the wallpaper, from the deployment**, the same way its preference domain is. `MacHostEnvironment` describes the agent's storage and gains nothing; the `HostEnvironment` protocol is untouched.
- **It is per user**, being under each user's home.
- **Phase 2 inherits it unchanged.** The binary has the same deployment, so it finds the same directory and domain.

**Considered, and held for sandboxing: Syd's "I guess the wallpapers could be put in their own container in ~/Library/Containers."** That would be `~/Library/Containers/com.sydpolk.photogoround.wallpaper.dev/` and `…wallpaper.prod/`. Not chosen for now. A sandboxed wallpaper would have its storage in a real container regardless — Syd: "we will probably have to move it if we want to sandbox" — so that is when the question comes back, with the points below.

- **For it: one convention, not two.** The agent's production storage is already `~/Library/Containers/com.sydpolk.photogoround`, created by an unsandboxed process, so the wallpaper would sit beside it in the same shape. Everything the project owns in production would then live under `~/Library/Containers/com.sydpolk.photogoround*`.
- **For it: it survives sandboxing more gracefully.** If TODO.md's sandboxing item ever goes ahead and a sandboxed wallpaper carries that bundle identifier, the system puts its container at that same path. It would not be a drop-in, though: a real container keeps its files under `Data/`, not at the top.
- **Against it: that directory belongs to the system's container manager.** `~/Library/Containers` is where macOS creates and tracks sandboxed apps' containers. An unsandboxed process making its own directory there works — the agent's production path already relies on it — but it sits in a place with system bookkeeping attached. A container that later appears under the same identifier could collide with it. `Application Support` has no such owner.
- **Neutral: the files never move with the app's bundle and are per user** either way, and both are resolved from the deployment alone.

**Naming.** `<display UUID>.<extension>`, with the extension taken from the served `Content-Type` — `heic` in practice, since `PictureClient` sends no `Accept` and the service's default is HEIC. The system decides how to read the file from its name.

**Written atomically**, so the system never reads a half-written file.

**Never deleted.** `setDesktopImageURL` sets the current Space on one screen, so other Spaces may still point at a file this display showed earlier. If the extension ever changes, the previous file stays behind; deleting it could blank a Space nobody is looking at.

**The unknown that Phase 1 answers first: does rewriting the same URL redraw?** The system may cache the decoded desktop by URL and ignore a call naming the URL it already has, even when the file underneath it has changed. If so, each display alternates between two names (`<uuid>-a`, `<uuid>-b`), which costs one extra file per display and nothing else. It is measured rather than assumed: the first run sets the same name twice and Syd watches whether the desktop changes. Reading `desktopImageURL(for:)` back will not answer it, because it reports the URL whether or not anything redrew.

## The fit

The screensaver's rule expressed as the options dictionary:

- `.imageScaling: NSImageScaling.scaleProportionallyUpOrDown`
- `.allowClipping: false`
- `.fillColor`: the colour set in System Settings — see below.

**The fill colour is the user's, not ours.** The screensaver paints black because it draws its own view. The desktop has a fill colour of its own, chosen in System Settings › Wallpaper when the picture is set to fit, and Apple's default is not black. Syd, 2026-09-10: "use the System Settings fill color for now. We may add selecting background color as an option later."

**There is no public system-wide preference to read.** The fill colour belongs to each desktop, not to the system as a whole. Since Sonoma it is stored in a private store under `~/Library/Application Support/com.apple.wallpaper/`, whose format is undocumented and has changed before. Nothing here reads it.

**Two public ways to keep it, and which one works is measured first in Phase 1:**

- **Leave `.fillColor` out of the options** and let the system choose. The fewest lines, if the system keeps the colour the desktop already had. Unknown: it may instead fall back to a default of its own.
- **Read it back and pass it on.** `NSWorkspace.shared.desktopImageOptions(for:)` returns the current desktop's options, including `.fillColor` when one is set. Reading it before each set and passing it back unchanged carries the user's colour across every change. Unknown: whether a colour chosen in the post-Sonoma Wallpaper settings shows up through that call at all.

The first is tried first, because if it works there is nothing to carry. The measurement is one probe Syd runs, printing `desktopImageURL(for:)` and `desktopImageOptions(for:)` for each screen, then the same after a change with `.fillColor` left out. Reading his desktop's settings from here would be looking at his machine, so the probe is his to run.

**If neither keeps it**, the fallback is a colour of our own until the background colour option exists — which would be a decision for Syd, not a default to slip in.

The agent never enlarges — `PhotoRenderer` returns a small original at its own pixels — so the system does the enlarging, exactly as the screensaver's `AspectFit` does. `PLAN.md`'s *Beyond 0.1* holds the upscale cap and the other fits, and Syd's "options later" covers them.

**Asking at the display's native pixels.** `screen.convertRectToBacking(screen.frame)` gives the size in pixels, which is what the box on the wire is measured in. A 5K display asks at 5120×2880, so a HEIC of a few megabytes arrives and is written once per half hour, which is negligible.

## Timing

- **Every thirty minutes per display, measured from that display's stored change time.** See *The time each display last changed*. The interval is a `Duration` constant beside `Shuffle.defaultDwell` today, not a preference.
- **Not at launch, unless a display is due.** "At start, straight away" was Claude's proposal, on the grounds that a wallpaper which waited half an hour would look broken. Syd overturned it the same day: "the image should not be changed before the time interval (initially 30 minutes) if it has previously been saved, even if the binary was just started up." The grounds survive in a narrower form: a display with no stored time — the very first run, or a monitor never seen before — is due, so the first launch still changes every display at once.
- **One question, asked every time: which displays are due?** At launch, on wake, when the loop's sleep ends, and when a display appears. Each due display gets a new picture, and the loop then sleeps until the earliest stored time plus the interval. This replaces the earlier design's in-memory "last complete round" and its separate wake check, which were two answers to the same question.
- **Across sleep, by the wall clock.** On `NSWorkspace.didWakeNotification` the question is asked again, so a Mac that slept through a change makes it when it wakes. This does not rely on a sleeping `Task.sleep` noticing the time that passed, which has not been measured.
- **Displays keep their own schedules.** Two displays that last changed at different times stay apart, and nothing pulls them back into step. A display unplugged and plugged back in picks up its own schedule, because its UUID is the key.
- **A retry a minute later when a display got nothing**, whether from an empty library or no agent. Its stored time is left alone, so it stays due. Nothing goes blank while it waits, so there is no reason to match the screensaver's three seconds.
- **One request in flight at a time.** An event that arrives while a display is being changed lets that change finish.

`PLAN.md` suggested a `DispatchSourceTimer` checking the wall clock. A cancellable `Task` loop that works out the next due time on every event does the same job and matches how `Shuffle` is built.

## The time each display last changed

Syd, 2026-09-10: "we should store (per display) a preference storing the time the picture was changed for that display. And the image should not be changed before the time interval (initially 30 minutes) if it has previously been saved, even if the binary was just started up."

**What is stored, keyed by display UUID:** the time that display's picture last changed. Claude proposes storing the file's URL beside it. The name is not fixed: the extension follows the served type, and the redraw question may make each display alternate between two names. A launch that is not due has changed nothing, but it still needs to know which file each display is showing so it can put it back at that launch and on Space and display changes.

**Written only after the desktop has been set.** If the fetch failed or the set threw, the old time stays, so the display stays due and is retried.

**Where it is stored: a preference domain of the wallpaper's own — two of them, one per deployment.** Syd, 2026-09-10: "give the wallpaper its own domain. Actually two, one for prod and one for qa", then "I meant 'prod' and 'dev'." The obvious places were each ruled out by a rule already written down:

- **Not the agent's preference domain.** TODO.md, *Settings endpoints, and preferences as a black box*: "the agent's preferences should be a black box." The wallpaper is a client and must not write there.
- **Not `UserDefaults.standard` in the app.** The app's bundle identifier is `com.sydpolk.photogoround`, which is also the production agent's preference domain. So the app's standard defaults *are* the production agent's domain, and a development run would write wallpaper state into it.
- **Not the database.** `PLAN.md` puts state in the database and preferences in `UserDefaults`, and a change time is state rather than something a person set. But the database is private to the agent.

**Two domains, following the two deployments**, `.production` and `.development` — the same split that keeps a development run off a real library everywhere else. The wallpaper resolves which one from the deployment, in one place, together with its directory; `MacHostEnvironment` is the agent's storage and is not involved. Syd named them: `com.sydpolk.photogoround.wallpaper.dev` and `com.sydpolk.photogoround.wallpaper.prod`. Unlike the agent's, whose production domain carries no suffix, both of these say which deployment they are.

It becomes the Phase 2 binary's own domain when the wallpaper moves. Like every preference domain it is per user, and because the app is unsandboxed it reaches it through `cfprefsd` normally — the screensaver's empty-suite problem does not arise.

**Considered and not taken: the file's own modification date.** Each display already has one file, written when its picture changes, so its modification date would be that time with no second store to keep in step. Its costs were that anything rewriting the file's date — a restore from backup, a copy that does not preserve it — would move the schedule, and that it records when the file was written rather than when the desktop was set. Syd chose a preference domain.

**Edge cases, all Claude's proposals:**

- **A stored time in the future** — the clock was set back, or the preferences came from another Mac — would never come due until the clock caught up. It counts as due.
- **A stored time whose file is gone** — the wallpaper's directory cleared by hand — leaves the desktop pointing at nothing. It counts as due.
- **A display with a stored time that is not due, at launch.** Nothing is fetched, and its stored file is set on it again. Syd: "yes, put the stored files back at launch."

**Several users:** each user's domain is their own, so each user's schedule is their own too.

## Displays and Spaces

`setDesktopImageURL` sets the *current Space* on *one screen*. Two events therefore leave a display showing something that is not ours:

- **Switching to a Space** that has never been given our file.
- **Plugging in a display**, or changing its arrangement.

At launch, on `activeSpaceDidChangeNotification`, and on `NSApplication.didChangeScreenParametersNotification`, each attached display is given its current file again — no request to the agent, no card spent. A display that has never had a picture, such as a monitor just plugged in, is given one.

**Launch is on the list by Syd's decision**, and it covers a case the other two cannot: the desktop changing while the app was closed. The display is the same monitor with the same UUID, so its stored clock still says it is not due and nothing else would notice until its next change. Putting the file back fixes a macOS reversion at once. It also overrides a picture somebody chose while the app was closed — but the next change would override it within thirty minutes anyway, so the difference is only in how long their choice lasted.

**The cost, stated plainly: this overrides a picture the user chose on that Space.** If someone sets their own wallpaper on Space 3 and switches back to it, it becomes ours again. That is milder than the reassertion `PLAN.md` describes, and it is still fighting the user in a small way. The pause control `PLAN.md` names is the answer, and it is not in this plan.

**Not in this plan: putting ours back when macOS reverts to the default on its own.** *Wallpaper is asserted continuously, never set once* is a real observation and a real design, with a heuristic for not fighting the user that needs its own argument. It is listed under *Not yet decided*.

## An empty library, a missing agent, and the log

- **A `204`, or no agent at all: the desktop keeps what it has**, whether that is our last picture or something the user chose. The retry follows a minute later.
- **Failures are described in `Shuffle`'s own words** — `no photos`, `no agent: …`, `not answering: …` — by reusing `Shuffle.trouble(from:)` instead of writing the mapping a second time. That means taking `private` off it.
- **Logged when they change, not every time.** A retry every minute with the agent down would otherwise be a line a minute all night. A new trouble is `.notice`, a repeat is `.debug`, and recovery is one `.notice`. This is the same rule `Shuffle.note` follows.
- **Every change is one `.notice` line**: the display, card, deal, the pixels served and asked for, and the file name. That is two lines an hour per display, and it is the line the exit gate is counted from — the lesson of the screensaver's overnight run, whose `.info` line had evaporated by morning.
- **A display with no UUID is skipped and says so**, because it has no file name. `DisplayShuffles` adopts the sole identified display in that case; the wallpaper has no reason to, since it asks per screen rather than per view.
- **After each set, the URL the system reports is compared with the one just set**, and a mismatch is logged. It is cheap, and it is the first place to look when a desktop does not change.

Category `wallpaper`, lines prefixed `wallpaper:`, as `saver:` is for the saver.

## What the agent logs

Syd, 2026-09-10: "the agent needs to log when a card is served to a wallpaper, as opposed to a screensaver, or the app."

**That is already there, and nothing in the agent changes to get it.** `PictureEndpoint.Served.report()` writes one line per request:

- To the unified log at `.notice`, which persists: `served status=… consumer=… card=… deal=… bytes=… source=… cacheBytes=… queued=… ms=…`.
- To the console, where `consumer` leads the summary after the photograph's name.

`consumer` is whatever the client put on the wire, so the wallpaper asking as `wallpaper` is the whole of it. The screensaver's overnight count in `Screensaver Plan.md` was taken from exactly this line, filtered on `consumer=screensaver`.

**What it does not say is which display — so it gains `display=`.** Claude proposed it; Syd, 2026-09-10: "yes, add display= to the served line", built with Phase 1. The request carries `display=<uuid>` and the endpoint registers the consumer row with it, but `Served` has no field for it and the line never prints it. With one display that costs nothing. With two, the exit gate — twice an hour *per display* — cannot be counted from the agent, only from the wallpaper's own lines. It would also let the saver's per-display loop be checked from the agent's side, the question `Screensaver Plan.md`'s *One instance per display* left open.

The change is small and sits entirely in the agent: a `display` field on `Served`, filled from the query, printed as `display=` in the log line and after the consumer on the console. The UUID is public for the same reason the source id is — a structural value somebody reads.

**It is documented, so it is tested and the man page changes with it.** `Documentation/photogoroundd.md` says "Every request is logged to the console with the consumer, the size asked for, the deal ordinal, the bytes, and the latency"; the display joins that list. The assertion goes beside *A record carries who asked and what they asked for* in `Tests/photogorounddTests/RequestLogTests.swift`, which already checks the consumer.

It is the one change this plan makes to the agent, and it is logging, not a new job.

## What it costs the shared queue

Two cards an hour per display, against the screensaver's 341 an hour. The wallpaper therefore sees what `PLAN.md` already describes: "a near-random sample rather than a slow walk", because a screensaver session in between can roll through the library. That is accepted there, and worth confirming it still reads as right once it is on the desktop.

## Testing

The loop is written so a test drives it without touching anybody's desktop: the list of displays, the call that sets a desktop, and the clock are all passed in as closures. In `Tests/PhotoGoRoundDisplayTests`:

- each display is asked for as `wallpaper`, at its own pixel size, under its own UUID
- the bytes land in `<uuid>.<extension>` and that file is what the desktop is set to
- an empty answer and an agent failure leave the desktop alone — nothing set, no file written
- a picture already set survives a request for that display that comes up empty
- a display that got nothing is retried after `retry`, not after `interval`, and its stored time is left alone
- a launch with a stored time under thirty minutes old asks the agent for nothing
- a launch with no stored time, or one at least thirty minutes old, changes that display
- displays come due independently: one due and one not changes only the first
- the time is stored only after a successful set
- the change times are read and written through a scratch suite, never a real domain, as every preference test in the project already does
- a stored time in the future, and one whose file is gone, both count as due
- waking before a display is due changes nothing; waking after it changes that display
- reapplying sets the same files without asking the agent; a display with no picture is asked for one
- a launch that is not due sets each display's stored file without asking the agent
- unticking the checkbox stops the asking and sets nothing; ticking it again changes only displays that are due, and puts the others' stored files back
- the extension follows the content type
- in `Tests/photogorounddTests/RequestLogTests.swift`: a served request records its consumer and its display, and a request that names no display records none
- each deployment resolves its own directory and domain, and neither names the agent's container

What no test can reach is whether the desktop actually changes, whether the same URL redraws, and how Spaces behave. Those are answered by Syd running it and by the log lines above — the same standard the screensaver was held to.

## The draft already written

Written on 2026-09-10 before this plan existed, then stopped. Uncommitted, not compiled, not tested. It matches this plan's proposals as they stood when it was stopped; if the plan changes, it changes with it or is discarded.

**It already differs in three places.** It hardcodes a black fill (`fitOnBlack()` in `Wallpaper.swift`), which Syd's decision to use the System Settings fill colour replaced. It changes every display at start and keeps one change time in memory (`changedAt`, `isDue`, `woke()`), which the stored per-display time replaced. And it writes into the agent's container through `MacHostEnvironment.wallpaperRoot`, with a `HostTests` test defending that — both of which "the app should not need to see the agent's container" removes.

- `Sources/PhotoGoRoundDisplay/Wallpaper.swift` — new. `Wallpaper` (the loop, driven by closures), `WallpaperDisplay`, and an AppKit extension holding `Wallpaper.desktop()`, the fit options, the `NSWorkspace` call and `watchTheSystem()`.
- `Sources/PhotoGoRoundAgentAPI/Host/HostEnvironment.swift` — `MacHostEnvironment.wallpaperRoot`.
- `Tests/PhotoGoRoundKitTests/HostTests.swift` — one test, *The wallpapers live in the container, wherever the container is*.
- `Sources/PhotoGoRoundDisplay/Shuffle.swift` — `trouble(from:)` is no longer `private`.
- **Not yet written:** `WallpaperTests`, and the app delegate that hosts it.

## What this leaves stale elsewhere

Named here first, then brought into line on 2026-09-10 at Syd's request — "please update all other planning documents to reflect decisions made in Wallpaper Plan.md" — as dated corrections marked beside the original text, not rewrites of it. `PLAN.md`, `Screensaver Plan.md`, `TODO.md` and `app/mac/FEATURES.md` were changed. **Code is not a planning document:** `Sources/pgr_ctl/ServiceCommand.swift` still describes `SMAppService`, and is left for when the installation route is built.

- **`PLAN.md` Phase 7** says "scheduled by the server". The app runs it now, and later its own binary.
- **`PLAN.md`, *Wallpaper mechanics and their limits***, says "the practical mitigation is for the agent to re-apply", and *Wallpaper is asserted continuously* lists "agent launch" among the events. Both mean whatever runs the wallpaper, not the agent.
- **`PLAN.md`, *Alternatives considered and rejected*,** says "The agent is what makes the wallpaper schedule real." Only in the sense that it serves the pictures.
- **`Sources/pgr_ctl/ServiceCommand.swift`** and **`app/mac/FEATURES.md`, *The app brings its own agent***, describe `SMAppService.agent` with the plist inside the bundle — "no writing into `~/Library/LaunchAgents`". That is the opposite of the per-user plist Syd specified on 2026-09-10.
- **TODO.md, *Design the wallpaper***, lists "Who owns the loop" as open. It is answered. Its "Decided, 2026-09-09" entry puts the files in `<container>/wallpapers/` and says `HostEnvironment` should give the path out; both are reversed by "the app should not need to see the agent's container."
- **TODO.md, *Sandboxing, and whether the App Store is reachable***, does not mention the wallpaper. Sandboxing it would move its files out of `Application Support` and into a real container — Syd: "we will probably have to move it if we want to sandbox."

## Not yet decided

- **Whether rewriting the same URL redraws the desktop**, which Phase 1 answers first.
- **How the System Settings fill colour is kept**: leaving `.fillColor` out, or reading it back with `desktopImageOptions(for:)`. Phase 1 answers this first too.
- **Selecting a background colour as an option.** Syd: "We may add selecting background color as an option later." It joins the other options held for later.
- **Reasserting against macOS reverting on its own**, and the heuristic for not fighting the user. `PLAN.md`, *Wallpaper is asserted continuously*.
- **What the *Also set wallpapers* checkbox defaults to** — off, as "Also" suggests, or on.
- **What System Settings › Wallpaper needs from us.** TODO.md, *What System Settings › Wallpaper needs from us*; answered before Phase 1 is built.
- **A pause control beyond the checkbox**, and where it would live — the app, the shipping menu-bar app (TODO.md, *A menu-bar app for shipping*), or the Phase 2 binary.
- **Whether reapplying on a Space change is wanted at all**, given it overrides a picture the user chose on that Space.
- **Everything about Phase 2**: bundle or bare executable, menu-bar presence, and how the app installs and removes the plist.
- **Separate pools of sources for the wallpaper and the screensaver.** `PLAN.md`, *TODO: separate pools of sources*, and Syd's "in addition to sources later".

# References

- `PLAN.md` — Phase 7; *One display mode in v1*; *Every surface has a defined empty state*; *Wallpaper mechanics and their limits*; *Wallpaper is asserted continuously, never set once*; *Consequences of one shared queue*; *The empty state*; *Beyond 0.1* (*Display styles*, *Timing and transitions*, *TODO: separate pools of sources*).
- `TODO.md` — *Design the wallpaper*; *Sandboxing, and whether the App Store is reachable*; *Installing by launching the app*; *A menu-bar app for shipping*; *What System Settings › Wallpaper needs from us*.
- `Screensaver Plan.md` — the surface this one follows, and *Moving Shuffle and PictureLayerView* for why shared code goes in the display library.
- `app/mac/FEATURES.md` — *The app brings its own agent*.
- `Sources/PhotoGoRoundDisplay/` — `PictureClient.swift`, `PictureLayerView.swift` (`identifier(of:)`), `Shuffle.swift`, `AspectFit.swift`.
- `Sources/PhotoGoRoundAgentAPI/` — `Host/HostEnvironment.swift`, `Model/Consumer.swift` (`ConsumerKind.wallpaper`), `Support/Log.swift` (`Log.wallpaper`).
- `Sources/pgr_ctl/ServiceCommand.swift` and `Scripts/make-agent-bundle.sh` — the two agent-installation routes as they stand.
- Apple: `NSWorkspace.setDesktopImageURL(_:for:options:)`, `desktopImageURL(for:)`, `NSWorkspace.DesktopImageOptionKey`; `launchd.plist(5)` (`LimitLoadToSessionType`); `SMAppService`.
