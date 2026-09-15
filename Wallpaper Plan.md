# Summary

The desktop picture: one photograph per display, changed every `intervalSeconds` — thirty minutes by default, as first planned, and sixty seconds from 2026-09-10 to 2026-09-13 — sized to fit, with the rest filled in the colour set in System Settings. It is a client of the agent like every other surface, hosted by the Mac app first and moved to a bundle of its own later — shown in System Settings › Wallpaper itself, which a probe showed can work on macOS 27. Subordinate to `PLAN.md`, which places this in Phase 7.

# Rationale

The wallpaper is the other half of the original complaint: Apple's picker chokes on a large folder and falls back to the Golden Gate image unprompted. With the screensaver showing photographs overnight, the wallpaper is the last Mac surface that still depends on Apple's broken selection. It is also the first surface that needs a *file* rather than bytes, and the first that runs with nobody watching it for hours at a stretch. Both are worth getting right while it is small.

# Phases

- **Phase 1 — The wallpaper in the app.** A loop that asks the agent for a picture for each display, writes it to that display's file, and makes that file the desktop. The app starts it at launch. **Built 2026-09-10; the exit gate has not been run.** See *What was built*. **First run 2026-09-11: it works** — the checkbox turns it on, the desktop shows photographs from the sources, and the agent's log shows them served to `consumer=wallpaper`. The exit gate is under way: the day on Syd's MacBook Pro, then the weekend on Plex.
  - First, find out whether leaving `.fillColor` out keeps the fill colour set in System Settings, or whether it has to be read with `desktopImageOptions(for:)` and passed back. **Answered 2026-09-10 with `Scripts/wallpaper-probe.swift`: it keeps it.** See *The fit*.
  - Also first, find out whether setting the same URL again with new contents redraws the desktop. The answer decides between one file per display and two alternating files. **Answered the same day: it does not**, so each display alternates between two files. See *The file on disk*.
  - Aspect fit in the System Settings fill colour, every thirty minutes, and the desktop left alone when there is nothing to give it. *The preference `intervalSeconds` since 2026-09-10: sixty seconds until 2026-09-13, thirty minutes since; every "thirty minutes" below is that interval.*
  - Store the time each display's picture changed, in the wallpaper's own preference domain, and change a display only once that time is thirty minutes old — at launch as much as at any other moment.
  - Put each display's file back at launch and when displays or Spaces change.
  - An *Also set wallpapers* checkbox in the app; the loop runs only while it is ticked.
  - Before any of it is built, look at what System Settings › Wallpaper needs from us — TODO.md. *Partly answered by the probe runs; Syd said to start building on 2026-09-10 with the rest still open.*
  - The agent's served line names the display as well as the consumer, so each display's changes can be counted from the agent's side.
  - **Exit gate:** the app is left open for an evening, every display changes every thirty minutes, and the agent's log shows `consumer=wallpaper` twice an hour per display. *The day and weekend runs began at sixty seconds — a line a minute per display. Since 2026-09-13 the interval is thirty minutes again, so the count is back to twice an hour per display.*
- **Phase 2 — Its own bundle, in the Wallpaper pane if that can work.** A bundle built and installed very like the screensaver's, so the wallpaper runs without the app and is chosen in System Settings › Wallpaper. *Until 2026-09-14 this phase read "the same loop in a process of its own, installed per user as a plist in `~/Library/LaunchAgents`, with the binary staying inside the app bundle", designed after Phase 1; see* Its own binary.
  - First, the extension probe: does macOS register an extension of ours on `com.apple.wallpaper`, does the Wallpaper pane list it, and does it run — all with SIP on. **Built and run 2026-09-14: registered, launched and connected to by `WallpaperAgent` with no private entitlement; the pane lists nothing, because the probe answers nothing.** *Until then this read "Proposed 2026-09-14; not built."* See *The extension probe*.
  - Next, the second probe: a Photo-Go-Round section in the pane that can be chosen and draws a still. **Built and run 2026-09-14: all three gates passed — the section shows, choosing it reaches the extension, and the desktop shows the picture.** *Until then: "Drafted 2026-09-14; not built."* *This bullet first read "If all three pass, a second probe for what the private wallpaper frameworks expect an extension to do."* See *The second probe*.
  - Next, the third probe: snapshots, the export `WallpaperAgent` makes from them, and the lock screen. **Run 2026-09-15: the export succeeds and the lock screen shows the picture**, at version 0.3.2, after a bug in the probe's own surface bookkeeping turned 0.3's desktop gray. *Until then: "Built 2026-09-14; not yet run", and before that "Drafted 2026-09-14; not built."* See *What the third probe found*.
  - Next, the fourth probe: pictures from the agent — permission to connect, finding the port from inside the extension's sandbox, and a photograph on the desktop served to `system-wallpaper`. **Built and run 2026-09-15: all three gates passed — the port is found from inside the sandbox, the agent serves `system-wallpaper`, and the desktop shows the photograph.** *Until then: "Drafted 2026-09-15; not built."* See *What the fourth probe found*.
  - If any fails, it cannot work, and what is left for the pane is a folder registered in Apple's private store. *Until 2026-09-14 a bundle that is only a LaunchAgent was the other choice; Syd: "I don't see the LaunchAgent method as viable in the system wallpaper case."* See *Getting into System Settings › Wallpaper*.
  - `Scripts/make-wallpaper-bundle.sh`, very similar to `Scripts/make-saver-bundle.sh`. See *The bundle, like the saver's*. *Claude's reading, 2026-09-14: it builds and installs whatever ships — the pane's extension if that route works — and has no launchd step unless it does not.*
  - Whatever launchd needs goes in each user's `~/Library/LaunchAgents` — **only if the system wallpaper route cannot be figured out.** Syd: "don't want launch agent at all if system wallpaper route can be figured out."
  - macOS 27 and later only.
  - The pane's wallpaper asks the agent as `system-wallpaper`; the app's keeps asking as `wallpaper`. See *Two wallpapers, told apart in the log*.
  - The app's wallpaper stays alongside the pane's until Syd decides on the App Store.
  - **Exit gate:** not yet decided.

# Design Decisions

*Syd's, 2026-09-10, in his words where he gave them*

- **"Make it change every 30 minutes."**
- **"could we make the internal for the wallpaper 60 seconds for now? Eventually we will have a set of choices"**, then **"this should be part of the wallpaper preferences."** Superseding the thirty minutes above: `intervalSeconds` in the wallpaper's own domain, sixty seconds when nothing has set it.
- **"set both the default and the current time between serving wallpaper to 30 minutes."** 2026-09-13, superseding the sixty seconds: `intervalSeconds` is thirty minutes when nothing has set it, and the development domain holds 1800.
- **"we should store (per display) a preference storing the time the picture was changed for that display. And the image should not be changed before the time interval (initially 30 minutes) if it has previously been saved, even if the binary was just started up."** The interval is measured per display from that stored time, across launches, not from when the process started.
- **"give the wallpaper its own domain. Actually two, one for prod and one for qa"** — corrected at once: **"I meant 'prod' and 'dev'."** One domain per existing deployment, and the agent's domain is not touched; Syd: "the agent won't care about this preference."
- **The names: "com.sydpolk.photogoround.wallpaper.{dev|prod}"** — `com.sydpolk.photogoround.wallpaper.dev` and `com.sydpolk.photogoround.wallpaper.prod`.
- **"Same aspect rules as screensaver."** Shrink or expand with the aspect ratio kept, never cropped: `scaleProportionallyUpOrDown`, clipping off. `PLAN.md`'s *One display mode in v1* already names the wallpaper and the screensaver together.
- **"use the System Settings fill color for now. We may add selecting background color as an option later."** Apple's wallpaper does not default to black, so the space around the photograph is filled with whatever colour the user chose there, not one we pick.
- **"We will add options for both screensavers and wallpapers in addition to sources later."** Nothing in this plan is a preference — *with two exceptions added the same day: the* Also set wallpapers *checkbox below, and `intervalSeconds`.*
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

*Syd's, 2026-09-14, for Phase 2, in his words*

- **"Wallpapers needs its own binary/bundle so that it can be set from System Settings and run without the app."**
- **"I am expecting something very similar to Scripts/make-saver-bundle.sh"**
- **"appearing the wallpaper pane itself"** — his answer to whether "set from System Settings" meant System Settings › Wallpaper or the background item's switch under Login Items.
- **"b. I really want this in the wallpaper pane but only if it can work"** — the extension probe first, before either fallback. See *Getting into System Settings › Wallpaper*.
- **"whatever launchctl needs should be put into ~/Library/LaunchAgents so multiple users don't clobber each other"**
- **"this will very soon be MacOS 27+ only"**
- **"reverse-engineering the wallpaper extension API will mean we can't sandbox this"**, then, when Claude pointed out that Apple's own wallpaper extension is sandboxed: **"you are right about the App Store; that is what I meant."** The private route costs the App Store. See *Getting into System Settings › Wallpaper*, *Sandboxing, and the App Store*.
- **"the logging for fetches from the system wallpaper panel should say "system-wallpaper" to distinguish it from the app-based "wallpaper" now."** See *Two wallpapers, told apart in the log*.
- **"We will continue to support both until I decide on trying to sandbox or not."** Both the pane's wallpaper and the app's. *Claude's reading, given the correction above: the decision meant is the App Store.*
- **"I am ok with not supporting app and system wallpapers and the two systems fighting each other"** *Claude's reading: turning on the pane's wallpaper and the app's for the same display is not a supported configuration. If somebody does, the two fighting over the desktop is accepted, and nothing is built to prevent it.*
- **"I don't see the LaunchAgent method as viable in the system wallpaper case."** *Claude's reading: route C — a LaunchAgent calling `setDesktopImageURL` — never appears in the Wallpaper pane, so it is not a way to get the system wallpaper; if the probe fails, route A is the one route into the pane left. Whether a LaunchAgent bundle is still wanted for the app-style wallpaper is not said.*
- **"don't want launch agent at all if system wallpaper route can be figured out"** — asked whether a LaunchAgent bundle is still wanted for the app-style wallpaper. *Claude's reading: no LaunchAgent bundle is built while the system wallpaper route is being worked out, and none at all if it works; the question comes back only if it cannot be figured out.*
- **"yes"** — to writing the step 1 findings into this plan and changing *The extension probe* to follow Phosphene's shape: no private entitlement, a sandboxed extension inside a host app.
- **"yes, build the probe"**
- **"yes"** — to recording the probe's results here and drafting the second probe.
- **"yes, build the second probe"**
- **"yes"** — to recording the second probe's results here.
- **"1."** — snapshots and the lock screen next, of the open items offered.
- **"yes, build the third probe"**
- **"you can go ahead and upgrade everything to our minimum support to macOS 27, so yes, use the OS 27 APIs"**, and **"you can update the plan files with this decision."** Every minimum in the project is 27.0, and the probe hands its renderer a frame the macOS 27 way. See *macOS 27 and later*.
- **"and really, all of this should be executed in the build script. I have to open the system settings panel, but until then, this is all mechanical command-line stuff, and there is no reason that the build script should not do everything until I have to open the settings panel"** — 2026-09-15. The probe's script now stops the old extension, replaces the copy in `~/Applications`, registers it, and waits for `pluginkit` to show the new version. `--build-only` skips all of that. The steps after it are in `Documentation/Wallpaper Extension Probe.md`.
- **"please go ahead and put the "--sign <arg>" directly in the build script. This is unlikely to change anytime soon."** — 2026-09-15. The script signs with `Apple Development: Sydney Polk (W8E4GRMLBV)` unless told otherwise; `--sign -` builds ad-hoc.
- **"yes, build 0.3.2"**, and **"yes, record it in the plan"** — 2026-09-15.
- **"1."** — pictures from the agent next, of the open items offered, 2026-09-15; and **"yes, draft it in the plan"**.
- **"yes, build the fourth probe"**, and **"yes, record it in the plan"** — 2026-09-15.

*Decided before this plan*

- **One file per display, named by the display's UUID**, scoped to the deployment, outside the cache, and never swept. TODO.md, *Design the wallpaper*, 2026-09-09. *That entry put the files in `<container>/wallpapers/`; Syd reversed the location on 2026-09-10 — see the bullet above. The rest of it stands.*
- **An empty library leaves the existing desktop alone.** `PLAN.md`, *The empty state*.

*Proposed by Claude, not decided*

- **The loop lives in `PhotoGoRoundDisplay`**, with the app as its host, so that moving it into its own binary later means writing a new host rather than moving the code.
- **One rule for when to change: which displays are due?** Asked at launch, on wake, and when the loop's sleep ends, after which it sleeps until the next display is due. This replaces a separate rule for launch, one for wake and one for the timer. *Replaces two proposals Syd's stored-time decision overturned: changing the picture at launch, and a wake check against a "last complete round" held only in memory.*
- **Each display's file URL is stored beside its change time**, so a launch that is not due still knows which file each display is showing.
- **A change time in the future, or one whose file is gone, counts as due.**
- **It retries after a minute when a display got nothing**, rather than waiting the full half hour. *The two were the same while the interval was sixty seconds, from 2026-09-10 to 2026-09-13.*
- **`intervalSeconds` is read on every use and clamped to between ten seconds and seven days**, and the loop never sleeps longer than thirty seconds, so a changed value applies within that without a restart. *Chosen while building, 2026-09-10.*
- **It puts each display's file back when screens or Spaces change, and otherwise does not fight macOS reverting it.** Launch is the third occasion, by Syd's decision above. *Wallpaper is asserted continuously* is later work.
- **At launch, before putting each file back, it compares the stored file with what `desktopImageURL(for:)` reports and logs any difference.** That is a record of how often the desktop changes while the app is closed, whether macOS reverted it or somebody chose another picture — the evidence *Wallpaper is asserted continuously* says is missing. *A log line only: the read-back was measured lagging on 2026-09-10.*
- **It asks at each display's native pixel size, as consumer `wallpaper`, with the display UUID.** That gives one consumer row per display, which is the identity the deck already uses.
- **Phase 2's probe is a throwaway host app carrying one extension on `com.apple.wallpaper`**, built by a script with `swiftc` and `codesign` rather than an Xcode target, signed two ways, and registered by Syd. *2026-09-14; not approved to build. Revised the same day to follow Phosphene: no private entitlement, a sandboxed extension inside the host app.* See *The extension probe*.
- **The bundle is an Xcode target, `Photo-Go-Round Wallpaper`, with a host like `AppDelegate` around the same `Wallpaper` loop.** *2026-09-14, proposed before the pane was asked for; much of it changes if an extension is what ships.* See *The bundle, like the saver's*.
- **Phase 2's second probe answers the pane and draws one bundled still, without the agent**, grown from the first probe's extension. *2026-09-14; built and run that night at Syd's "yes, build the second probe", and all three gates passed.* See *The second probe*.
- **Phase 2's third probe answers `snapshot` with the picture in an `IOSurface`, without Phosphene's encoder workaround at first.** *2026-09-14; built that night at Syd's "yes, build the third probe", and run 2026-09-15: no workaround was needed, and both gates passed at 0.3.2. Until then: "not yet run", and before that "not approved to build."* See *What the third probe found*.
- **Phase 2's fourth probe gives the extension `network.client` and read-only exceptions for our preference domain and its plist, reads the port both ways, and asks the agent as `system-wallpaper`.** It shows the generated picture at once and swaps in the photograph when it arrives. *2026-09-15; built at Syd's "yes, build the fourth probe", and run the same morning: all three gates passed. Until then: "not approved to build."* See *What the fourth probe found*.
# Background

`PLAN.md` Phase 7 is one line — "per-screen `NSWorkspace.setDesktopImageURL`, scheduled by the server." `PLAN.md`'s *Wallpaper mechanics and their limits* and *Wallpaper is asserted continuously, never set once* were written before *The service is the interface*. TODO.md's *Design the wallpaper* settled where the files go and left open who runs the loop, which is now answered.

Everything a client needs already exists. `PictureClient` asks the agent at a size and a display. `PictureLayerView.identifier(of:)` turns an `NSScreen` into the UUID the deck keys on. `ConsumerKind.wallpaper` and `Log.wallpaper` were both defined long ago and had no callers until Phase 1.

**No surface opens the agent's container.** The app and the saver use `MacHostEnvironment` for its preference domain alone, which is how they find the port; only the agent and `pgr_ctl`, the rig, touch the database and the cache. The wallpaper keeps it that way.

The app is unsandboxed (`ENABLE_APP_SANDBOX = NO` in both configurations), so it can write under `~/Library/Application Support` and call `NSWorkspace` without an entitlement.

**System Settings › Wallpaper has no public slot.** The wallpapers it lists are ExtensionKit extensions on `com.apple.wallpaper`, and that extension point requires the private entitlement `com.apple.private.wallpaper.extension` — measured 2026-09-14 from the system's own bundles. The screensaver has Screen Saver › Other; the wallpaper has nothing like it. See *Getting into System Settings › Wallpaper*. *Later the same day: a third-party project, Phosphene, is in the pane with an extension whose source declares no such entitlement. See* Phosphene: a third-party extension in the pane. *Measured that evening: an extension of ours with no private entitlement was registered, launched and connected to by `WallpaperAgent`. See* The extension probe. *Later that night, the second probe's section was chosen in the pane and drew on the desktop. See* The second probe.

**Code was written before this plan and stopped.** On 2026-09-10, a draft of Phase 1 was written and then halted at Syd's direction, because the design had not been read as a plan. **Superseded the same day:** after the probe, Phase 1 was built to this plan and the draft was rewritten rather than kept. See *What was built*.

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
20. Phase 1 began with `Scripts/wallpaper-probe.swift`, run by Syd. Leaving `.fillColor` out keeps the System Settings colour; setting the same URL again does not redraw; the reported URL lagged once; restoring a folder URL left the Golden Gate default. Syd: "yes, record them and start building."
21. Phase 1 was built and its tests pass; the exit gate is Syd's to run. Syd then changed the interval: "could we make the internal for the wallpaper 60 seconds for now? Eventually we will have a set of choices", and "this should be part of the wallpaper preferences." It became `intervalSeconds`, in the wallpaper's own domain.
22. First run, 2026-09-11. Syd: "The checkbox works. I see wallpaper from the sources. I see from the logs that wallpaper served from the queue." He left it running for the day, and set it up on Plex to run over the weekend.
23. Syd, 2026-09-13: "set both the default and the current time between serving wallpaper to 30 minutes." `Wallpaper.defaultInterval` went back to thirty minutes, and `intervalSeconds` in `com.sydpolk.photogoround.wallpaper.dev` was set to 1800 with `defaults write`, which a running app picks up within its thirty-second recheck. The production domain did not exist and was not created.
24. Syd, 2026-09-14: "Wallpapers needs its own binary/bundle so that it can be set from System Settings and run without the app." Claude proposed a bundle following the saver's — an Xcode target, a host around `Wallpaper`, a script with `--install` — and listed where it did not fit, first among them that no public route into the Wallpaper pane was known. Syd, while that was being written: "I am expecting something very similar to Scripts/make-saver-bundle.sh".
25. Asked whether System Settings meant the Wallpaper pane or the background item's switch under Login Items, Syd: "appearing the wallpaper pane itself".
26. Claude read Apple's wallpaper extensions and the extension point's definition, found the private entitlement it requires, and offered three routes: a folder registered in Apple's private store, a probe measuring whether an extension of ours is refused, or leaving the pane out. Syd, meanwhile: "whatever launchctl needs should be put into ~/Library/LaunchAgents so multiple users don't clobber each other".
27. Syd: "b. I really want this in the wallpaper pane but only if it can work", then "this will very soon be MacOS 27+ only". Claude proposed the probe as three gates and asked whether to build it.
28. Syd: "please capture all of this in the "Wallpaper Plan.md" file" — so it is recorded here, and the probe is not built. With it: "In almost ALL cases, I want the plan before any implementation."
29. Syd, while it was being recorded: "reverse-engineering the wallpaper extension API will mean we can't sandbox this." Recorded as his, with Claude's differing reading beside it rather than in it.
30. Syd: "the logging for fetches from the system wallpaper panel should say "system-wallpaper" to distinguish it from the app-based "wallpaper" now. We will continue to support both until I decide on trying to sandbox or not." Claude read `PictureEndpoint` and `ConsumerKind` and found the agent takes any consumer name, so nothing in the agent changes.
31. Syd, on the sandboxing difference: "you are right about the App Store; that is what I meant."
32. Claude listed what supporting both left open, first among them both being on for one display. Syd: "I am ok with not supporting app and system wallpapers and the two systems fighting each other."
33. Syd: "I don't understand. How are wallpapers done by the system?" Claude read `WallpaperAgent`'s entitlements and links, the Settings pane's extension, and what was running, and explained: one per-user `WallpaperAgent` hosts an extension per kind of wallpaper, the pane is a Settings extension that records the choice, and `setDesktopImageURL` is the public way to set that same choice. The same reading found `WallpaperAgent` also entitled to host `com.apple.wallpaper.development`, with no definition found for it. Not yet written into this plan beyond this line; Claude asked whether to add it.
34. Syd: "I don't see the LaunchAgent method as viable in the system wallpaper case."
35. Asked whether a LaunchAgent bundle was still wanted for the app-style wallpaper, Syd: "don't want launch agent at all if system wallpaper route can be figured out."
36. Asked again whether to write step 33's explanation and the development point into the plan, Syd: "yes, add both to the plan." They are *How the system does wallpaper* and *The development extension point*.
37. Syd chose the shared cache search first: "1". Nothing defines `com.apple.wallpaper.development` there or anywhere else looked. Syd, during the search: "also make sure and scan the web." The web turned up Phosphene, a third-party extension in the Wallpaper pane on `com.apple.wallpaper`, whose source declares no private entitlement.
38. Asked whether to write that into the plan and change the probe to follow Phosphene's shape, Syd: "yes".
39. Syd: "yes, build the probe". Claude built it with `Scripts/make-wallpaper-extension-probe.sh`, following *The extension probe*, with two additions named to Syd: the `dlopen` check and logged connections.
40. Syd listed his one signing identity, `Apple Development: Sydney Polk (W8E4GRMLBV)`, asked for "the revised build script", asked for it to be written back to the scripts directory and for the command line. It was already there, and he was given the commands.
41. Syd ran gate 1 on the development-signed build: twelve extensions, ours among them. Claude found that the script's summary printed no signer for an identity build — `codesign -dv` shows `Authority` only at `-dvv` — and fixed it.
42. Syd asked where the probe would appear in the pane and in what category. Claude read Phosphene's `SettingsProvider.swift`: an extension names its own section, and the probe names none.
43. Syd's log showed the extension starting and never connected to, and "nothing showed up in the wallpaper pane". Claude read `WallpaperAgent`'s side of the log and the crash report: `WallpaperAgent` had launched the extension, and it had crashed. Disassembly traced the crash to the entry point, and the script was changed to link `_NSExtensionMain`.
44. Syd rebuilt, registered the probe again and opened the pane. `WallpaperAgent` connected five times, the probe logged each connection, and the pane stayed empty.
45. Asked whether to record the results and draft the second probe here, Syd: "yes".
46. Syd: "yes, build the second probe". Claude read Phosphene's view-model mirrors, interface setup, `acquire` and still path in full, built the probe, cleared all but one deliberate warning, and decoded its archive as Apple's class in a harness before handing it over.
47. Syd: "no photos go round section". The log showed the first probe's extension process, still running, answering instead of the new build, and `ps` confirmed it. Claude added `killall WallpaperProbeExtension` to the script's removal steps; Syd ran it and opened the pane again.
48. Syd: "I see the section, the probe wallpaper, and the picture on the desktop." The log confirmed all three gates, and showed the snapshot failures and one `isChoiceDownloaded` race.
49. Asked whether to record the results here, Syd: "yes".
50. Syd, after committing and putting his own wallpaper back: "let's continue". Asked which open item to take next, Syd: "1." — snapshots and the lock screen. Claude read the export controller's lines from the second probe's run, and Phosphene's snapshot code, snapshot cache and README, and searched Phosphene's sources for the encoder workaround its README describes, finding none.
51. The third probe drafted here for Syd's review.
52. Syd: "yes, build the third probe". Claude built it; it has not been run.
53. Syd, of the one deprecation warning left: "you probably can't do anything about these warnings". Claude answered that it had been kept on purpose and could be replaced with the macOS 27 API. Syd: "you can go ahead and upgrade everything to our minimum support to macOS 27, so yes, use the OS 27 APIs", then "you can update the plan files with this decision." Every macOS minimum in the project went to 27.0, and the probe's `enqueue` was replaced.
54. Syd ran 0.3, 2026-09-15: "no, the desktop is a dark gray image. The wallpaper is set to Photo-Go-Round, but the picture is wrong". The log showed the frame enqueued and the snapshot sent, so either could be the cause. Syd: "yes, build that variant" — 0.3.1, answering no snapshots.
55. Syd asked for the steps the script printed to go in a Markdown file, and to be walked through them one at a time, with routine commands in one block. They went to `Documentation/Wallpaper Extension Probe.md`, and the script stopped printing them.
56. Syd: "and really, all of this should be executed in the build script…" The script took over the install and registration, up to the Settings pane.
57. Syd, of 0.3.1: "wallpaper is now blue and yellow test image". So answering the snapshot was what turned 0.3 gray, not the macOS 27 enqueue.
58. Syd: "yes" to reading how Apple's snapshot class encodes. Claude disassembled it, sent a snapshot through a real `NSXPCConnection` in a harness, and compared the 0.3 and 0.3.1 logs. The snapshot was intact; the probe's surface bookkeeping was not. Syd also had the signing identity put in the script.
59. Syd: "yes, build 0.3.2". Syd ran it: the desktop kept the picture, the export succeeded, and the lock screen showed the picture.
60. Syd: "yes, record it in the plan".
61. Asked which open item to take next, Syd: "1." — pictures from the agent. Claude read `Screensaver Plan.md`'s sandbox findings, `ServicePort.swift`, `PictureClient.swift`, `PictureEndpoint.swift` and `Consumer.swift`, and the entitlements of Apple's Aerials extension, and proposed the fourth probe in prose.
62. Syd: "yes, draft it in the plan". The fourth probe drafted here for Syd's review.
63. Syd: "yes, build the fourth probe". Claude built it as 0.4. A compile error — `CGDisplayCreateUUIDFromDisplayID` needs `ColorSync` without AppKit — was fixed, and a harness outside the sandbox checked the port reads, the display UUID and the decode, without asking the agent for a card.
64. Syd ran it, and sent the pane's thumbnail — the generated picture, which the thumbnail always is. The probe's log showed the port read, the request answered and the photograph enqueued. Syd: "but I do see a picture from the rotation", with the agent's own log showing the same card served to `system-wallpaper`.
65. Syd: "yes, record it in the plan".

## Where the loop runs

**Not in the agent.** The agent serves pictures and does nothing else. A wallpaper loop inside it would make it a consumer of its own queue, give it AppKit, and give it a second job, which is exactly what the agent's `main.swift` argues against: "A service that also answers questions is a service with two jobs, and the second one grows."

**In the app, for now.** The obvious cost is that the wallpaper changes only while the app is open. That is accepted because Phase 2 removes it.

**Why the code goes in the display library rather than the app target.** The loop needs `PictureClient`, `PixelSize` and the display identifier, all of which are already in `PhotoGoRoundDisplay`. If the loop lived in `app/mac/Sources`, Phase 2 would begin by moving it, which is what Phase 2 of `Screensaver Plan.md` had to do for `Shuffle` and `PictureLayerView`. That library already has one AppKit file behind `#if canImport(AppKit)`; the wallpaper's `NSScreen` and `NSWorkspace` code would be a second, and the loop above it would compile anywhere.

**How the app hosts it.** It needs a place that runs once the application has finished launching and lives as long as the app. The app is a SwiftUI `App` with no delegate today, so the smallest host is an `@NSApplicationDelegateAdaptor` whose `applicationDidFinishLaunching` starts the wallpaper. A property on the `App` struct would work but gives no clean moment at which `NSScreen.screens` is known to be ready. **Built that way:** `app/mac/Sources/AppDelegate.swift`, which `PhotoGoRoundApp` also uses to hand the wallpaper to the Settings window.

## The *Also set wallpapers* checkbox

Syd, 2026-09-10: "add an option to the app: a checkbox which says 'Also set wallpapers'."

- **Ticked, the wallpaper runs; unticked, it does not.** Unticking stops the loop and leaves the desktop showing whatever it has — the same rule as an empty library, since taking our picture down would mean choosing a replacement for the user. Ticking starts it, and the due rule decides what happens: a display whose stored time is under the interval old gets its stored file back and nothing new.
- **It was the plan's first preference**, and `intervalSeconds` joined it the same day. Everything else waits for "options … later".
- **Where it is stored — Claude's proposal, built that way:** the key `enabled` in the wallpaper's own domain, `com.sydpolk.photogoround.wallpaper.{dev|prod}`, beside the change times. The agent does not read it, and the Phase 2 binary would read the same key, so moving the wallpaper out of the app does not move the setting.
- **Where it sits — Claude's proposal, built that way:** the Settings window, under its two panels, which is the app's one existing place for options, until the menu-bar app exists. It is listed in `app/mac/FEATURES.md` as an app feature.
- **What it defaults to is open.** "Also" reads as opt-in, which is off; on means nobody has to find it. Listed under *Not yet decided*. **Built off**, Claude's pick while building: a development build then does not change anybody's desktop just by launching.
- **It is the first way to stop the wallpaper**, which is what the pause control was for. Whether a separate pause is still wanted is folded into that item below.

## How wallpaper binaries are made on macOS

Answered from general knowledge, not from anything measured on this machine or on macOS 27. The Sonoma rewrite of the wallpaper settings is the part most likely to have moved.

- **The hard requirement is the logged-in GUI session.** `setDesktopImageURL` works through the window server and Apple's wallpaper process on the user's behalf, so the caller must be in that user's Aqua session. A LaunchDaemon, which is system-wide and running before anyone logs in, cannot set wallpaper. Whether the process is a login item or a LaunchAgent is a question of packaging, not of what it can do.
- **Third-party rotators generally ship as menu-bar apps launched as login items** (examples from memory: Irvue, Unsplash Wallpapers, Satellite Eyes), calling `setDesktopImageURL` on a timer. The menu-bar item gives a pause control somewhere to live.
- **A per-user LaunchAgent works just as well.** A plist in `~/Library/LaunchAgents` is loaded into the user's `gui/<uid>` domain at login, which is the Aqua session unless `LimitLoadToSessionType` says otherwise — so that key must be left out. launchd starts the process and can restart it with `KeepAlive`.
- **There are no per-user daemons.** launchd reads `~/Library/LaunchAgents` for each user. Daemons come only from `/Library/LaunchDaemons` and `/System/Library/LaunchDaemons`.
- **Since macOS 13 the user is told.** Anything in `~/Library/LaunchAgents` appears under System Settings › General › Login Items › *Allow in the Background*, and the system posts a notification when one is added. It still runs; the user can see it and switch it off.
- **Apple's own rotation is no help.** "Change picture every 30 minutes" in System Settings is done by the system's `WallpaperAgent`, and the animated wallpapers use a private extension point. There is no hook into either. *Measured 2026-09-14: that extension point is `com.apple.wallpaper`, it carries the stills the pane lists as well as the animated wallpapers, and it requires a private entitlement. See* Getting into System Settings › Wallpaper.

## Its own binary

*2026-09-14: Phase 2 is being designed now, and aims at the Wallpaper pane; the ten sections after this one hold it. This section is as it was written.*

Held for Phase 2 and not designed here. What has been said about it:

- It is its own process, and it calls the agent for the image.
- It is installed per user, as a plist in `~/Library/LaunchAgents` — the same shape as the agent. The binary stays in the app bundle, and the plist's `ProgramArguments` points into it.
- It runs in the user's GUI session, which is what lets it call `NSWorkspace`.

Open when Phase 2 is designed: whether it is a bare executable or an `LSUIElement` bundle, whether it carries a menu-bar item (the pause control needs a home), and how the app installs, updates and removes the plist. The app's quit no longer ends the wallpaper at that point, so stopping it becomes a real question.

**The shipping app is probably a menu-bar app, not the full desktop app.** Syd, 2026-09-10: "The full desktop app is useful, but we are probably not going to ship it." That makes a menu-bar app a possible host for the wallpaper, alongside a separate binary, and the natural place for the pause control. Recorded in TODO.md, *A menu-bar app for shipping*. Which of the two runs the wallpaper is Phase 2's decision.

## How the system does wallpaper

Syd, 2026-09-14: "I don't understand. How are wallpapers done by the system?" Answered from Apple's own bundles on this Mac, read that day, and marked where it rests on general knowledge instead. **In short: one per-user process owns each display's wallpaper, and everything else — System Settings and this app alike — tells that process what to show.**

**`WallpaperAgent`**, `/System/Library/CoreServices/WallpaperAgent.app`, one per logged-in user.

- **Measured:** it was running. It is sandboxed (`com.apple.security.app-sandbox`).
- **Measured:** it is the host for wallpaper extensions. Its entitlements include `com.apple.private.wallpaper.extension-host` — the host entitlement the extension point requires — and `com.apple.extensionkit.host.extension-point-identifiers` naming `com.apple.wallpaper` and `com.apple.wallpaper.development`. See *The development extension point* for the second.
- **Measured, not interpreted:** it also carries `com.apple.private.coreservices.definesExtensionPoint`, `com.apple.private.wallpaper.export`, and `com.apple.developer.extension-host.screensaver`.
- **Measured:** it links the private `Wallpaper`, `WallpaperExtensionKit`, `WallpaperFoundation`, `WallpaperServices`, `WallpaperAnalytics` and `WallpaperTypes`, and the public `ExtensionFoundation`.
- **General knowledge:** it is what draws the desktop.

**One extension per kind of wallpaper**, in `/System/Library/ExtensionKit/Extensions/`, each on `com.apple.wallpaper` and each entitled `com.apple.private.wallpaper.extension`. Several were running as processes of their own when looked at, so `WallpaperAgent` runs them out of process.

- `WallpaperImageExtension` (`com.apple.wallpaper.extension.image`) — stills and photographs; its entitlements name the group `com.apple.wallpaper.extension.photos`.
- `WallpaperDynamicExtension` — pictures that change through the day.
- `WallpaperAerialsExtension` — the moving ones.
- `WallpaperGradientExtension` — plain colours.
- `WallpaperSonomaExtension`, `…Sequoia…`, `…Ventura…`, `…Monterey…`, `…Macintosh…`, and `NeptuneOneWallpaper` — Apple's named sets.
- `WallpaperLegacyExtension` — by its name, older-style choices; not looked into.

**The System Settings pane is itself an extension.** `Wallpaper.appex`, `com.apple.Wallpaper-Settings.extension`, on `com.apple.Settings.extension.ui` — a Settings UI extension, not a wallpaper extension — entitled `com.apple.private.wallpaper`. `WallpaperSettingsIntents.appex`, `com.apple.settings-intents.WallpaperIntents`, carries the same entitlement. **General knowledge and the WallpaperFolderManager article, not measured:** the pane shows what the wallpaper extensions offer and records the choice in a private store that `WallpaperAgent` reads.

**`NSWorkspace.setDesktopImageURL`** is the public way to set that same choice, and it is what Phase 1 calls. **Not measured:** what it becomes inside `WallpaperAgent`; most likely a still-image choice handled by `WallpaperImageExtension`. Two of the probe's 2026-09-10 results fit that reading: a fill colour chosen in the pane recoloured the bands around a picture this app set, and setting a folder's URL back left the Golden Gate default.

**What follows, and why two wallpapers "fight".** There is one choice per display, per Space. Setting a file through `setDesktopImageURL` replaces what the pane chose — the 2026-09-10 probe's first set replaced Syd's folder rotation on screen — and the pane edits the same choice back. Nothing draws in layers; whichever wrote last is what shows. That is the fight Syd accepted in *Two wallpapers, told apart in the log*.

**Where each route plugs in:**

- **Phase 1, the app:** sets the choice from outside, through the public call.
- **The extension probe:** would be one of the kinds of wallpaper `WallpaperAgent` loads, picked in the pane like Apple's. *This line first said that is why it needs the private entitlement; Phosphene's source, found later the same day, suggests it does not. See* Phosphene: a third-party extension in the pane.
- **Route A:** uses the image extension's existing folder of pictures, set up by writing its private store.
- **Route C:** the public call again, from a LaunchAgent instead of the app — the same program run in a second place. Ruled out for the system wallpaper.

## Getting into System Settings › Wallpaper

Syd, 2026-09-14: "appearing the wallpaper pane itself", and "I really want this in the wallpaper pane but only if it can work."

**Why "like the screensaver" does not carry over.** The saver is a `.saver` bundle in `~/Library/Screen Savers`, and System Settings lists it under Screen Saver › Other. That slot is public. Nothing found shows anyone outside Apple getting a wallpaper into the Wallpaper pane the same way. *Corrected later on 2026-09-14: Phosphene does. See* Phosphene: a third-party extension in the pane.

**Measured 2026-09-14, from the system's own bundles on macOS 27:**

- `pluginkit -m -v -p com.apple.wallpaper` lists eleven extensions, all Apple's, all in `/System/Library/ExtensionKit/Extensions/`: `WallpaperImageExtension`, `WallpaperDynamicExtension`, `WallpaperAerialsExtension`, `WallpaperGradientExtension`, `WallpaperSonomaExtension`, `WallpaperSequoiaExtension`, `WallpaperVenturaExtension`, `WallpaperMontereyExtension`, `WallpaperMacintoshExtension`, `WallpaperLegacyExtension`, and `NeptuneOneWallpaper`. That count is the baseline the probe is compared against. `Wallpaper.appex` and `WallpaperSettingsIntents.appex` sit in the same directory and are not in the list.
- The two Info.plists read, `WallpaperSonomaExtension` and `NeptuneOneWallpaper`, both carry `EXAppExtensionAttributes` › `EXExtensionPointIdentifier` = `com.apple.wallpaper`; Sonoma's package type is `XPC!`.
- The extension point's definition, `/System/Library/ExtensionKit/ExtensionPoints/com.apple.wallpaper.appexpt`, is only this: `EXRequiredEntitlements` = `com.apple.private.wallpaper.extension`, and `EXRequiredHostEntitlements` = `com.apple.private.wallpaper.extension-host`.
- `WallpaperSonomaExtension` is signed with exactly two entitlements: `com.apple.private.wallpaper.extension` and `com.apple.security.app-sandbox`.
- `WallpaperSonomaExtension` links the private `WallpaperExtensionKit`, `WallpaperFoundation` and `WallpaperTypes`, and the public `ExtensionFoundation` and `AVFoundation`. `WallpaperImageExtension` links the same three private frameworks and `ExtensionFoundation`. Whatever the pane asks of an extension is defined in those private frameworks, and nothing documents it.

**Not measured:** that a build of ours carrying a `com.apple.private.*` entitlement is refused. With System Integrity Protection on, macOS is generally understood to refuse to run a non-Apple binary signed with a private entitlement, but that is general knowledge, not a result from this machine. The probe measures it. *Later the same day: Phosphene's author reports running Developer ID signed and notarized without that entitlement, and its source declares none. The probe still measures it on this Mac.* *Measured that evening: not refused. See* The extension probe.

**The routes into the pane, as offered to Syd:**

- **A. A folder registered in Apple's private store.** WallpaperFolderManager adds a folder to the pane on macOS 26 by writing plists, encoded as data inside other plists, under `~/Library/Containers/com.apple.wallpaper.extension.image/`, then restarting `cfprefsd` and `WallpaperAgent`; on 13 to 15 the same thing lived in `com.apple.systempreferences.plist`. Our bundle would keep a small folder fed from the agent, and the pane would show that folder. The costs: the format is undocumented and has moved once already; Apple's `WallpaperAgent` does the rotating, which replaces the per-display change times and the *Shuffle All* interval; and the agent's `consumer=wallpaper` lines would no longer match what is on the glass one for one. A small folder stays clear of the original complaint, Apple's picker choking on a large one.
- **B. A probe first** — Syd's choice. See *The extension probe*.
- **C. Leave the pane out.** A per-user LaunchAgent calling `setDesktopImageURL`, which is what Phase 2 was before 2026-09-14. Its only presence in System Settings would be its switch under General › Login Items & Extensions › Allow in the Background — from general knowledge, not checked on 27. **Ruled out for the system wallpaper, 2026-09-14.** Syd: "I don't see the LaunchAgent method as viable in the system wallpaper case." It never appears in the Wallpaper pane, which is the point of the system wallpaper.

**"Only if it can work"** is read as: it works with SIP on, signed the way a shipped build is signed. Something that works only with SIP off, or only ad-hoc on one Mac, cannot ship, and Syd will not be asked to turn SIP off.

**Sandboxing, and the App Store.** Syd, 2026-09-14: "reverse-engineering the wallpaper extension API will mean we can't sandbox this." Claude's reading was put to him separately: the one Apple extension whose entitlements were read is itself signed with `com.apple.security.app-sandbox`, so an extension on this point runs sandboxed rather than preventing it; what the private entitlement and private frameworks rule out — from general knowledge, not measured — is the App Store, whose review refuses non-public API. Syd: "you are right about the App Store; that is what I meant." **So the extension route costs the App Store**, and Developer ID direct, which `PLAN.md` already chose, has no review. The decision lives in TODO.md's *Sandboxing, and whether the App Store is reachable*, and until it is made both wallpapers stay: "We will continue to support both until I decide on trying to sandbox or not."

## The development extension point

Found 2026-09-14 while answering *How the system does wallpaper*, and added here at Syd's "yes, add both to the plan". **A lead, not an answer.**

**Measured:** `WallpaperAgent`'s `com.apple.extensionkit.host.extension-point-identifiers` names two points, `com.apple.wallpaper` and `com.apple.wallpaper.development`.

**Looked for and not found:**

- a definition among the `.appexpt` files anywhere under `/System/Library` or `/Library` — the only wallpaper one is `com.apple.wallpaper.appexpt`;
- an `.appexpt` or extension-point file inside `WallpaperAgent.app`;
- any mention in `WallpaperAgent`'s `Info.plist`;
- the string `wallpaper.development` in `WallpaperAgent`'s own binary.

**Not searched:** the private wallpaper frameworks. Their code lives in the dyld shared cache rather than as files on disk, so the searches above never reached them, and a point defined in code would be there.

**Why it matters.** `com.apple.wallpaper` requires `com.apple.private.wallpaper.extension`, which is what makes "only if it can work" doubtful. If `com.apple.wallpaper.development` requires less, an extension of ours might be let in where it would otherwise be refused. **What it requires is unknown.** That it is meant for developing wallpapers, perhaps only on Apple's internal builds, is a guess from its name, not a finding.

**Proposed by Claude, not decided:**

- Look for the point's definition in the shared cache before building the probe, since what it requires decides what the probe signs with.
- Give the probe a second extension on `com.apple.wallpaper.development`, run with the same three gates and the same two signatures as the one on `com.apple.wallpaper`, so the two points are measured side by side.

**Searched 2026-09-14, at Syd's go-ahead — "1" — and not found.**

- `strings` over all 82 files of the dyld shared cache in `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/`: `com.apple.wallpaper` appears in 4 files, which shows the search reaches the text; `wallpaper.development` in none.
- Two earlier passes with `grep -a` over the same files found nothing even for strings that are there, so their empty result is not counted.
- `pluginkit -m -v -p com.apple.wallpaper.development` lists nothing.
- LaunchServices' registry, `lsregister -dump` filtered to the name, mentions it only inside `WallpaperAgent`'s entitlements, and holds no extension point by that name.
- `WallpaperAgent`'s `Info.plist` declares no extension points.

**Probably moot.** Phosphene is in the pane on `com.apple.wallpaper` without the private entitlement, which removes the reason this point mattered. Both proposals above are set aside unless the probe is refused on `com.apple.wallpaper`.

## Phosphene: a third-party extension in the pane

Found 2026-09-14, after Syd's "also make sure and scan the web", and written here at his "yes". **Read from its source on GitHub; not downloaded, and not run on this Mac.**

**What it is.** An MIT-licensed menu-bar app and wallpaper extension, by the GitHub user kageroumado, that adds videos to System Settings › Wallpaper as a collection of its own, chosen for the desktop and the lock screen the way Apple's are.

- Distributed as a signed, notarized DMG and a Homebrew cask. Its README says it was validated on macOS 26 and on the macOS 27 beta, and asks for nothing like turning SIP off.
- Video only; it offers no stills.

**What the source shows:**

- **The extension's `Info.plist`** holds only `EXAppExtensionAttributes` › `EXExtensionPointIdentifier` = `com.apple.wallpaper`.
- **The extension target**, `glass.kagerou.phosphene.extension`, is product type `com.apple.product-type.extensionkit-extension`, copied into the app's extensions folder, with `ENABLE_APP_SANDBOX = YES`, `ENABLE_HARDENED_RUNTIME = YES`, deployment target 26.0, and no entitlements file. The project's one entitlements file is the app's, and holds only `com.apple.security.files.bookmarks.app-scope`. The app is unsandboxed and `LSUIElement`.
- **No `com.apple.private.wallpaper.extension` anywhere**, although `com.apple.wallpaper.appexpt` on this Mac names it in `EXRequiredEntitlements`. Whether that key goes unenforced for this point, or is enforced in a way Phosphene passes, is unknown. The probe's gates are how this Mac answers.
- **Registered by launching the app**, per its README.
- **At start the extension `dlopen`s `WallpaperExtensionKit`** from `/System/Library/PrivateFrameworks/` and checks that the private XPC classes it relies on are present, logging one clear line when they are not.
- **Its `AppExtensionConfiguration` accepts a connection only from a caller it validates**, and exports a protocol whose methods include `acquire`, `update`, `invalidate`, `snapshot`, `provideSettingsViewModels`, adding and removing choice requests, downloads, migration, skipping shuffled content, and debug requests. Apple's request types are read by reflection, since no SDK header declares them.
- **It draws into a remote `CAContext`** that `WallpaperAgent` hands it, through `AVSampleBufferDisplayLayer`.
- **Storage:** the extension is sandboxed and the app is not, so the app writes the video library into the extension's sandbox container and announces changes with a Darwin notification.

**Its author's caveats, paraphrased.** Any major macOS release could break it; Apple renaming fields in its request types would break it; and switching wallpapers quickly can wedge `WallpaperAgent`, which killing the process clears. The author's guide to reversing Apple frameworks adds that private-framework code cannot pass App Store review. The same guide says a sandbox will not let a process `dlopen` arbitrary private frameworks, while Phosphene's sandboxed extension does exactly that for one; the two are not reconciled here, and it was not looked into. *Measured 2026-09-14 by the probe: the sandboxed `dlopen` of `WallpaperExtensionKit` succeeds on this Mac.*

**What it means for this plan — Claude's reading, not measured:**

- **The pane is very likely reachable without Apple's entitlement, macOS 27 included.** The probe now confirms a known path on this Mac rather than testing a long shot.
- **The probe drops the private entitlement.** See *The extension probe*, revised.
- **The second probe has a map.** What `WallpaperAgent` asks of an extension is largely visible in Phosphene's source. It is MIT, but this project writes its own code rather than taking dependencies, so it is read for reference, not linked or copied.
- **A still is one frame** drawn into the same remote context Phosphene draws video into. Not checked.
- **The pane's wallpaper would be sandboxed.** Asking the agent needs permission to open network connections, and finding the port from inside the sandbox — the problem the saver solved by reading the preferences plist as a file.
- **Phosphene's storage model is one way for the app to hand the extension its settings.**
- **Syd's App Store point stands:** private-framework code cannot pass review.
- **`com.apple.wallpaper.development` probably no longer matters.**

## The extension probe

Claude's proposal, 2026-09-14. **Not built:** Syd asked for it to be captured here, and has not said to build it. **Revised the same day to follow Phosphene**, a third-party extension already in the pane — Syd: "yes". **Built and run that evening** — Syd: "yes, build the probe". See *What the probe found*, below.

**Three questions, in order, each yes or no:**

1. **Does macOS register it?** Syd runs `pluginkit -m -v -p com.apple.wallpaper`. Twelve, with ours among them, is a yes.
2. **Does System Settings › Wallpaper show it?** Syd opens the pane and says.
3. **Does it run?** The extension logs one `probe:` line when it starts. A refusal leaves a line of its own in the unified log, found by the extension's name; the probe's instructions give the `/usr/bin/log show` predicate for both.

A no at any gate ends it: the answer is "it cannot work", and route A is what is left for the pane. *It read "back to A or C" until C was ruled out for the system wallpaper, 2026-09-14.* *Weaker than it reads for gate 2, found when it was built: the pane lists a provider only from its answer to `WallpaperAgent`'s request for settings view models, which this probe cannot give, so an empty pane with gates 1 and 3 passing is not a no.*

**What is built:**

- A host app, `Photo-Go-Round Wallpaper Probe.app`, `LSUIElement`, which does nothing itself. An ExtensionKit extension ships inside an app, so something has to carry it.
- One extension in the host's `Contents/Extensions/`, with `EXExtensionPointIdentifier` = `com.apple.wallpaper`, sandboxed, and **no private entitlement** — Phosphene's shape; and a minimal `@main` on ExtensionFoundation's `AppExtension` that logs the `probe:` line and nothing more. *Revised 2026-09-14; it first carried `com.apple.private.wallpaper.extension` and `com.apple.security.app-sandbox`, copying Apple's.*
- The host registers the extension by being launched once, as Phosphene's app does.
- Deployment target macOS 27.0.
- **Two signatures, as two runs:** ad-hoc, and Syd's development identity. One may be refused where the other is not, and that is measured rather than guessed.
- **A script with `swiftc` and `codesign`, following `make-agent-bundle.sh`, so the Xcode project is not touched.** Its source sits beside `Scripts/wallpaper-probe.swift`, as the second wallpaper probe.
- **The output defaults to a directory under DerivedData**, never the checkout.
- **The script only builds.** Copying the app to `~/Applications` and registering it are Syd's, handed to him as commands, as every install is.

**What it does not answer.** Three yeses say macOS lets an extension of ours in; they say nothing about drawing. What the pane asks an extension for lives in `WallpaperExtensionKit`, `WallpaperFoundation` and `WallpaperTypes`, all private. So a pass leads to a second probe to find that out, and whatever it finds can change with any macOS update — the private store behind route A already moved once, in macOS 26. *2026-09-14: Phosphene's source is the best map of that protocol found so far, read for reference rather than linked or copied.*

**Left to Claude when it is built:** where exactly its source directory sits, and the host's and extension's bundle identifiers.

**Possibly a second extension, on `com.apple.wallpaper.development`** — proposed, then set aside once the shared cache search found nothing and Phosphene was found. See *The development extension point*.

**What was built, 2026-09-14.** Syd: "yes, build the probe".

- `Scripts/make-wallpaper-extension-probe.sh` compiles `Scripts/wallpaper-extension-probe/Host.swift` and `Extension.swift` with `swiftc` for macOS 27.0, assembles `Photo-Go-Round Wallpaper Probe.app` with `WallpaperProbeExtension.appex` in `Contents/Extensions/`, signs the extension with `com.apple.security.app-sandbox` alone and the host with no entitlements, both with hardened runtime, and verifies the result. `--sign` defaults to ad-hoc and `--output` to `~/Library/Developer/Xcode/DerivedData/photo-go-round/wallpaper-extension-probe`. It prints the install, gate and removal commands, and runs none of them.
- Bundle identifiers, Claude's picks: `com.sydpolk.photogoround.wallpaper-probe` and `com.sydpolk.photogoround.wallpaper-probe.extension`.
- Logging: subsystem `com.sydpolk.photogoround`, category `wallpaper-probe`, every line `.notice` and prefixed `probe:`.
- **Two additions beyond the design above, both Claude's, named to Syd when built:** the extension tries `dlopen` of `WallpaperExtensionKit` and logs the result, which tests the sandbox question in *Phosphene*; and it accepts connections, exporting nothing, and logs each one and its end.

**What the probe found, 2026-09-14,** on the development-signed build — `Apple Development: Sydney Polk (W8E4GRMLBV)`, team `R5PQPZARC5`. **The ad-hoc run has not been made.** Measured from the unified log and the crash report.

- **Gate 1, yes.** `pluginkit -m -v -p com.apple.wallpaper` listed twelve extensions, the twelfth `com.sydpolk.photogoround.wallpaper-probe.extension`, from `~/Applications`.
- **First run, 20:49: `WallpaperAgent` launched the extension, and the extension crashed.** `WallpaperAgent` began `provideSettingsViewModels` for it and launched it through runningboard, with sandbox profile `application`; nothing refused it. The extension logged that it had started in its own sandbox container and that `dlopen` of `WallpaperExtensionKit` had succeeded, then died with `EXC_BREAKPOINT` (SIGTRAP) inside `AppExtension.main()`, before any connection reached it. `WallpaperAgent` logged the query failing with `NSCocoaErrorDomain` 4099.
- **The cause was the build, not the system.** The crash report's stack ends in ExtensionFoundation's setup of `_EXRunningExtension._shared`. Disassembled, the trap is a nil check on a word inside `ExtensionMain.launchArguments`, whose field offset is `0x10`, the next field's `0x30`. Xcode's `app-extension` product type, which `extensionkit-extension` is based on, sets `LD_ENTRY_POINT = _NSExtensionMain` and `APPLICATION_EXTENSION_API_ONLY = YES`. `_NSExtensionMain`, in Foundation, hands over to ExtensionFoundation's `_EXExtensionMain`, which reads the launch arguments. The probe had been linked with an ordinary `main`. Phosphene's project overrides none of those settings, and Apple's `WallpaperSonomaExtension` and `WallpaperImageExtension` both import `_NSExtensionMain`.
- **The fix:** the script links the extension with `-e _NSExtensionMain` and builds it with `-application-extension`. The rebuilt binary's `LC_MAIN` points at the `NSExtensionMain` stub.
- **Second run, 21:06, after the probe was removed and registered again: gate 3, yes.** `WallpaperAgent` (pid 686) asked for settings view models, launched the extension and connected. The probe logged "connection from pid 686", and "invalidated" within a millisecond. `WallpaperAgent` logged `provideSettingsViewModels` failing with 4099, and "Could not update view model for choice provider com.sydpolk.photogoround.wallpaper-probe.extension". The same exchange came at 21:06:09, :10, :28 and :40, each reusing the running process, which runningboard suspended in between. No crash, and no line about entitlements or signing.
- **Gate 2: nothing in the pane — the caveat case.** `WallpaperAgent` asks, and the probe has nothing exported to answer with. That the empty export is why each connection is invalidated is Claude's reading, not measured.
- **The sandboxed `dlopen` of `WallpaperExtensionKit` works** on this Mac, which settles the contradiction recorded in *Phosphene*.

**So an extension of ours, with no private entitlement, is launched and asked by `WallpaperAgent` on macOS 27.** Whether it can be chosen and can draw is *The second probe*.

## The second probe

Claude's draft, 2026-09-14, at Syd's "yes" to recording the first probe's results and drafting this. **Not built, and not approved to build.** **Built and run that night** — Syd: "yes, build the second probe". See *What the second probe found*, below.

**What it answers:** whether a Photo-Go-Round section can be chosen in System Settings › Wallpaper and draw a still on the desktop. It asks the agent for nothing. A picture carried in the extension keeps the network, the agent's port, and the sandbox's view of preferences out of it.

**Three questions, in order:**

1. **Does the pane show a Photo-Go-Round section with one item?** The extension answers the request for settings view models with one group and one item; Syd opens the pane and says.
2. **Does choosing the item reach the extension?** Syd picks it; the extension logs the `acquire` it receives — the size asked for and the choice — and what it sent back.
3. **Does the desktop show the picture?** Syd looks and says. The log line for the reply is not evidence that the glass changed.

Each no is read against the log, which shows whether the request arrived and what was sent back.

**What `WallpaperAgent` asks, from Phosphene's source — read for reference, not copied:**

- **The calls.** Phosphene declares the protocol `WallpaperAgent` calls as `WallpaperExtensionXPCProtocol`: `provideSettingsViewModelsWithContentTypes:reply:` for the pane; `acquireWithId:request:reply:`, `updateWithId:request:reply:`, `invalidateWithId:reply:` and `snapshotWithId:reply:` for a surface; and calls for choices, downloads, migration, shuffling, debugging and notifications. The extension can call back through `WallpaperExtensionProxyXPCProtocol`, which includes `updateSettingsViewModels:reply:`.
- **The view models** are the private class `WallpaperSettingsViewModelsXPC`. Phosphene writes Codable mirrors of `WallpaperTypes`' values — view models holding groups; a group with an id, a name, a sort order, a sort id and items; an item with a choice id, a name, a thumbnail given as an image URL, a choice descriptor and a content badge — archives them with `NSKeyedArchiver` under a class name of its own, and unarchives them with `setClass` mapping that name to the real class. The same models serve the desktop picker and the screen saver picker.
- **The surface.** For `acquire`, Phosphene creates a remote `CAContext` through private QuartzCore API, gives it a root layer of the size the request names, and replies with an instance of the private `WallpaperRemoteContextXPC`, made with `class_createInstance`, whose `box` ivar it writes the context id into after checking the class's layout.
- **A still.** Phosphene draws video through `AVSampleBufferDisplayLayer`, and has a diagnostic path that hosts a still only, from a `CGImage` wrapped as a single sample buffer.

**What is built, as drafted:**

- The first probe's host, script and bundle identifiers, so the steps to register it are unchanged; the extension grows rather than a second one appearing.
- A bridging header declaring the two protocols and the private `CAContext` interface, compiled in with `-import-objc-header`.
- One group, "Photo-Go-Round", holding one item, "Probe Picture", whose thumbnail and picture are one JPEG in the extension's `Resources` — readable from inside the sandbox without asking for anything.
- The settings request answered as above. `acquire` answered with a remote context whose root layer shows the picture, aspect fit: Phosphene's still path first, and a plain layer's `contents` as the simpler alternative, the two measured in turn if the first does not draw.
- Every other call answered with an empty reply, and every call logged with a description of its arguments, so what `WallpaperAgent` sends is on record.
- The caller's pid logged on each connection. Phosphene checks the caller's audit token through private SPI; the probe leaves that out.

**Costs, named now:**

- **More private API, and a more brittle kind.** The first probe used the extension point and nothing else. This one depends on the private `CAContext` interface, on writing a context id into a private class's ivar, and on class and field names Apple can change in any release; Phosphene's README says renamed fields would break it.
- **The pane caches answers.** Phosphene's comments say that on macOS 26.6 `WallpaperAgent` keeps the view models on disk and asks again only after a reinstall or an OS update, so each rebuild is removed and registered again before it is judged. Not measured here.
- **A rendering fault can wedge `WallpaperAgent`** for every wallpaper, not only ours; Phosphene's remedy is killing it. That is Syd's to do, as everything running on his Mac is.

**What it does not answer:** pictures from the agent; the sandboxed extension's network permission and port discovery; a surface per display and per Space; the lock screen; snapshots for the pane's thumbnails; the *Shuffle All* interval; and the empty state.

**Left to Claude when it is built:** the picture, the group's and item's names, and the exact wording of the log lines.

**What was built, 2026-09-14.** Syd: "yes, build the second probe".

- The first probe's host, script and bundle identifiers, with the extension grown to four files in `Scripts/wallpaper-extension-probe/`:
  - `Extension.swift` starts, loads `WallpaperExtensionKit`, checks that the fifteen private classes are present, writes the thumbnail, and exports the handler on each connection;
  - `PaneHandler.swift` declares the protocol, allows the private classes on each object argument, logs every call, answers the settings request and `acquire`, and answers everything else empty;
  - `PaneModels.swift` is the section;
  - `ProbePicture.swift` is the picture, its thumbnail, and the still as a sample buffer.
- The script compiles the four files, raises the version to 0.2 (build 2), and prints this probe's gates.
- **Checked before Syd ran it:** a command-line harness in Claude's scratchpad loaded `WallpaperExtensionKit` and decoded the probe's archive as `WallpaperSettingsViewModelsXPC`. Walking the result with `Mirror` found every value in Apple's fields, for the desktop and the screen saver alike.
- **One warning, kept on purpose:** `AVSampleBufferDisplayLayer`'s `sampleBufferRenderer.enqueue` is deprecated on macOS 27, in favour of a render synchronizer's receiver taking a `CMReadySampleBuffer`. It is the call Phosphene is validated with on 27, and the probe asked whether a still draws, not how the newer API behaves. *Replaced 2026-09-14, when every minimum became macOS 27: the probe hands the frame to `AVSampleBufferRenderSynchronizer.sampleBufferReceiver(adding:)` and the receiver's `enqueueImmediately`, and logs the result. Not yet run.*

**Where it differs from the draft above — Claude's choices while building, named to Syd:**

- No bridging header. The protocol is declared in Swift with Apple's selectors, and `CAContext` is reached by name rather than declared.
- The picture is drawn in code — a blue-to-yellow gradient labelled "Photo-Go-Round wallpaper probe" — not carried as a JPEG. Its thumbnail is written into the extension's container, where Phosphene keeps its own, because the pane reads the thumbnail from a URL.
- Only the sample-buffer layer is used. Phosphene's author recorded that a plain layer's `contents` composites black in `WallpaperAgent`, so the draft's alternative was dropped.
- The section is offered to the screen saver picker as well as the desktop, as Phosphene does.
- The group's sort order, −100, and sort id, `com.apple.wallpaper.aerials`, are Phosphene's; what they mean has not been looked into.
- The surface is built, and the reply sent, on the main thread: the macOS 27 SDK makes `AVSampleBufferDisplayLayer`'s properties main-actor state, and XPC calls arrive elsewhere.

**What the second probe found, 2026-09-14,** on the development-signed build. Measured from the unified log; gates 1 and 3 also seen by Syd: "I see the section, the probe wallpaper, and the picture on the desktop."

- **The first attempt, at 21:59, never ran the new code.** Every line came from pid 38311 — the first probe's extension process, started at 21:06 and suspended since — because `WallpaperAgent` reuses a running extension process even after a new build is registered; `ps` confirmed its start time. The old code answered, and `WallpaperAgent` logged the same 4099 failures as before. The script's removal steps now begin with `killall WallpaperProbeExtension`; Syd ran it and opened the pane again.
- **Startup, 22:04:47, pid 45803:** sandboxed; `WallpaperExtensionKit` loaded; all fifteen private classes present; thumbnail written.
- **Gate 1, yes.** `WallpaperAgent` asked for settings view models, passing a `WallpaperContentTypeSetXPC`. The probe answered with 5,005 bytes decoded as `WallpaperSettingsViewModelsXPC`, and the section appeared.
- **Gate 2, yes.** Choosing the item at 22:04:55 brought two `acquire` calls, both 1800×1169 at 2x on display 1: one with `isPreview` false — the desktop — answered with remote context 2954774346, and one with `isPreview` true — the pane's preview — answered with context 3318084944.
- **Gate 3, yes.** The picture is on the desktop.
- **Behind the working result:** five `snapshot` calls between 22:04:55 and 22:05:00, each answered with nothing and each followed by `WallpaperAgent` logging "Failed to create snapshot to export"; what the snapshot is for — the lock screen, or an exported copy — is not known. And one `isChoiceDownloaded` failing with 4099 at 22:04:55.355, in the nine milliseconds between one connection closing and the next opening; Claude's reading is a race on the closing connection rather than a bad answer. No other errors.
- **The request-field log line is swamped** by the bytes of the choice's configuration data, so the fields that matter were cut off the end of it. The size, scale, display and preview flag were still found. Worth trimming in the next probe.

**So a Photo-Go-Round section can be chosen in System Settings › Wallpaper and can draw a still on the desktop on macOS 27**, from a sandboxed extension with no private entitlement. Not yet asked: the ad-hoc signed run, pictures from the agent, snapshots and the lock screen, Spaces and several displays, and sleep and wake.

## The third probe: snapshots and the lock screen

Claude's draft, 2026-09-14, after Syd chose snapshots and the lock screen as the next step: "1." **Not built, and not approved to build.** **Built that night** — Syd: "yes, build the third probe" — **and run 2026-09-15: both gates passed at version 0.3.2.** *Until then: "and not yet run."* See *What the third probe found*, below.

**Why this one first.** It is the one thing already failing in the second probe's log, and it grows the probe that exists.

**What is known — measured on this Mac, from the second probe's run:**

- When the probe's item was chosen, `WallpaperAgent`'s export controller logged "Existing exported wallpaper does not match the expected wallpaper - exporting new default wallpaper", and then "No existing exported wallpaper exists - exporting default wallpaper" four more times. Each time it went through translating, wallpaper lookup and snapshotting, called the probe's `snapshot`, received nothing, and ended "Failed to create snapshot to export", with `WallpaperExtensionError` 2.
- So a snapshot is how `WallpaperAgent` makes an exported copy of the chosen wallpaper. `wallpaperexportd` logged nothing in that window; nothing reached it.
- `WallpaperAgent`'s entitlements name `/Library/Application Support/com.apple.wallpaper/` and `com.apple.private.wallpaper.export`.

**Not known:** where the exported copy is written, and what reads it. The lock screen, the login window before anyone logs in, and the pane's thumbnails are the likely readers; none of them is measured.

**What Phosphene does — read from its source, not run:**

- **`snapshot` is answered with a `WallpaperSnapshotXPC` holding a BGRA `IOSurface` of one frame.** The instance is made with `class_createInstance`, and a retained pointer to the surface is written at offset 8, where Phosphene assumes a `rawValue` holding the surface reference sits, after checking that the instance is big enough.
- **Separately, it writes a 24-bit BMP of the frame into the cache directory `WallpaperAgent` passes with each `acquire`,** reached as a security-scoped URL and named `<hash of the choice>-<width>-<height>-0-<timestamp>.bmp`. Its comment calls this Apple's "Using existing snapshot as initial wallpaper contents" pattern.
- **It calls `invalidateSnapshots` on `WallpaperAgent` when the choice changes,** so the pane fetches a fresh one.
- **Its README warns** that Apple's snapshot encoder checks that the coder is exactly `NSXPCCoder` while the real coder is a subclass, so that without a runtime method swap snapshots encode to nothing and the lock screen goes grey during transitions. **No such swap was found** in any Swift, Objective-C or header file in its repository on 2026-09-14. Whether it was removed, or the warning is stale, is not known.

**Three questions, in order:**

1. **Does the export succeed?** `WallpaperAgent` logs the export without "Failed to create snapshot to export", and the probe logs the snapshot it sent.
2. **Does the lock screen show the picture?** With the probe picture chosen, Syd locks the screen and says.
3. **If the export still fails with a snapshot sent, did the snapshot arrive empty?** The log is read for an encoding failure — the case Phosphene's README describes.

**What is built, as drafted:**

- The second probe grown again, with the same host, script and identifiers, at version 0.3.
- `snapshot` answered with the probe picture drawn into a BGRA `IOSurface`, at the size of the last desktop `acquire`, wrapped in `WallpaperSnapshotXPC`. The class's ivars are logged with `class_copyIvarList`, and the surface pointer is written only if they show a pointer-sized field at offset 8, as Phosphene assumes; otherwise it fails closed and says so.
- The `acquire` request's `cacheDirectory` field logged, with whether it can be reached. No BMP is written in this probe: the export is the question.
- **No method swap in this probe.** If gate 3 shows the snapshot arriving empty, the swap is the next step, drafted then.
- The request-field log line trimmed, so `Data` contents are no longer walked and the fields that matter are not cut off.
- Removal steps as before, including `killall WallpaperProbeExtension`.

**Costs, named now:**

- **Another private class filled by writing into its memory,** and a retained `IOSurface` handed over as a raw pointer whose release is Apple's to do. If the assumption about the field is wrong, that is a leak or a double release inside `WallpaperAgent`.
- **If gate 2 passes, the lock screen shows the probe picture too.** Syd puts his own wallpaper back in the pane afterwards.

**What it does not answer:** where the export is written, beyond what the log names; the login window before anyone logs in; pictures from the agent; snapshots after the picture changes.

**Left to Claude when it is built:** the wording of the log lines.

**What was built, 2026-09-14.** Syd: "yes, build the third probe".

- **`snapshot`** answers with the picture drawn into a BGRA `IOSurface`, aspect fit on black, at the pixel size of the last desktop `acquire` — 1920×1080 if none has arrived yet — wrapped in `WallpaperSnapshotXPC`. The class's size and ivars are logged first, and the retained surface pointer is written only if an ivar sits at offset 8 with room for a pointer before the next one.
- **`acquire`** remembers the desktop's pixel size, and logs the request's cache directory: its path, whether the security scope was granted, and how many entries can be read — a count, not the names.
- The request-field log line no longer walks the contents of `Data` values.
- Version 0.3, build 3, and the script's printed gates are this probe's.
- **Checked before Syd runs it:** a harness in Claude's scratchpad, built from the probe's own sources, loaded `WallpaperExtensionKit` and found `WallpaperSnapshotXPC` to be 16 bytes with one ivar, `rawValue`, at offset 8, so the guard passes. Reading the reply back with `Mirror` gave a `WallpaperSnapshot(surface:)` holding the 3600×2338 BGRA surface written. Encoding it across XPC, where Phosphene's README places the trouble, is out of a harness's reach.
- **Changed 2026-09-15, before it ran.** When every minimum became macOS 27, the deprecated `enqueue` was replaced by `AVSampleBufferRenderSynchronizer.sampleBufferReceiver(adding:)` and the receiver's `enqueueImmediately`, which needed `RemoteSurface.make` to take its sample buffer as `sending`. The probe builds with no warnings. **So its first run also checks that the desktop still shows the picture** — the second probe's gate 3, against the new call.
- **Not yet run.** *Run 2026-09-15; see below.*

### What the third probe found

Run on Syd's MacBook Pro, 2026-09-15, development-signed, in three builds.

**0.3: the desktop went gray.** Syd: "no, the desktop is a dark gray image. The wallpaper is set to Photo-Go-Round, but the picture is wrong". The probe logged the frame enqueued and a 3600×2338 snapshot sent, and `wallpaperexportd` logged "Successfully exported wallpaper". Two changes were new since the second probe — the macOS 27 enqueue, and answering `snapshot` — so either could be the cause.

**0.3.1, the bisect: no snapshots answered, and the picture showed.** Syd: "wallpaper is now blue and yellow test image". So the macOS 27 enqueue works, and answering the snapshot was what went wrong. The export failed again, as in the second probe.

**Why, measured on this Mac:**

- **The snapshot itself was sound.** `WallpaperSnapshotXPC` conforms to `NSSecureCoding`. Its `encodeWithCoder:` casts the coder to `NSXPCCoder` with `swift_dynamicCastObjCClass`, turns `rawValue` into an XPC object with `IOSurfaceCreateXPCObject`, and calls `encodeXPCObject:forKey:` with the key `surface`. `initWithCoder:` reads it back with `decodeXPCObjectForKey:` and `IOSurfaceLookupFromXPCObject`. Read from a disassembly of `WallpaperExtensionKit`.
- **It crosses a real connection intact.** A harness sent the probe's own 3600×2338 surface, wrapped as the probe wraps it, through an anonymous `NSXPCListener`. The far side got the same surface ID and the same pixels. *This corrects* What was built*, above, which said encoding across XPC was out of a harness's reach.*
- **Phosphene's README warning did not apply here.** `swift_dynamicCastObjCClass` accepts a subclass, and the export succeeded without a method swap. Whether it applied on an earlier macOS is not known.
- **The probe mixed up its own surfaces.** It held each surface under the text description of the request's id — `<WallpaperIDXPC: 0x7676e25140>`, an address in the extension's own process. In 0.3, after the snapshot was answered, `WallpaperAgent` dropped the connection, reconnected, and asked for a desktop surface and a preview surface. Both requests arrived at the same address. The preview's surface replaced the desktop's under that one key — the probe logged "holding 4 surfaces" twice, with no increase — and the desktop's remote context was freed. In 0.3.1 there was no reconnect, so no collision.
- **Not established:** why answering the snapshot brings the reconnect.

**0.3.2: surfaces held by display and by desktop or preview, and snapshots answered again.** The log showed "kept as display 1, desktop" and "kept as display 1, preview".

1. **The desktop kept the picture.** Syd: "yes".
2. **Gate 1, the export, passed.** At 08:39:55 `WallpaperAgent` took the probe's snapshot, and `wallpaperexportd` logged "Successfully exported wallpaper".
3. **Gate 2, the lock screen, passed.** Syd, after Control-Command-Q: "yes".
4. Gate 3 was needed only if the export failed.

**Also learned:** the id is `XPCBox<WallpaperID>` holding a real UUID — `WallpaperID(id: 6C276937-0D3D-4D5D-8BB1-D8C530B4F723)` for the desktop, a different UUID for the preview. The real extension can key its surfaces by that UUID rather than by display.

**So a Photo-Go-Round extension can answer snapshots, `WallpaperAgent` exports them, and the lock screen shows the picture** — still from a sandboxed extension with no private entitlement, and with no encoder workaround. Not yet asked: the ad-hoc signed run, pictures from the agent, Spaces and several displays, sleep and wake, the login window before anyone logs in, and snapshots after the picture changes.

**What changed in the build, 2026-09-15:**

- `PaneHandler.swift` — surfaces keyed by display and by desktop or preview; the id's fields logged with their values; `answersSnapshots`, false for 0.3.1 and true again for 0.3.2.
- `Scripts/make-wallpaper-extension-probe.sh` — version 0.3.2, build 5; installs and registers after building, unless `--build-only`; signs with Syd's development identity by default.
- `Documentation/Wallpaper Extension Probe.md` — the steps, new.

## The fourth probe: pictures from the agent

Claude's draft, 2026-09-15, after Syd chose pictures from the agent as the next step: "1." **Not built, and not approved to build.** **Built the same morning** — Syd: "yes, build the fourth probe" — **and run: all three gates passed.** See *What the fourth probe found*, below.

**Why this one next.** Every probe so far has shown a picture it drew itself. A wallpaper that cannot reach the agent is not Photo-Go-Round, and it is the first question where the extension's own sandbox, rather than `WallpaperAgent`, decides the answer.

**What is known — read and measured before this draft:**

- **The agent is localhost HTTP.** `GET /v1/next?consumer=…&display=<uuid>&w=…&h=…`, on a port the agent chooses at launch and publishes as `servicePort` in its preference domain — `com.sydpolk.photogoround.dev` in development, `com.sydpolk.photogoround` in production. `PictureClient` reads it fresh on every request. *Read from the code.*
- **`system-wallpaper` needs nothing in the agent.** `PictureEndpoint` takes the consumer name as it comes, and `ConsumerKind` is deliberately not an enum. *Read from the code; see* Two wallpapers, told apart in the log.
- **The saver's sandbox answered both halves, and ours differs on both.** `legacyScreenSaver` grants `network.client` and read-only access to `/`. Inside it, localhost HTTP worked, `UserDefaults(suiteName:)` came back empty rather than refusing, and reading the plist as a file worked. *Measured 2026-09-07;* Screensaver Plan.md, *The question the entitlements do not answer: finding the port*. **Our extension is sandboxed on its own terms** — its only entitlement today is `com.apple.security.app-sandbox` — so it has neither grant.
- **`ServicePort` already reads the suite first and the plist underneath**, falling through on empty, because empty is what the refusal looks like.
- **Apple's Aerials extension carries `com.apple.security.network.client`**, and temporary exceptions for its own preference domains and folders. *Read from its signature on this Mac.*

**Three questions, in order:**

1. **Can the extension find the port?** Through `UserDefaults(suiteName:)` with a `temporary-exception.shared-preference.read-only` naming our domains, or through the plist read as a file with a `temporary-exception.files.home-relative-path.read-only` naming it — each logged on its own, so they come apart the way the saver's did.
2. **Can it connect?** With `network.client`, a request to that port answers `200`, and the agent logs `consumer=system-wallpaper` with the display's UUID.
3. **Does the desktop show the photograph?** Decoded in the extension and handed to the same `AVSampleBufferDisplayLayer` that shows the generated picture now.

**What would be built:**

- The third probe grown again, at version 0.4, with the same host, script and identifiers.
- **Entitlements:** `com.apple.security.network.client`; `com.apple.security.temporary-exception.shared-preference.read-only` naming `com.sydpolk.photogoround.dev` and `com.sydpolk.photogoround`; `com.apple.security.temporary-exception.files.home-relative-path.read-only` naming both plists under `/Library/Preferences/`.
- **On each desktop `acquire`:**
  - reply at once with the generated picture, as now;
  - then, off the main thread, read the port both ways for both domains and log each result, with the domain and which read found it;
  - ask the agent as `system-wallpaper`, with the display's UUID from `CGDisplayCreateUUIDFromDisplayID` and the desktop's pixel size;
  - log the status, byte count and time taken;
  - decode the photograph and enqueue it on that surface's layer, replacing the generated picture; if any step fails, the generated picture stays and the log says which step.
- **`snapshot`** answers with whatever that display's surface is showing — the photograph once it has arrived.
- **The preview** keeps the generated picture, so the pane does not spend a card each time it is opened.
- **Its own lines** keep the `probe:` prefix. The `system-wallpaper:` prefix belongs to the real extension.
- **No code shared with the app.** The probe writes its own small port read and request rather than linking `PhotoGoRoundDisplay`, as the earlier probes are built with `swiftc` from their own sources. Whether the real extension links `ServicePort` and `PictureClient` is for when it is built.

**Costs, named now:**

- **Temporary exceptions.** App Review rejects them, which does not matter while private frameworks already rule the App Store out; they are also what a later sandboxing decision would have to revisit.
- **Each desktop `acquire` spends a card** from the shared queue, and `WallpaperAgent` acquires more than once when a wallpaper is chosen — four times in the 0.3 run. The log will show how many.
- **The probe runs against Syd's running agent and library.** The desktop shows one of his photographs.

**What it does not answer:** changing the picture on a timer; several displays and Spaces; sleep and wake; the empty state when the agent is not running; whether the change times and interval in `com.sydpolk.photogoround.wallpaper.{dev|prod}` can be read too; the ad-hoc signed run.

**If both port reads fail**, a third route needs no exception: the agent, which is not sandboxed, writes the port into the extension's container, which the extension can always read. That changes the agent, so it is drafted only if this probe needs it. Phosphene's app hands settings to its extension the same way.

**Left to Claude when it is built:** the wording of the log lines; the request timeout; the order the two reads and two domains are tried in.

**What was built, 2026-09-15.** Syd: "yes, build the fourth probe". As drafted, with these specifics:

- **`AgentPicture.swift`, new.** For each domain, development first, the suite and then the plist are read and each is logged. The plist is read from the real home found with `getpwuid`, with no `fileExists` check first, so the read's own error tells a refusal from a missing file. The request goes to each port found in turn: a transport failure moves to the next, and any HTTP answer is final. The timeout is ten seconds. Decoding uses `CGImageSourceCreateThumbnailAtIndex`, at no more than the desktop's longest side, with the file's orientation applied.
- **`PaneHandler.swift`.** After a desktop `acquire` has replied, the request runs on a utility queue. The photograph is enqueued on the main thread through the surface's existing receiver, and only if the surface held for that display is still the one the request was made for. `snapshot` draws whatever the desktop shows.
- **The script.** Version 0.4, build 6, with the three entitlements drafted.
- **Checked before Syd ran it:** a harness outside the sandbox, built from `AgentPicture.swift`, found port 52100 through both reads of `com.sydpolk.photogoround.dev` and none in `com.sydpolk.photogoround`. It spelled display 1's UUID as `WallpaperAgent` logs it, and decoded a JPEG. It asked the agent for nothing, so no card was spent.

### What the fourth probe found

Run on Syd's MacBook Pro, 2026-09-15, at 08:59, development-signed, against the app's running agent.

1. **Gate 1, the port — passed.** Inside the extension's sandbox, both the suite and the plist gave `servicePort 52100` for `com.sydpolk.photogoround.dev`. The production domain opened with no port in it, which is its ordinary state on this Mac.
2. **Gate 2, the agent — passed.** The request `…/v1/next?consumer=system-wallpaper&display=37D8832A-…&w=3600&h=2338` answered `200` with 864,507 bytes in 225 ms. `photogoroundd` logged `served status=200 consumer=system-wallpaper`, card 2881, deal 81972, `scan20040509_190112.tiff` from Photos › Favorites, and its own window showed "system-wallpaper · display 37D8832A-… · 3600x2338".
3. **Gate 3, the photograph — passed.** Decoded at 1488×1810 and enqueued on the desktop's surface 450 ms after the generated picture. Syd: "but I do see a picture from the rotation."

**Also learned:**

- **A second `enqueueImmediately` on the same receiver replaces the still.** A slideshow can change pictures on a surface it already holds, without a new `acquire`.
- **One card spent.** This run brought one desktop `acquire` and one preview `acquire`, so one request. The four acquires of the 0.3 run came with a reconnect.
- **The snapshot came before the photograph.** `WallpaperAgent` asked for it at 08:59:01.256; the photograph arrived at 08:59:01.723. So the export, and probably the lock screen, hold the generated picture until a later snapshot. Not checked on the lock screen in this run.

**Not established:**

- **Which exception each read needs.** Both were granted, so the run shows that each read works with both in place, not that either is enough alone. In `legacyScreenSaver`, which has no preference exception for our domain, the suite came back empty.
- **Whether a stale plist port bites.** The agent had been running for a while, so the file and the suite agreed.

**So a Photo-Go-Round extension in the Wallpaper pane can find the agent, ask it as `system-wallpaper`, and put a photograph from the shared queue on the desktop**, still sandboxed, still with no private entitlement, and now with `network.client` and two temporary exceptions. Not yet asked: changing the picture on a timer; refreshing the snapshot when the picture changes; several displays and Spaces; sleep and wake; the empty state; the ad-hoc signed run.

## The bundle, like the saver's

Claude's proposal, 2026-09-14, in answer to "Wallpapers needs its own binary/bundle so that it can be set from System Settings and run without the app" and "I am expecting something very similar to Scripts/make-saver-bundle.sh". **It was written before the pane was asked for.** If an extension turns out to work, the pane hosts the wallpaper rather than launchd, and much of this changes; it is recorded as proposed.

**The LaunchAgent in it waits on the system wallpaper route.** Syd, 2026-09-14: "I don't see the LaunchAgent method as viable in the system wallpaper case", then "don't want launch agent at all if system wallpaper route can be figured out." So the plist in `~/Library/LaunchAgents`, `launchctl bootout` and `bootstrap`, and the host running the loop under launchd are built only if that route cannot be figured out. The script modelled on `make-saver-bundle.sh` stands either way.

- **An Xcode target, `Photo-Go-Round Wallpaper`**, building `Photo-Go-Round Wallpaper.app`: `LSUIElement`, bundle identifier `com.sydpolk.photogoround.wallpaper`, unsandboxed, linking `PhotoGoRoundAgentAPI` and `PhotoGoRoundDisplay` as the saver does.
- **A host in `app/wallpaper/Sources`** doing what `AppDelegate` does now: `Wallpaper.desktop()`, `watchTheSystem()`, `resume()`. The loop does not move, and its domain and directory stay `com.sydpolk.photogoround.wallpaper.{dev|prod}`, which cannot collide with the bundle identifier because both carry a suffix.
- **`Scripts/make-wallpaper-bundle.sh`**, with the saver script's options — `--output`, `--release`, `--install`, `-h` — and `xcodebuild` underneath.
- **`--install` writes launchd's plist to `~/Library/LaunchAgents` and restarts the job with `launchctl bootout` and `bootstrap`**, where the saver script has its `killall`. Syd: "whatever launchctl needs should be put into ~/Library/LaunchAgents so multiple users don't clobber each other."
- **The AFTERWARDS text** says the agent must be running, and gives the `/usr/bin/log show` line for category `wallpaper`.

**Where it does not fit what is already decided — each named to Syd, none answered:**

- **Where the bundle lives.** The saver's `--install` copies its bundle into `~/Library/Screen Savers`. For the agent, Syd decided "the binary stays in the app bundle", and *Its own binary* says the wallpaper follows that shape. A standalone install puts the bundle somewhere else — `~/Applications`, as `make-agent-bundle.sh --install-to` suggests.
- **Whether the script runs `launchctl`.** `make-saver-bundle.sh --install` installs outright; `make-agent-bundle.sh` prints the commands instead, because "putting a login item on a Mac is the owner's call."
- **Two hosts must not both run the loop.** The app and the bundle together ask for every display twice and spend two cards for one picture. TODO.md's *A wallpaper bundle* says the same.
- **The checkbox reaches another process late.** `Wallpaper` reads `enabled` once, in `init`, so ticking or unticking it in the app does not start or stop a separate process until that process restarts. The interval has no such problem; it is read on every use.

## Two wallpapers, told apart in the log

Syd, 2026-09-14: "the logging for fetches from the system wallpaper panel should say "system-wallpaper" to distinguish it from the app-based "wallpaper" now. We will continue to support both until I decide on trying to sandbox or not." And of sandboxing: "you are right about the App Store; that is what I meant."

**What says it.** The agent's served line prints `consumer=` as whatever the client put on the wire, so the name is the client's to choose. The pane's wallpaper asks as `system-wallpaper`; the app's keeps asking as `wallpaper`.

**Nothing in the agent changes** — read from the code on 2026-09-14, not run. *Run 2026-09-15 by the fourth probe: the agent served `consumer=system-wallpaper` unchanged; see* What the fourth probe found.

- `PictureEndpoint` takes `request.query("consumer")` as it comes, prints it in the served line, and passes it to the dashboard's tally, which counts pictures by consumer name.
- It registers the deck's consumer as `ConsumerKind(request.query("consumer") ?? "cli")`. `ConsumerKind` is deliberately not an enum, and the schema has no CHECK on the column; `Consumer.swift`: "a new surface is meant to be a new consumer row rather than a new code path in the deck."

**What a second name brings with it:**

- A consumer's identity is `(kind, display)`, so a display fed by both wallpapers has two consumer rows, and the dashboard counts the two apart.
- Phase 1's exit gate, counted from `consumer=wallpaper`, keeps meaning the app's wallpaper alone.
- Both still draw from the one shared queue.

**Proposed by Claude, not decided:**

- A constant `ConsumerKind.systemWallpaper`, spelled `system-wallpaper`, beside `.wallpaper`, so no client writes the string by hand.
- The pane wallpaper's own log lines — as distinct from the agent's served line — prefixed `system-wallpaper:`, beside the app's `wallpaper:`, so one word filters either.
- If `Documentation/photogoroundd.md` names consumer kinds when this is built, it gains this one, with a test.

**Supporting both:**

- **Both on for one display — answered: not supported.** The pane's wallpaper and the app's would each set that display's desktop: whichever set last shows, and two cards are spent for one picture. It is *The bundle, like the saver's*' "two hosts must not both run the loop" in a new form. Syd, 2026-09-14: "I am ok with not supporting app and system wallpapers and the two systems fighting each other." So nothing detects it, hands over between them, or warns. *That answers the pane's wallpaper against the app's only; the app against a LaunchAgent bundle, route C, is still open under* The bundle, like the saver's.
- **Route A's fetches.** A folder the pane rotates is also fed from the agent; whether those fetches are `system-wallpaper` too is open.
- **Where the pane's wallpaper keeps its state.** Whether it shares the per-display change times and the *Shuffle All* interval in `com.sydpolk.photogoround.wallpaper.{dev|prod}` or has its own is open — and a sandboxed extension may not be able to read that domain at all, which is what the saver found inside `legacyScreenSaver` (TODO.md, *An Options button for the screensaver*).

## macOS 27 and later

Syd, 2026-09-14: "this will very soon be MacOS 27+ only." The probe targets 27.0 on its own. `Package.swift` still says `.macOS("26.0")`, with a comment that it is held there so the server runs on a second Mac kept off betas; raising that line is Syd's, and nothing here changes it. *Raised 2026-09-14. Syd: "you can go ahead and upgrade everything to our minimum support to macOS 27, so yes, use the OS 27 APIs." `Package.swift` says `.macOS("27.0")`, and every other macOS minimum in the project moved with it; see `PLAN.md`,* The 27.0 baseline, and the temporary 26.0 hold.

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

**Naming.** `<display UUID>.<extension>` — *two of them per display, `-a` and `-b`, since the redraw measurement below* — with the extension taken from the served `Content-Type` — `heic` in practice, since `PictureClient` sends no `Accept` and the service's default is HEIC. The system decides how to read the file from its name.

**Written atomically**, so the system never reads a half-written file.

**Never deleted.** `setDesktopImageURL` sets the current Space on one screen, so other Spaces may still point at a file this display showed earlier. If the extension ever changes, the previous file stays behind; deleting it could blank a Space nobody is looking at.

**The unknown that Phase 1 answers first: does rewriting the same URL redraw?** The system may cache the decoded desktop by URL and ignore a call naming the URL it already has, even when the file underneath it has changed. If so, each display alternates between two names (`<uuid>-a`, `<uuid>-b`), which costs one extra file per display and nothing else. It is measured rather than assumed: the first run sets the same name twice and Syd watches whether the desktop changes. Reading `desktopImageURL(for:)` back will not answer it, because it reports the URL whether or not anything redrew.

**Measured 2026-09-10: it does not redraw.** The probe set a blue picture at one name, rewrote the file as yellow five seconds later — atomically, as the wallpaper writes — and set the same URL again. The desktop stayed blue. So each display alternates between two names, `<uuid>-a.<extension>` and `<uuid>-b.<extension>`, and every change writes and sets the one not currently shown. The stored file URL says which that is.

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

**Measured 2026-09-10: leaving it out keeps it.** With `Scripts/wallpaper-probe.swift`, a tall yellow picture set with no `.fillColor` showed blue bands — Syd's chosen fill, which the system reported as sRGB 0.319 0.495 0.724. To rule out the system's default happening to be that same blue, Syd chose red in System Settings, which recoloured the bands around our picture at once. The probe then set the picture again with no `.fillColor`: the bands stayed red, and `desktopImageOptions(for:)` reported sRGB 0.813 0.363 0.274. So the options carry scaling and clipping and nothing else, and System Settings stays in charge of the colour — including over a picture we set.

The agent never enlarges — `PhotoRenderer` returns a small original at its own pixels — so the system does the enlarging, exactly as the screensaver's `AspectFit` does. `PLAN.md`'s *Beyond 0.1* holds the upscale cap and the other fits, and Syd's "options later" covers them.

**Asking at the display's native pixels.** `screen.convertRectToBacking(screen.frame)` gives the size in pixels, which is what the box on the wire is measured in. A 5K display asks at 5120×2880, so a HEIC of a few megabytes arrives and is written once per half hour, which is negligible. *While the interval was sixty seconds it was a few megabytes a minute per display; since 2026-09-13 it is once per half hour again.*

## Timing

- **Every thirty minutes per display, measured from that display's stored change time.** See *The time each display last changed*. The interval was first a `Duration` constant beside `Shuffle.defaultDwell`. **Changed 2026-09-10: sixty seconds, and a preference.** Syd: "could we make the internal for the wallpaper 60 seconds for now?", then "this should be part of the wallpaper preferences." **Changed again 2026-09-13: thirty minutes when unset.** Syd: "set both the default and the current time between serving wallpaper to 30 minutes." It is `intervalSeconds` in the wallpaper's domain — thirty minutes when unset, read on every use rather than once at start, parsed with a default and clamped to between ten seconds and seven days, as every preference is. The loop sleeps no longer than thirty seconds, so a `defaults write` applies within that and never needs a restart, which is `PLAN.md`'s rule for every preference.
- **Not at launch, unless a display is due.** "At start, straight away" was Claude's proposal, on the grounds that a wallpaper which waited half an hour would look broken. Syd overturned it the same day: "the image should not be changed before the time interval (initially 30 minutes) if it has previously been saved, even if the binary was just started up." The grounds survive in a narrower form: a display with no stored time — the very first run, or a monitor never seen before — is due, so the first launch still changes every display at once.
- **One question, asked every time: which displays are due?** At launch, on wake, when the loop's sleep ends, and when a display appears. Each due display gets a new picture, and the loop then sleeps until the earliest stored time plus the interval. This replaces the earlier design's in-memory "last complete round" and its separate wake check, which were two answers to the same question.
- **Across sleep, by the wall clock.** On `NSWorkspace.didWakeNotification` the question is asked again, so a Mac that slept through a change makes it when it wakes. This does not rely on a sleeping `Task.sleep` noticing the time that passed, which has not been measured.
- **Displays keep their own schedules.** Two displays that last changed at different times stay apart, and nothing pulls them back into step. A display unplugged and plugged back in picks up its own schedule, because its UUID is the key.
- **A retry a minute later when a display got nothing**, whether from an empty library or no agent. Its stored time is left alone, so it stays due. Nothing goes blank while it waits, so there is no reason to match the screensaver's three seconds.
- **One request in flight at a time.** An event that arrives while a display is being changed lets that change finish.

`PLAN.md` suggested a `DispatchSourceTimer` checking the wall clock. A cancellable `Task` loop that works out the next due time on every event does the same job and matches how `Shuffle` is built.

## The time each display last changed

Syd, 2026-09-10: "we should store (per display) a preference storing the time the picture was changed for that display. And the image should not be changed before the time interval (initially 30 minutes) if it has previously been saved, even if the binary was just started up."

**What is stored, keyed by display UUID:** the time that display's picture last changed. Claude proposes storing the file's URL beside it. The name is not fixed: the extension follows the served type, and the redraw question may make each display alternate between two names. A launch that is not due has changed nothing, but it still needs to know which file each display is showing so it can put it back at that launch and on Space and display changes. **Built that way:** the key `displays`, holding `[display UUID: ["changedAt": date, "file": path]]`, readable with `defaults read` on the wallpaper's domain.

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

**One route to the default, measured 2026-09-10.** The probe's `restore` set Syd's saved desktop URL back — his `~/Pictures/` folder, since System Settings was rotating through it — and the desktop became the Golden Gate default instead of resuming the rotation. A desktop pointed at something that is not a picture is one way to get there. Whether it is the way behind the reversions `PLAN.md` describes is not known.

## An empty library, a missing agent, and the log

- **A `204`, or no agent at all: the desktop keeps what it has**, whether that is our last picture or something the user chose. The retry follows a minute later.
- **Failures are described in `Shuffle`'s own words** — `no photos`, `no agent: …`, `not answering: …` — by reusing `Shuffle.trouble(from:)` instead of writing the mapping a second time. That means taking `private` off it.
- **Logged when they change, not every time.** A retry every minute with the agent down would otherwise be a line a minute all night. A new trouble is `.notice`, a repeat is `.debug`, and recovery is one `.notice`. This is the same rule `Shuffle.note` follows.
- **Every change is one `.notice` line**: the display, card, deal, the pixels served and asked for, and the file name. That is two lines an hour per display — sixty an hour while the interval was sixty seconds — and it is the line the exit gate is counted from — the lesson of the screensaver's overnight run, whose `.info` line had evaporated by morning.
- **A display with no UUID is skipped and says so**, because it has no file name. `DisplayShuffles` adopts the sole identified display in that case; the wallpaper has no reason to, since it asks per screen rather than per view.
- **After each set, the URL the system reports is compared with the one just set**, and a mismatch is logged. It is cheap, and it is the first place to look when a desktop does not change. **It can lag, measured 2026-09-10:** the first set over Syd's folder rotation put the new picture on screen while the same process read back the folder, and a later set read back correctly. So a mismatch is logged as what the system reported, and never acted on.

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

**Built 2026-09-10.** `display=` follows `consumer=` in the unified-log line, `display <uuid>` follows the consumer on the console, and a request that names no display logs `display=none`. Two tests in `RequestLogTests`, and the man page sentence now reads "with the consumer, the display it named, the size asked for…". **Grown since, 2026-09-12**: the served line also names the photograph and its source — `name=` and `sourceName=` in the unified log, public — and the man page sentence reads "with the photograph's name, the consumer, the display it named, the source's row id and name, …". See `PLAN.md`, *The agent's dashboard*.

## What it costs the shared queue

Two cards an hour per display, against the screensaver's 341 an hour. **At sixty seconds it was sixty an hour per display** — about a sixth of the screensaver's rate — from 2026-09-10 to 2026-09-13; at thirty minutes it is two an hour again. The wallpaper therefore sees what `PLAN.md` already describes: "a near-random sample rather than a slow walk", because a screensaver session in between can roll through the library. That is accepted there, and worth confirming it still reads as right once it is on the desktop.

## Testing

The loop is written so a test drives it without touching anybody's desktop: the list of displays, the call that sets a desktop, and the clock are all passed in as closures. In `Tests/PhotoGoRoundDisplayTests`:

- each display is asked for as `wallpaper`, at its own pixel size, under its own UUID
- the bytes land in `<uuid>-a.<extension>` or `<uuid>-b.<extension>`, alternating from one change to the next, and that file is what the desktop is set to
- the options carry scaling and clipping and no fill colour
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
- `intervalSeconds` is thirty minutes when unset — sixty seconds until 2026-09-13 — a changed value applies without a restart, nonsense is ignored or clamped, and the loop looks again at least every thirty seconds — and every other test sets its interval through the preference, the way `defaults write` would

What no test can reach is whether the desktop actually changes, whether the same URL redraws, and how Spaces behave. Those are answered by Syd running it and by the log lines above — the same standard the screensaver was held to.

**Built 2026-09-10: 22 tests in `WallpaperTests` and two in `RequestLogTests`; 767 across the package, all passing.** The first run failed two of the wallpaper tests, and the fault was in the tests: they moved on when the agent was asked, and the ask is recorded before the picture arrives. One found nothing set yet; the other advanced the clock mid-round, which stamped the later time on the record, so the display was correctly not due. They wait for the set now, through `firstPictureSet`, which says why.

## What was built

**Phase 1, built 2026-09-10 after the probe.** The exit gate has not been run; that is Syd's.

**First run, 2026-09-11, on Syd's MacBook Pro.** "The checkbox works. I see wallpaper from the sources. I see from the logs that wallpaper served from the queue." So the whole path held on its first run: the checkbox starts the loop, the loop asks the agent as `wallpaper`, the agent serves it from the shared queue, and the desktop shows the picture. **The exit gate is running**: left on for the day on the laptop, then for the weekend on Plex. It is counted from the agent's `consumer=wallpaper` lines, per display by `display=` — sixty an hour per display while the interval was sixty seconds, and two an hour since it went back to thirty minutes on 2026-09-13.

- `Sources/PhotoGoRoundDisplay/Wallpaper.swift` — `WallpaperDisplay`; `WallpaperHome`, the domain and directory per deployment; `Wallpaper`, the loop, driven by closures and `@Observable` so the checkbox can bind to it; and an AppKit extension holding `Wallpaper.desktop()`, `fitOptions()`, the `NSWorkspace` calls and `watchTheSystem()`.
- `Tests/PhotoGoRoundDisplayTests/WallpaperTests.swift` — 22 tests.
- `app/mac/Sources/AppDelegate.swift` starts it after launch; `PhotoGoRoundApp` hands it to the Settings window; `SourcesSettingsView` has the checkbox under its two panels.
- `Sources/photogoroundd/Service/PictureEndpoint.swift` — `display=`, with two tests in `RequestLogTests` and the sentence in `Documentation/photogoroundd.md`.
- `Sources/PhotoGoRoundDisplay/Shuffle.swift` — `trouble(from:)` is no longer `private`.
- `Sources/PhotoGoRoundAgentAPI/Host/HostEnvironment.swift` — `Deployment.identifier` is public, so the wallpaper's domains are spelled from it rather than from a second copy.
- `Scripts/wallpaper-probe.swift` — kept, as the saver's spike was.

**Choices made while building, all Claude's and all open to Syd:** the checkbox is off until ticked; `intervalSeconds` is clamped to between ten seconds and seven days; the loop looks again at least every thirty seconds.

**The draft written before this plan was rewritten, not kept.** Three things in it went: a hardcoded black fill, which the System Settings colour replaced; changing every display at start with one change time held in memory, which the stored per-display times replaced; and writing into the agent's container through `MacHostEnvironment.wallpaperRoot`, with a `HostTests` test defending it, which "the app should not need to see the agent's container" removed. `wallpaperRoot` and that test are gone.

**The Xcode project file changed during the first app build, and nothing here edited it.** `app/Photo-Go-Round.xcodeproj/project.pbxproj` was modified at 21:15:45, while `xcodebuild` was building the app and the saver: the `pgr_ctl` target's exception keeping `Sources/pgr_ctl/Info.plist` out of the target was removed, and a group's comment renamed. That exception matters, since `pgr_ctl` embeds that plist through the linker. Not reverted; Syd's to decide.

**Phase 2's first extension probe, built 2026-09-14.** Not part of anything that ships; *The extension probe* holds what it found.

- `Scripts/make-wallpaper-extension-probe.sh` — builds and signs the probe, and installs nothing. *Since 2026-09-15 it also installs and registers it, unless `--build-only`.*
- `Scripts/wallpaper-extension-probe/Host.swift` — the host app.
- `Scripts/wallpaper-extension-probe/Extension.swift` — the extension.

**Phase 2's second extension probe, built 2026-09-14,** in the same place; *The second probe* holds what it found.

- `Scripts/wallpaper-extension-probe/PaneHandler.swift` — the protocol and the answers.
- `Scripts/wallpaper-extension-probe/PaneModels.swift` — the section.
- `Scripts/wallpaper-extension-probe/ProbePicture.swift` — the picture.
- `Scripts/wallpaper-extension-probe/Extension.swift` and `Scripts/make-wallpaper-extension-probe.sh` — grown from the first probe.

**Phase 2's third extension probe, built 2026-09-14 and run 2026-09-15 at 0.3.2,** in the same place; *What the third probe found* holds the results.

- `Scripts/wallpaper-extension-probe/PaneHandler.swift` and `ProbePicture.swift` — the snapshot, and surfaces held by display.
- `Scripts/make-wallpaper-extension-probe.sh` — installs and registers, and signs with Syd's identity by default.
- `Documentation/Wallpaper Extension Probe.md` — the steps Syd follows after the script.

**Phase 2's fourth extension probe, built and run 2026-09-15 at 0.4,** in the same place; *What the fourth probe found* holds the results.

- `Scripts/wallpaper-extension-probe/AgentPicture.swift` — the port reads, the request and the decode.
- `Scripts/wallpaper-extension-probe/PaneHandler.swift` — the photograph swapped onto the desktop's surface, and the snapshot drawn from what is shown.
- `Scripts/make-wallpaper-extension-probe.sh` — the network entitlement and the two read-only exceptions.
- `Documentation/Wallpaper Extension Probe.md` — the 0.4 steps.

## What this leaves stale elsewhere

Named here first, then brought into line on 2026-09-10 at Syd's request — "please update all other planning documents to reflect decisions made in Wallpaper Plan.md" — as dated corrections marked beside the original text, not rewrites of it. `PLAN.md`, `Screensaver Plan.md`, `TODO.md` and `app/mac/FEATURES.md` were changed. **Code is not a planning document:** `Sources/pgr_ctl/ServiceCommand.swift` still describes `SMAppService`, and is left for when the installation route is built.

- **`PLAN.md` Phase 7** says "scheduled by the server". The app runs it now, and later its own binary.
- **`PLAN.md`, *Wallpaper mechanics and their limits***, says "the practical mitigation is for the agent to re-apply", and *Wallpaper is asserted continuously* lists "agent launch" among the events. Both mean whatever runs the wallpaper, not the agent.
- **`PLAN.md`, *Alternatives considered and rejected*,** says "The agent is what makes the wallpaper schedule real." Only in the sense that it serves the pictures.
- **`Sources/pgr_ctl/ServiceCommand.swift`** and **`app/mac/FEATURES.md`, *The app brings its own agent***, describe `SMAppService.agent` with the plist inside the bundle — "no writing into `~/Library/LaunchAgents`". That is the opposite of the per-user plist Syd specified on 2026-09-10.
- **TODO.md, *Design the wallpaper***, lists "Who owns the loop" as open. It is answered. Its "Decided, 2026-09-09" entry puts the files in `<container>/wallpapers/` and says `HostEnvironment` should give the path out; both are reversed by "the app should not need to see the agent's container."
- **TODO.md, *Sandboxing, and whether the App Store is reachable***, does not mention the wallpaper. *2026-09-14: Syd's "reverse-engineering the wallpaper extension API will mean we can't sandbox this" — corrected to "you are right about the App Store; that is what I meant" — belongs there too, as does "We will continue to support both until I decide on trying to sandbox or not."; see* Getting into System Settings › Wallpaper. Sandboxing it would move its files out of `Application Support` and into a real container — Syd: "we will probably have to move it if we want to sandbox."
- **TODO.md, *A wallpaper bundle, so the wallpaper runs without the app***, written earlier on 2026-09-14, does not know that the bundle is meant for the Wallpaper pane, that the probe comes first, or that the saver's script is the model Syd expects. Not changed; Syd asked for this file only.

## Not yet decided

- **Selecting a background colour as an option.** Syd: "We may add selecting background color as an option later." It joins the other options held for later.
- **Reasserting against macOS reverting on its own**, and the heuristic for not fighting the user. `PLAN.md`, *Wallpaper is asserted continuously*.
- **What the *Also set wallpapers* checkbox defaults to** — off, as "Also" suggests, or on. *Built off until this is decided.*
- **What System Settings › Wallpaper needs from us.** TODO.md, *What System Settings › Wallpaper needs from us*; answered before Phase 1 is built. *Phase 1 was built with it still open.*
- **The set of interval choices.** Syd: "Eventually we will have a set of choices." They would write `intervalSeconds`.
- **The bounds on `intervalSeconds`, and the thirty-second recheck** — Claude's picks while building.
- **A pause control beyond the checkbox**, and where it would live — the app, the shipping menu-bar app (TODO.md, *A menu-bar app for shipping*), or the Phase 2 binary.
- **Whether reapplying on a Space change is wanted at all**, given it overrides a picture the user chose on that Space.
- **Everything about Phase 2**: bundle or bare executable, menu-bar presence, and how the app installs and removes the plist. *2026-09-14, now also:*
  - *Answered 2026-09-14: a Photo-Go-Round section can be chosen in the pane and draw; see* What the second probe found. *Open from it:* ~~what `snapshot` must return, and whether the lock screen shows the picture~~ — *answered 2026-09-15: an `IOSurface` in `WallpaperSnapshotXPC`, and it does; see* What the third probe found; ~~pictures from the agent~~ — *answered 2026-09-15; see* What the fourth probe found; *open from it:* which temporary exception each port read needs on its own, and refreshing the snapshot when the picture changes; Spaces, several displays, and sleep and wake; ~~the macOS 27 replacement for the deprecated `enqueue`~~ — *run 2026-09-15, and it draws*; why answering a snapshot brings a reconnect; and whether the section also appears in the Screen Saver picker;
  - the first probe's ad-hoc run, which has not been made;
  - what `com.apple.wallpaper.development` is for — searched and not found, and probably moot since Phosphene;
  - ~~how a sandboxed extension reaches the agent: permission to connect, and finding the port from inside the sandbox~~ — *answered 2026-09-15: `network.client` and read-only exceptions for the domain and its plist; see* What the fourth probe found;
  - how the app hands the extension its settings — Phosphene's app writes into the extension's container;
  - whether a still can be shown as one frame through an extension that draws its own;
  - whether to take route A, if it cannot — C is ruled out for the system wallpaper;
  - a LaunchAgent bundle for the app-style wallpaper — not wanted if the system wallpaper route can be figured out, and open again only if it cannot;
  - the App Store — whether to try for it, which is Syd's, and which decides how long both wallpapers stay;
  - where the pane's wallpaper keeps its state;
  - where the bundle lives, given "the binary stays in the app bundle";
  - whether `make-wallpaper-bundle.sh --install` runs `launchctl` or prints the commands;
  - how the app and the bundle hand the loop over, and how the checkbox reaches a separate process;
  - Phase 2's exit gate.
- **Separate pools of sources for the wallpaper and the screensaver.** `PLAN.md`, *TODO: separate pools of sources*, and Syd's "in addition to sources later".

# References

- `PLAN.md` — Phase 7; *One display mode in v1*; *Every surface has a defined empty state*; *Wallpaper mechanics and their limits*; *Wallpaper is asserted continuously, never set once*; *Consequences of one shared queue*; *The empty state*; *Beyond 0.1* (*Display styles*, *Timing and transitions*, *TODO: separate pools of sources*).
- `TODO.md` — *Design the wallpaper*; *Sandboxing, and whether the App Store is reachable*; *Installing by launching the app*; *A menu-bar app for shipping*; *What System Settings › Wallpaper needs from us*.
- `Scripts/wallpaper-probe.swift` — the Phase 1 probe: `show`, `fill`, `redraw`, `restore`.
- `Sources/PhotoGoRoundDisplay/Wallpaper.swift`, `Tests/PhotoGoRoundDisplayTests/WallpaperTests.swift`, `app/mac/Sources/AppDelegate.swift` — Phase 1 as built.
- `Screensaver Plan.md` — the surface this one follows, and *Moving Shuffle and PictureLayerView* for why shared code goes in the display library.
- `app/mac/FEATURES.md` — *The app brings its own agent*.
- `Sources/PhotoGoRoundDisplay/` — `PictureClient.swift`, `PictureLayerView.swift` (`identifier(of:)`), `Shuffle.swift`, `AspectFit.swift`.
- `Sources/PhotoGoRoundAgentAPI/` — `Host/HostEnvironment.swift`, `Model/Consumer.swift` (`ConsumerKind.wallpaper`), `Support/Log.swift` (`Log.wallpaper`).
- `Sources/pgr_ctl/ServiceCommand.swift` and `Scripts/make-agent-bundle.sh` — the two agent-installation routes as they stand.
- Apple: `NSWorkspace.setDesktopImageURL(_:for:options:)`, `desktopImageURL(for:)`, `NSWorkspace.DesktopImageOptionKey`; `launchd.plist(5)` (`LimitLoadToSessionType`); `SMAppService`.
- `/System/Library/ExtensionKit/ExtensionPoints/com.apple.wallpaper.appexpt` and `/System/Library/ExtensionKit/Extensions/Wallpaper*.appex` — the extension point and Apple's extensions, read 2026-09-14; `pluginkit -m -v -p com.apple.wallpaper`, `codesign -d --entitlements`, `otool -L`.
- `/System/Library/CoreServices/WallpaperAgent.app` — the host, read 2026-09-14: its entitlements, its links, its `Info.plist` and its strings. `/System/Library/ExtensionKit/Extensions/Wallpaper.appex` and `WallpaperSettingsIntents.appex` — the Settings side.
- `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e*` — searched for `com.apple.wallpaper.development`, 2026-09-14; `lsregister -dump`.
- Phosphene — https://github.com/kageroumado/phosphene, read 2026-09-14: `PhospheneExtension/Info.plist`, `Phosphene/Phosphene.entitlements`, `Phosphene.xcodeproj/project.pbxproj`, `PhospheneExtension/PhospheneExtension.swift`, `PhospheneExtension/WallpaperExtensionConfig.swift`, `README.md`. Project page: https://kagerou.glass/phosphene/
- *Show HN: I reverse engineered Apple's video wallpapers* — https://news.ycombinator.com/item?id=48215979
- kageroumado, *How to Reverse Engineer Apple Frameworks* — https://kagerou.glass/blog/how-to-reverse-engineer-apple-frameworks/
- Howard Oakley, *An overview of app extensions and plugins in macOS Sequoia*, The Eclectic Light Company, 2025-04-23 — https://eclecticlight.co/2025/04/23/an-overview-of-app-extensions-and-plugins-in-macos-sequoia/
- Bart Reardon, *Adding Wallpaper folders to macOS System Settings* (WallpaperFolderManager), 2025-12-04 — https://bartreardon.github.io/2025/12/04/adding-wallpaper-folders-to-macos-system-settings.html
- `Scripts/make-saver-bundle.sh` — what Phase 2's script follows. `Scripts/make-agent-bundle.sh` — `--install-to`, and printing the `launchctl` commands rather than running them.
- `Package.swift` — the `.macOS("27.0")` line; `.macOS("26.0")` until 2026-09-14.
- `Scripts/make-wallpaper-extension-probe.sh` and `Scripts/wallpaper-extension-probe/` — the first extension probe. `~/Library/Logs/DiagnosticReports/WallpaperProbeExtension-2026-09-14-204957.ips` — its first run's crash report.
- `Scripts/wallpaper-extension-probe/PaneHandler.swift`, `PaneModels.swift`, `ProbePicture.swift` — the second extension probe.
- `Documentation/Wallpaper Extension Probe.md` — the steps for running the probe, 2026-09-15.
- `/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework` — `WallpaperSnapshotXPC`'s `encodeWithCoder:` and `initWithCoder:`, disassembled 2026-09-15 for *What the third probe found*, from a harness that loaded the framework; and the same harness sending a snapshot through an anonymous `NSXPCListener`. Both harnesses were built under `~/.claude/build/photo-go-round/`, not kept in the repository.
- Read for *The fourth probe*: `Screensaver Plan.md`, Phase 1 and *The question the entitlements do not answer: finding the port*; `Sources/PhotoGoRoundDisplay/ServicePort.swift` and `PictureClient.swift`; `Sources/photogoroundd/Service/PictureEndpoint.swift`; `Sources/PhotoGoRoundAgentAPI/Model/Consumer.swift`; and the entitlements of `/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex`, 2026-09-15.
- Phosphene, read for *The third probe*: `PhospheneExtension/SnapshotCreation.swift`, `createSnapshotXPC` in `RuntimeHelpers.swift`, `BMPCache.swift`, the `invalidateSnapshots` calls in `WallpaperXPCHandler.swift`, and the README's *Quirks worth knowing*.
- Phosphene, read for *The second probe*: `PhospheneExtension/WallpaperExtension-Bridging-Header.h`, `WallpaperXPCHandler.swift`, `CodableShims.swift`, `SettingsProvider.swift`, `RuntimeHelpers.swift`, `StillFrame.swift`, `SnapshotCreation.swift`.
- Xcode's `DarwinProductTypes.xcspec`, in Swift Build's `SWBApplePlatform` plugin — the `app-extension` and `extensionkit-extension` product types.
