# Summary

A `.saver` bundle that shows one photograph at a time, sized to fit, on black — the Mac app's window with the chrome taken off and nothing added. No pan, no cross-fade, no configuration sheet. Subordinate to `PLAN.md`, which places this in Phase 6.

# Rationale

This project exists because Apple's screensaver has the display half solved and the library half broken, so the saver is the surface the original complaint was actually about; everything built so far has been rehearsal for it. The phase carried one unanswered question from the day the plan was written — whether a saver inside `legacyScreenSaver`'s sandbox can talk to the agent at all — and it was the largest technical risk in `PLAN.md`; Phase 1 answered it on 2026-09-07, and found a second question underneath it that nobody had asked. No amount of motion design is worth anything until a photograph arrives on the glass, and a pan tuned inside a host process with no debugger attached is the most expensive way to tune one. So v1 is the smallest thing that answers the question and puts a picture up, and the motion is a separate argument held for later.

# Phases

- **Phase 1 — complete, 2026-09-07. The spike.** A stub `.saver` that draws nothing and logs everything, one file in `app/saver/` assembled by `Scripts/make-saver-bundle.sh`, installed and run for real. **Both questions are answered and they came apart**: reaching the agent works, finding it through `UserDefaults` does not.
  - Bundle mechanics held on the first build. `@objc(PGRScreenSaverView)` emitted `_OBJC_CLASS_$_PGRScreenSaverView` unmangled, `NSPrincipalClass` matched it, the linker produced a Mach-O bundle rather than a dylib, and an ad-hoc signature was enough. None of `PLAN.md`'s three silent-failure traps fired.
  - **Q1 — reaching the agent: passes, both spellings.** `127.0.0.1` answered `200, 126149 bytes, card 29992, 165 ms`; `localhost` answered `200, 510667 bytes, card 37365, 93 ms`. Different cards per request, so the queue pops correctly through the sandbox. **`PictureClient` needs no change** — the mDNSResponder worry was worth testing and is dead.
  - **Q2 — finding the port: fails silently through `cfprefsd`, works through the file.** `UserDefaults(suiteName:)` returned a suite that opened cleanly and held nothing; the plist read directly gave 823 bytes and `servicePort = 9000`. See *The question the entitlements do not answer*.
  - The sandbox is confirmed rather than assumed: `NSHomeDirectory()` is `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data`, while `getpwuid` still reports `/Users/jazzman` — which is what makes the file fallback addressable at all.
  - **`startAnimation()` fired twice inside one host process**, 32 seconds apart under two activity ids. Carried into Phase 3; see *The host outlives the session*.
  - **No `isPreview: true` instance ever appeared**, through selecting the saver and browsing the pane. Carried into Phase 4, and suggestive rather than proven.
  - **Exit gate: a stub inside `legacyScreenSaver` reports a 200 and a byte count from the running agent.** Met. *One correction to the gate as written: `ScreenSaverEngine` runs the saver that is selected, so the bundle has to be chosen in System Settings before the engine will load it at all. The first run produced an empty log for that reason and nothing else.*
- **Phase 2 — complete, 2026-09-08. The display code moves.** `Shuffle` and `PictureLayerView` are in `PhotoGoRoundDisplay`, so the saver will link the same code the window runs rather than a second copy of it. The Xcode project needed no edit: it uses synchronized root groups, so taking files out of `app/mac/Sources` is the whole of it.
  - `consumer` is a parameter. It was hardcoded `"app"`, and the deck keys a consumer's history on the string, so two surfaces sharing it would leave neither readable.
  - The deployment is a parameter, still defaulting to `.development`.
  - `app/tests/ShuffleTests.swift` moved to `Tests/PhotoGoRoundDisplayTests`, where `swift test` reaches it and Xcode is not required to run the rule it defends.
  - **Port discovery is `ServicePort`:** the suite first, the plist underneath, falling through on *empty* rather than on failure because empty is what the refusal looks like. Three answers rather than two — `published`, `none`, `unreadable` — and it handles both domain spellings, dotted under the real home and path-named beside itself. Nine tests.
  - **`PictureClient.Failure.portUnreadable`** carries *a port may be published and this process cannot see it*. It maps to `Trouble.noAgent` with a precise reason, so the log line is right and the words on the glass do not change; a `Trouble` case of its own would change what the window says. See *Not yet decided*.
  - **`Preferences.domain` is public now.** The lookup has to name the same domain to find its file, and spelling it a second time is how two copies drift apart.
  - **Log lines carry the consumer** — `app: no photos`, not `shuffle: no photos` — because two surfaces on one subsystem are otherwise indistinguishable.
  - **Divergence from this plan, and it is a simplification.** The plan said AppKit would go behind `#if canImport(AppKit)`. AppKit came out of `Shuffle` altogether instead: `draws(at:on:)` takes a `String?` display identifier, and `CGDisplayCreateUUIDFromDisplayID` moved to `PictureLayerView.identifier(of:)`, which is the only code holding a screen anyway. One conditional file rather than two, and `Shuffle` compiles cross-platform outright — which is what Phases 4 and 5 of `PLAN.md` will want.
  - **Exit gate: `swift test` passes and the app looks and behaves exactly as it did.** Met. 731 tests across four targets; the app and its test bundle build; the window run and confirmed unchanged.
- **Phase 3 — complete, 2026-09-09.** The saver shows photographs: a `ScreenSaverView` hosting a `PictureLayerView`, driven by `Shuffle`, at ten seconds a picture. Everything is an Xcode target now — see *Xcode builds, scripts deploy*.
  - `animateOneFrame()` is never implemented; the loop is a `Task`, not a frame callback.
  - **The loop belongs to the display, not to the view** — `DisplayShuffles`. This is the phase's one real correction and it cost two runs to find: macOS does **not** make one view per display, it makes several, and each one starting its own loop drew twice the screen's share out of a shared queue. See *The host outlives the session*.
  - **A view gives its claim back three ways**: `stopAnimation`, losing its window, and `deinit`. The window guard is not belt-and-braces — in the 09:14 run one of the two views never received `stopAnimation` at all and only the window check released it.
  - **The display is resolved live, never cached.** Caching it at first layout keyed one view to `unknown` and its sibling to the real UUID, so the registry did not dedupe them at all. `window != nil` is not the same question as *the window is on a screen*.
  - **And a view that never resolves one adopts the machine's sole identified display**, rather than running a second loop for ever. Live resolution fixes a window that lands on a screen *later*; it does nothing for one that never reports a screen at all, which happened again at 09:42 and cost two more cards a dwell.
  - A picture already showing is never taken down, and now survives a stop and start — `Shuffle.stop()` cancels the loop and keeps `shown`, so a joining view inherits the photograph in the same millisecond rather than after a request.
  - The preview never serves, and says so in the log. That is the guard, not Phase 4's thumbnail.
  - **Confirmed 09:53 on 2026-09-08**: one `new loop`, one `joined the loop … now 2 views`, both views reporting the same card and deal, no `unknown` loop, and a refcounted teardown that used both release paths — the window guard for one view, `stopAnimation` for the other.
  - **Exit gate: it is the screensaver on the machine for an evening, and it is still showing photographs in the morning.** Met, overnight 2026-09-08 into 2026-09-09. **3,034 photographs, 00:05:38 to 08:59:52, zero non-200 responses** — and 341 an hour in every one of the eight full hours, without drifting by a count. One photograph every 10.56 seconds is a ten-second dwell plus the round trip; two loops on that display would have shown about 682 an hour. The flat number is the proof, not the total.
  - **It had to be counted from the agent's side, and that is a finding of its own.** The saver's per-photograph line is `.info`, which is memory-only, so it had evaporated by morning; the run was countable only because the agent's `served status=… consumer=screensaver` line is `.notice`. `Log.swift` states the rule — "state transitions worth reconstructing after the fact must be `.notice` or higher" — and the number that mattered was on the wrong side of it. See `TODO.md`, *Metrics in the database*.
- **Phase 4 — complete, 2026-09-09.** The bouncing treatment `PLAN.md` has described from the beginning, in `EmptyStateView` and `BouncePath`.
  - **Built once, in the display library, and mounted by the window and the saver alike** — which settles the standoff where `FEATURES.md` said the app would build it "so Phase 6 inherits it" while `Shuffle.swift` called it "Phase 6's treatment", and neither did.
  - Two lines: the words, and underneath them what to do. An empty library says *Use the Settings panel in the application to add images.*, because nothing is broken — nobody has added any.
  - **A missing agent and a wedged one are one message on screen**, at Syd's direction: to the user they are the same predicament. `Trouble.line` keeps them apart for the log.
  - One `CAKeyframeAnimation` over a path that closes on itself, so it repeats for ever with no seam and nothing to reschedule. Constant speed, pure reflection, an angle drawn away from both axes, and stillness when there is less than 24 points to travel through.
  - **Preview left this phase and came back as something else.** It is live and costs a card per dwell; what is left is a decision to record rather than code to write. See *The preview is live, and it is an ordinary instance*.
  - **Exit gate: an agent that is stopped produces words rather than a black rectangle, and they are not sitting still.** Met. The words appear and move, confirmed in all three surfaces — the window, the screensaver, and the settings preview. *Closed on the no-photos state; the agent-stopped wording had not been looked at on screen when this was marked, and it is a placeholder in the window regardless until the Install and Launch buttons exist. See `TODO.md`, `Installing by launching the app`.*
  - **Two things went to `TODO.md` rather than holding the phase open**: the words are illegible at the settings preview's scale, and there is nothing on screen at all for the first ten seconds of an empty library.

# Design Decisions

- **No pan and no cross-fade in v1.** Syd's call, 2026-09-07: just photo display, doing what the app window does, as a proof of concept. `Pan` stays where it is with no callers, and gets them when the motion phase is argued on its own.
- **HTTP, and the same `PictureClient` the app uses.** The saver opens neither the database nor the cache, exactly as *The database is private to the service* requires of every client.
- **The four-rung ladder in `PLAN.md` is resolved by reading entitlements, and confirmed by running code on 2026-09-07.** The host grants `network.client`, disables library validation, and permits read-only access to `/`. Options 1, 2, and 4 are unnecessary and XPC is impossible — see *What the host's entitlements settle*.
- **The spike pinned the port with `--port` rather than discovering it, and that is what made it readable.** Connectivity and discovery are separate failures with separate fixes; they did in fact come apart, and a spike that had conflated them would have reported one flat failure with two possible causes.
- **Discovery reads the plist as a file, because the suite comes back empty rather than refusing. Measured, not predicted.** `UserDefaults(suiteName:)` hands a sandboxed process a domain that opens cleanly and holds nothing, so the failure is indistinguishable from *the agent published no port*; an ordinary `open(2)` on the same `.plist` returns the right value, which the whole-filesystem read exception permits.
- **Xcode builds, scripts deploy. Decided 2026-09-08, reversing the entry below it.** Every product is an Xcode target — app, tests, saver, saver spike, agent, `pgr_ctl` — because a target is a thing that can be debugged in Xcode when it needs to be. The package and `swift test` stay exactly as they were, and the scripts stay for deployment, which is the half Xcode knows nothing about: `~/Library/Screen Savers`, the two caches that must be cleared, the LaunchAgent plist. See *Two build systems over one set of sources*.
- **The empty-state label wanders once per dwell. Decided 2026-09-08.** Kept despite motion being deferred, because a static label overnight is the burn-in hazard `PLAN.md`'s *The empty state* exists to avoid. It is a placeholder for the bouncing treatment and is not it.
- **The settings preview is live, and it consumes the queue. Measured 2026-09-09, correcting the day before.** The `isPreview: true` instance is an inert 0x0 probe, but the pane's actual preview is an ordinary `isPreview: false` view in another host process, which starts and serves like any other surface. So *Preview mode must not consume the queue* is not met and cannot be met by that guard — see *The preview is live, and it is an ordinary instance*. The guard stays because a probe should not serve either; it is simply not what was protecting anything.
- **The picture loop is keyed to the display, not to the view.** macOS makes more views than there are screens; the consumer is the display, which is what the deck's `(kind, displayID)` identity already assumes. Views borrow the loop and give it back.
- **A display's identity reaches the loop as a string, not an `NSScreen`.** The view is the only thing holding a screen, so it is the thing that turns one into an identifier — which leaves `Shuffle` free of AppKit and compiling wherever the library does.
- **The saver ships no motion but keeps the layer.** `PictureLayerView` is already layer-backed with a computed frame, which is what the pan will need — reverting it to a drawn image would be work done twice.
- **`os_log`, prefixed `saver:`, and the logging stays in.** It is the only channel out of the host's sandbox, and it is how every question about this phase gets answered. Same convention as the panel's `panel:`.
- **Development deployment first.** The saver talks to the same `com.sydpolk.photogoround.dev` domain the app does, so one agent serves the window and the saver during development and neither can be confused about which library it is on.
- **Swift, with an `@objc` principal class.** No Objective-C anywhere, and the three configuration traps that make a Swift `.saver` silently not appear are named in `PLAN.md`'s *Swift everywhere, including the screensaver*.
- **Ad-hoc signing is enough to develop against. Confirmed 2026-09-07.** The host sets `com.apple.security.cs.disable-library-validation`, and it loaded a bundle this project signed itself.

# Background

`PLAN.md` puts the screensaver at Phase 6 and opens it with a spike, because *The screensaver sandbox problem* is named there as the largest technical risk in the plan. Phase 1.5 shrank that risk considerably: since the agent became the interface, the saver needs no file access to the container and no write access to the deck, so the spike went from "can it read the cache and write the deck" to "can it make an HTTP request."

What exists to build on: `PhotoGoRoundDisplay` was carved out precisely so this phase would link the same fit and the same pan as the window rather than reimplementing them. It holds `AspectFit`, `Pan`, `PictureClient`, `PictureSource`, and `ServedPicture`, all tested. `Shuffle` and `PictureLayerView` — the loop that asks for a picture and the layer that draws it — are still in `app/mac/Sources`, where the saver cannot reach them.

What `PLAN.md` assumed would be built by now and is not: it makes the Phase 3 full-screen window "the screensaver's rehearsal space", where the pan, the cross-fade, and the bouncing empty state are all tuned before Phase 6 has to make them work inside someone else's sandbox. None of the three landed. `Pan` has no callers at all. That was going to be this plan's opening question; the answer above — v1 is photo display only — dissolves it rather than settling it, and the motion work stays unbuilt in both places until it is argued on its own terms.

The Xcode project at `app/Photo-Go-Round.xcodeproj` has exactly two targets today, the app and its unit-test bundle. There is still no `.saver` target: Phase 1's stub is a single file at `app/saver/Sources/PGRScreenSaverView.swift` assembled by `Scripts/make-saver-bundle.sh` with `swiftc`, deliberately outside the project so that a spike linking nothing could not fail for a reason it had brought with it. A screensaver Syd built from Xcode's template about two years ago was deleted on sight of its `.m` files, so there is no prior observation of what a saver can reach on this machine.

# Detailed discussions

## What the host's entitlements settle

`PLAN.md`'s *The screensaver sandbox problem* lists four options in order of preference and says the spike tries each in turn and "determines the shape of Phase 5" — a day's work whose outcome the whole phase hangs on. Most of that is answerable without writing anything, because the host's entitlements are readable on disk:

```
codesign -d --entitlements - --xml \
  /System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex
```

The grant, on macOS 27.0, and identical on the `-x86_64` variant beside it:

| Entitlement | Value | What it settles |
| --- | --- | --- |
| `com.apple.security.app-sandbox` | true | Confirms the premise: our code inherits a sandbox. |
| `com.apple.security.network.client` | **true** | **Outbound TCP is permitted, so localhost HTTP is permitted.** This is the whole spike's headline question. |
| `com.apple.security.cs.disable-library-validation` | true | The host will load a bundle we signed ourselves. |
| `com.apple.security.temporary-exception.files.absolute-path.read-only` | `["/"]` | **The entire filesystem is readable.** |
| `com.apple.security.temporary-exception.mach-lookup.global-name` | four Apple names | **XPC to our agent is impossible.** |
| `com.apple.security.assets.pictures.read-only` | true | `~/Pictures` is readable, which nothing here needs. |

Five consequences, in descending order of how much they change the plan:

**Option 3 — localhost HTTP — is granted, and it was ranked third.** `PLAN.md` calls it "unverified" and puts it below two options that turn out to be unnecessary. It is the one the architecture already wants, since Phase 1.5 made every client an HTTP client, and the entitlement says the sandbox will not be what stops it.

**Option 1 — writing the store into the host's container — is unnecessary, and the reason is better than expected.** The plan proposed relocating the database and cache into `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/…` so the saver could open them as ordinary local storage, and called the container path "an Apple implementation detail that could change under us." It never needed the trick: with `/` readable, the saver can already open the container where the store actually lives — `.build/pgr-container` in development, `~/Library/Containers/com.sydpolk.photogoround` in production. What it cannot do is *write* — SQLite needs to create `-wal` and `-shm` beside the file and take locks on them — which is precisely why a read-only grant is not a substitute for the service and why HTTP is the right answer anyway.

**Option 4 — Unix domain sockets — is dead for the reason the plan gave.** It needs a writable path the sandbox permits, and the write side is exactly what is missing.

**XPC is impossible, not merely risky.** `PLAN.md` says XPC is "architecturally the cleanest of the lot" and is tested only if option 1 fails, with the caveat that the sandbox "may simply deny `mach-lookup` for names it does not recognize." It does. The exception list names `com.apple.CARenderServer`, `com.apple.CoreDisplay.master`, `com.apple.nsurlstorage-cache`, and `com.apple.ViewBridgeAuxiliary`, and nothing else. A global Mach service published by our agent is not reachable from inside that profile at any price. This can be struck from the plan rather than deferred.

**The consumption-journal fallback would have worked, and is not needed.** The saver can write inside its own container, which an unsandboxed agent can read — so "the saver appends what it showed to a file and the agent applies the removals" was a viable last resort. It is moot.

**What entitlements did not prove, and what running it settled.** They describe the container the host was signed into, not the effective profile at runtime, which can be narrowed further by a `.sb` profile or by platform policy — so this was a strong prior rather than an observation, and the stub was built and run anyway, because *a phase ends when you have used it, not when it compiles*.

**Confirmed on 2026-09-07.** A stub inside `legacyScreenSaver` reported `sandboxed: true` with `NSHomeDirectory()` pointing at the host's container, then completed `GET /v1/next` twice — `127.0.0.1` in 165 ms and `localhost` in 93 ms, both `200`, each with a different card. The runtime profile is no narrower than the grant on the point that mattered. Two things the entitlements could not have told us came out of the same run and are written up below: the preference read fails in a way that looks like success, and the host process outlives an individual screensaver session.

## The question the entitlements do not answer: finding the port

The agent binds an ephemeral port and publishes it by writing `servicePort` into a preference domain — `com.sydpolk.photogoround.dev` in development, `com.sydpolk.photogoround` in production. `PictureClient` reads it fresh on every request, deliberately, so a restarted agent on a new port is picked up rather than being failed against forever.

That read is the part of the design the sandbox was most likely to break, and it was invisible in the entitlement list because it is an *absence*: there is no `com.apple.security.temporary-exception.shared-preference.read-only` naming our domain. A sandboxed process reaches `UserDefaults` through `cfprefsd` over Mach, and the sandbox arbitrates per-domain.

**Measured 2026-09-07, and the answer is worse than a refusal.**

```
cfprefs: opened the suite, no servicePort in it
plist:   /Users/jazzman/Library/Preferences/com.sydpolk.photogoround.dev.plist
plist:   read 823 bytes
plist:   servicePort = 9000
```

`UserDefaults(suiteName:)` does not return `nil` and does not throw. It hands back **a suite that opens cleanly and is empty** — so the sandbox's denial arrives disguised as an ordinary, healthy answer. A saver written exactly the way the app is written would read no port, raise `.noPortPublished`, and report *the agent is not running* while the agent answers `200` on the next line of the same log. That is the worst available diagnostic in the one process with no debugger attached, and it is the reason this is called out here rather than left as an implementation detail of Phase 2.

Two consequences follow, both now scheduled rather than speculative:

- **The lookup tries the file when the suite is empty.** Not "when the suite fails", because it does not fail.
- **`PictureClient.Failure` gains a case** distinguishing *nothing published a port* from *a port is published and this process cannot see it*. The first is fixed by starting the agent; the second is fixed by nothing the user can do, and reporting one as the other sends somebody to the wrong place — the same argument that already separates `unreachable` from `silent`.

Fallback 1 is therefore the mechanism rather than a fallback. The remaining two stay written down because the first has a caveat that has not been exercised:

1. **Read the plist as a file — confirmed.** `~/Library/Preferences/com.sydpolk.photogoround.dev.plist`, parsed with `PropertyListSerialization`, from a path built on `getpwuid` rather than `NSHomeDirectory()`. **The untested part is freshness:** `cfprefsd` buffers writes, so a port published seconds ago may not be in the file yet. The spike read a port written some time earlier and proves nothing about the race. Either the agent synchronizes after `publishServicePort`, or the saver tolerates a stale value and retries — and a stale port is not a hypothetical, because the agent takes a new one every launch.
2. **Pin the port.** A fixed port in preferences that the agent binds when set. This is what `--port` already does for `curl` and what the spike used; making it the saver's supported configuration is honest but pushes a number into the user's lap, which for a shipping product is wrong.
3. **Publish to a second location the saver can definitely read.** A small file the agent writes wherever both can reach it. It is a second publishing mechanism to keep in sync with the first, so it is last.

**A fourth that is not a fallback but might be the answer:** if a shipping saver is embedded in the app's bundle rather than installed loose, it can carry an App Group entitlement — and an App Group preference suite is *the saver's own domain*, which needs no exception. That is a distribution question rather than a v1 question, and it is out of scope here, but it is worth knowing the door exists before building around its absence.

## Moving Shuffle and PictureLayerView

`Shuffle` is 290 lines and almost entirely reusable as written. It is the loop — ask, decode off the main thread, hold what is shown, report trouble beside it rather than instead of it — and every rule it enforces is a rule the saver needs more than the window does. Two things are hardcoded to the app and become parameters:

- `consumer: "app"`, passed on every request. The saver is `"screensaver"`, and `PLAN.md`'s consumer table already lists both.
- `MacHostEnvironment(deployment: .development)` in the convenience initializer. The saver needs the same today and a different one when the app ships, so the deployment moves out to the caller.

`PictureLayerView` is 100 lines of AppKit and needs no changes at all. It already computes the picture's frame with `AspectFit` rather than delegating to `contentsGravity`, with a comment saying why: the pan needs the letterbox as a number and a gravity keeps that to itself. That decision was made for a phase that is not being built yet and it costs nothing to keep.

`PictureDisplay`, the `NSViewRepresentable` at the bottom of the same file, is SwiftUI's wrapper and the saver has no use for it — a `ScreenSaverView` is an `NSView` and hosts `PictureLayerView` directly. It can move with the rest or stay in the app; I would move it, so that everything about drawing a photograph lives in one place and the app holds only its window.

**The one real complication is iOS.** `PhotoGoRoundDisplay` declares `.iOS("27.0")` and compiles for it today, because everything in it is Foundation and CoreGraphics. Moving AppKit into it means `#if canImport(AppKit)` around `PictureLayerView` and around `Shuffle`'s `NSScreen` parameter, or splitting the display-side types out into a macOS-only target. Conditional compilation is the smaller change and the one I would make; a second target is worth it only when there is a real iOS surface to build, which `PLAN.md` defers past 1.0.

**`Shuffle`'s name is worth a second look once it moves.** In the app it names what the window is doing. In a library shared by three surfaces it names a class that is really "the picture loop", and `Shuffle` is also the word this project uses for the deck's ordering — a different concept entirely, which is now one import away from the first. Not a blocker, and renaming it churns a test file for a word; flagged rather than decided.

## The preview is live, and it is an ordinary instance

`ScreenSaverView` is instantiated a second time with `isPreview: true` for the thumbnail in the Screen Saver pane. `PLAN.md` is emphatic about what must not happen: "if it did, idly browsing screensaver settings would consume pictures nobody ever sees, and with a shared queue those are then spent for the wallpaper too."

It then says the solution is that "preview peeks at the queue without draining it, which the queue supports directly." **That sentence predates *The service is the interface***: the agent exposes one picture route, `GET /v1/next`, and serving pops. The queue still supports a peek; the wire does not expose it.

**Two measurements a day apart, and the first was read wrongly. The error is kept because it is an easy one to make again.**

2026-09-08 found this and stopped looking:

```
saver[2d00]: created, preview=true, 0x0
saver[2d00]: preview laid out at 0x0
```

An `isPreview: true` instance with no area, never drawn and never started. The conclusion drawn was that no live preview was possible and the thumbnail had to be a captured still — which fitted what was on screen, because the pane showed a photograph that did not cycle.

2026-09-09, with the empty state built, the pane was seen animating *and* changing pictures. The log says why:

```
pid 80193  saver[4f00]: created, preview=true, 0x0          ← never started
pid 80125  saver[9500]: created, preview=false, 1800x1169
pid 80125  saver[9500]: startAnimation, window=true, box=true
pid 80125  saver[9500]: joined the loop … now 1 views
pid 80125  saver[9500]: showing card 1 deal 36000
```

**Two processes.** The `isPreview: true` instance is a 0x0 probe — System Settings asking the class questions, `hasConfigureSheet` among them — and it is exactly as inert as the first measurement said. The pane's actual preview is an ordinary `isPreview: false` view in a *different* `legacyScreenSaver` process, created seconds later, which starts, joins the display's loop, and serves cards like any other surface.

**Where the reading went wrong** is worth naming precisely: one instance was observed, it happened to be the one whose flag matched the question being asked, and nothing checked for a second process doing the work. A fact about that instance was taken as a fact about the feature. The tell was in the log the whole time — the pid column was different.

Consequences, in the order they cost anything:

- **`PLAN.md`'s *Preview mode must not consume the queue* is not met, and cannot be met by this mechanism.** Browsing the pane runs a real instance and spends a card per dwell. The `isPreview` guard in the saver protects nothing, because the view doing the work does not carry the flag. There is no clean way to opt out either: the preview view is indistinguishable from a genuine one except by frame size, and guessing from that is the same kind of inference that produced this error.
- **It is nevertheless the outcome Syd wanted.** He said on 2026-09-08 that he would have relaxed that rule for a preview showing his own photographs. The OS relaxed it for us. What remains is a decision to record in `PLAN.md`, not code to write.
- **The four options are moot** — shipped placeholder, static card, `GET /v1/peek`, one card per settings visit. There is nothing to build; the preview already shows the library, live and cycling.
- **The documented workaround for a preview that never starts is still irrelevant**, now for a second reason. `FB9835060` — a `Timer` from `init` calling `startAnimation`, fixed in Ventura — would start the 0x0 probe, which is not the view anybody sees.

**It works, and not well. Syd, 2026-09-09: "I don't think that the preview works all that well, but it is something."** Recorded so that nobody later reads the paragraphs above as a claim that this is finished. Three things are wrong with it and only the first is ours: the empty state's text is illegible at that scale; the photograph is drawn for an 1800-point view and then shrunk into a tile, so it is seen at a fraction of the size it was fetched for; and it spends a card per dwell for as long as the pane is open. None of that is worth work today — it is better than the generic placeholder it replaced, and the alternatives were all worse — but *acceptable* is the claim being made here, not *good*.

**The sizing problem it left behind.** The preview view is 1800x1169 and is then scaled down into a small pane, so the empty state's font, fitted to 1800 points, arrives illegible. The view cannot tell it is being scaled. See `TODO.md`, *The empty state is sized for the view, not for how it is shown*.


## The empty state without motion

With the bouncing letters out of scope, an empty screensaver is words sitting still on black. `PLAN.md`'s *The empty state* argues the motion is not only fun: it "moves, so it cannot burn in on the OLED and XDR panels where a static centered label would be a genuine hazard over hours." A screensaver is the surface where that matters most, because it is the only one that runs unattended all night.

A photograph changing every ten seconds is not a burn-in risk. A "No photos" label that never moves, on a machine whose agent has stopped, is one — and it is exactly the state a first run lands in, and the state a crashed agent leaves behind.

Options that keep motion out of scope:

- **Move the label without animating it.** Reposition it once per dwell — every ten seconds, no interpolation, no `CAKeyframeAnimation`. It is not the bouncing empty state and does not pretend to be; it is three lines that stop the pixels sitting still. This is what I would do.
- **Fade the screen to black after N minutes of empty.** Correct for the panel and terrible as a product: it is indistinguishable from the failure it is reporting.
- **Ship the bouncing empty state after all,** on the grounds that it is a different kind of work from the pan and the cross-fade — it is a text layer on a computed path, not a treatment applied to a photograph. Defensible, and it is a scope increase Syd did not ask for, so it is his to grant.
- **Accept the static label in v1** and note that a proof of concept does not run all night. True, until the exit gate above says it does.

Listed under *Not yet decided*.

## One instance per display

macOS creates a separate `ScreenSaverView` for every attached screen. Each gets its own `Shuffle` and its own `PictureLayerView`, and each asks at its own pixel size and its own display UUID — which `Shuffle.identifier(of:)` already derives via `CGDisplayCreateUUIDFromDisplayID`, chosen because it survives reboots and cable swaps where the transient `CGDirectDisplayID` does not.

The displays then show different photographs for free, because serving pops the queue and no two requests can be answered with the same entry. Nothing has to coordinate.

Two things to watch on a multi-display machine, neither of which is a v1 blocker:

- **The queue drains twice as fast**, or three times, and the fastest consumer sets the pace the producers have to keep. `PLAN.md` says the correct degradation is fewer photographs rather than a stall, so the failure mode should be visibly benign. The evening-long exit gate is where that gets observed.
- **`consumer=` is one string for every display.** The wire distinguishes them by `display=`, which is what the consumer table is keyed on, so this is probably already right — but it is worth confirming against the endpoint rather than assuming, since a shared consumer row with two displays writing to it is the kind of thing that looks fine for an hour. **2026-09-10:** the agent's served line gains `display=`, decided in `Wallpaper Plan.md` and built with its Phase 1, which makes this checkable from the agent's side.

## The host outlives the session

`legacyScreenSaver` is not started and stopped with each screensaver session. In the Phase 1 run, one host process — pid 56721 — served two separate activations 32 seconds apart, and the stub's checks ran twice inside it under two activity ids. Two view instances, one process, and whatever the first left behind was still there when the second arrived.

That makes `startAnimation()` and `stopAnimation()` load-bearing in a way a single run would never reveal. `Shuffle` starts its loop lazily on the first `draws(at:on:)` and holds it in `loop`, with nothing that cancels it; in the window that is correct, because the window's lifetime is the process's. In the saver it is a leak with a schedule attached — every wake, every dismissal, every settings visit adds a picture loop to a process nobody restarts, each one asking the agent for a photograph on its own ten-second tick. A night of sleep cycles would end with the agent serving a crowd of dead views.

So Phase 3 owes three things, none of them large:

- **`stopAnimation()` cancels the loop** and drops the reference. `Shuffle.loop` is a `Task` already, so this is a `cancel()` and a `nil`.
- **`startAnimation()` is idempotent.** Called twice without an intervening stop, it must not start a second loop.
- **The picture on screen survives a stop and start**, because the alternative is a black frame every time the machine wakes — which is *Always have something to show* broken by the surface it was written for.

Worth noting what this does *not* imply: the two instances were both `preview: false`, so this is not the settings thumbnail. It is the ordinary run path, twice.

### What Phase 3 actually found, and why the three things above were not enough

**The duplication is across views, not within one**, and that was the wrong guess for most of a morning. Both of the things above — an idempotent start and a stop that cancels — operate on a single view, and neither of them can stop two *different* views doing the same job. Nor is it one view per screen: on 2026-09-08 two views reported the **same** display UUID, `37D8832A-…`, on a laptop with no external display, no Sidecar and no Universal Control. The earlier reading of "one instance per display" in `PLAN.md` is simply not what the host does.

**The cost was measured, live.** Between 08:40 and 08:59 a `legacyScreenSaver` process that had outlived its session drew deals 29557 through 29668 — about 110 photographs at one every ten seconds — with nothing on screen at all. That is the leak this section predicted, observed rather than reasoned about, and it ended only when an install killed the host.

**The fix is `DisplayShuffles`: one loop per display, borrowed.** A view asks the registry for its display's loop and gives the claim back when it is done; the loop runs while at least one view holds a claim. However many views the host decides to make, a screen gets one loop, one consumer row, and one card per dwell. Two consequences fall out that were not the goal and are worth having: a view that appears while a loop is already running **joins it and inherits the photograph already on screen**, so a wake is not a black frame; and a `Shuffle` is only ever stopped, never discarded, so the picture outlives every view that showed it.

**Three ways a claim comes back, and the second one is not redundancy.** `stopAnimation`, losing the window, and `deinit`. In the confirming run at 09:14 one of the two views **never received `stopAnimation` at all** — only `window=false, running=true` released it. Had the registry relied on `stopAnimation` alone, that display's loop would have run all day.

**And one more bug underneath, which is the interesting one.** The first attempt keyed the registry off a display id captured at first layout, and it did not dedupe anything: one view keyed to `unknown` and its sibling to the real UUID, so there were still two loops. `NSWindow.screen` is nil until the window has been *placed* on a screen, and `window != nil` is a different question that happens to be true earlier. The identity is now resolved live on every attach — starting, gaining a window, each layout — so a view that attaches early corrects itself onto the right loop rather than holding a wrong answer for ever. After that change the log showed one `new loop`, one `joined the loop … now 2 views`, both instances reporting the same card and deal, and sequential deals at one per dwell.

## Two build systems over one set of sources

**Every product is an Xcode target as of 2026-09-08**: the app, its tests, `Photo-Go-Round Saver`, `Photo-Go-Round Saver Spike`, `Photo-Go-Round Server`, and `pgr_ctl`. Syd's reason is the right one and it is not about building: *"by having xcode targets I can debug things in Xcode if needed."* A `.saver` and a headless agent are both awkward to attach a debugger to, and a target is the thing Xcode knows how to attach to.

This supersedes the earlier decision to assemble the saver with `swiftc` from a script. That was defensible when the saver linked nothing; it stopped being defensible once the point was to debug the real thing.

**The package is untouched and `swift test` remains the test story.** The executables' Xcode targets read straight out of `Sources/photogoroundd` and `Sources/pgr_ctl` through synchronized folders, so there is one copy of every source file and two ways to build it. `Console` had to become a library product — an Xcode target can link a package's *products* and cannot see a bare target.

**The scripts stay, and their job narrowed to deployment.** *"Scripts are nice for deployment"*, and *"real terminals are better than xcode's console for non-gui stuff"* — both true, and both name work Xcode does not do: copying into `~/Library/Screen Savers`, clearing the two caches that otherwise run the previous build, writing the LaunchAgent plist, running the agent where its stdout is readable. `make-saver-bundle.sh` now drives `xcodebuild` and then does that half.

**The risk of two build systems is real and it appeared on the first day.** The agent target failed to compile sources that `swift build` accepts — two `sending 'store' risks causing data races` errors in `SourceEndpoint.swift` — because the Xcode target had `SWIFT_APPROACHABLE_CONCURRENCY = YES` and the package does not. It changes isolation inference, so the same file was being compiled under different rules by the two systems. Removed from the agent and `pgr_ctl`; the app and saver keep it, having been written under it. **That setting is the first place to look when the two disagree again**, and they will.

**What the Xcode side does not do yet.** The agent target produces the `LSUIElement` bundle but not the `Contents/Library/LaunchAgents/` plist — that is still `make-agent-bundle.sh`, which is consistent with scripts owning deployment. There are no shared schemes; Xcode autocreates them per user on first open. **2026-09-10:** the shipping route is a per-user plist in `~/Library/LaunchAgents` with the binary left in the app bundle, not the in-bundle plist `SMAppService` wants — see `PLAN.md`, *The agent: registration and permissions*.

## Building, installing, and reloading

The `.saver` is a new bundle target in `app/Photo-Go-Round.xcodeproj`, alongside the app and its test bundle. Four settings carry the whole configuration risk, and `PLAN.md`'s *Swift everywhere, including the screensaver* names three of them because the failure mode for each is identical and maximally unhelpful — the saver silently does not appear in System Settings, with no error anywhere:

- `WRAPPER_EXTENSION = saver`, on a bundle target rather than a framework or app target.
- `NSPrincipalClass` set to exactly the string in `@objc(PGRScreenSaverView)`, so Swift's name mangling never reaches the plist.
- Both `init?(frame:isPreview:)` and `init?(coder:)` present, because the class is instantiated through the Objective-C runtime.
- The target links `PhotoGoRoundDisplay` from the local package, statically, the way the app does.

Installation for development is a copy into `~/Library/Screen Savers/`, which exists on this machine already. Two caches then get in the way, and both are worth writing into a script rather than rediscovering each time: `legacyScreenSaver` holds loaded bundles for the life of its process, and the Screen Saver pane holds its own list. `killall legacyScreenSaver` and quitting System Settings between builds is the whole of it.

For exercising it without waiting for an idle timer, `/System/Library/CoreServices/ScreenSaverEngine.app` can be launched directly. That is the fast loop for Phase 3 and the closest thing this phase has to a debugger.

**It runs the saver that is *selected*, which cost the first Phase 1 run.** Launching the engine with something else configured loads that instead, produces a perfectly empty log for our subsystem, and looks exactly like a bundle that failed to load. The saver has to be chosen in System Settings first — under **Other**, since a `.saver` is a legacy plug-in — and System Settings has to be quit and reopened after an install for the list to be re-read. The tell that distinguishes the two cases takes one command: if `legacyScreenSaver` appears nowhere in `log show --predicate 'process == "legacyScreenSaver"'`, no legacy saver was loaded at all and the bundle is not the problem.

**Separate `DerivedData` for anything an agent builds**, per standing practice on this project — `-derivedDataPath` on every `xcodebuild` invocation, never sharing Xcode's intermediates.

## Testing a saver

The moved code keeps its tests and gains a home that can run them: `ShuffleTests` currently lives in the Xcode test bundle and `@testable import Photo_Go_Round`, and after the move it belongs in `Tests/PhotoGoRoundDisplayTests` where `swift test` reaches it. That is a net improvement independent of this phase — the rule *a picture already showing is never taken down* is the deck's first duty and its tests should not require Xcode to run.

What cannot be unit-tested is the part that is new: whether a bundle loads, whether the sandbox permits a connection, whether a principal class resolves. Those are observed by running the thing and reading the log, which is the same standard Phases 1 and 2 were held to — and Phase 1 is the demonstration, since every one of its findings came out of log lines rather than a test.

**The stub is worth keeping past its phase, and it is cheap to keep.** It links nothing, so it still builds when everything else is mid-refactor, and it answers "is the sandbox still letting us out" in one command on a macOS release that changes the host's entitlements under us. Deleting it would mean rewriting it the first time a beta breaks something. The log lines are the deliverable for that half, so they get written as carefully as the code: what the saver was asked to do, what it asked the agent for, what came back, and how big it was.

## Not yet decided

Listed rather than asked, one at a time as they come up:

- **How a stale published port is handled**, which the file fallback inherits and the spike did not exercise: the agent synchronizes after publishing, or the client tolerates a stale value and retries.
- **Whether `Trouble` gains a case for an unreadable port.** `PictureClient` distinguishes it; the window does not, and says "No agent" for both. They are the same predicament for the person looking at the glass and nothing alike in the log, which is where the distinction is currently spent.
- **Whether `Shuffle` keeps its name** once it is shared by three surfaces and sits one import away from the deck's own use of the word.
- **Whether the dwell becomes a preference.** It is `Shuffle.defaultDwell`, ten seconds, and `PLAN.md` holds *Everything user-settable is a user default* back to Beyond 0.1 on the grounds that "a number nobody has looked at yet is not worth a key." Two surfaces wanting different numbers is the thing that would change that, and this phase is where the second one arrives.
- **Whether the saver is ever installed by the app,** which is a 1.0 distribution question but decides whether an App Group is available to solve port discovery properly.

## What this left stale in PLAN.md

**Applied 2026-09-07 and again 2026-09-08, at Syd's instruction, and annotated rather than overwritten** — `PLAN.md`'s own house style keeps a wrong argument visible when the error is easy to make again, so each of these is a marked correction beside the original text rather than a replacement of it. One typo was corrected in passing and flagged in place: the sandbox section's closing line said the spike "determines the shape of Phase 5", meaning Phase 6.

A third round, later on 2026-09-08, rewrote *Preview mode must not consume the queue* — and got it wrong. A fourth, on 2026-09-09, corrected it: the preview is live, it is an ordinary instance in another process, and the rule is not being met. Both rounds are left in `PLAN.md`, the second correcting the first in place.

The second round, 2026-09-08, corrected three more things: *Screensaver v1*'s "one instance per display" (macOS makes more views than screens, measured), *The empty state* (the wandering label is built and kept), and *The agent: registration and permissions* (everything is an Xcode target; the scripts own deployment).

The six from the first round, as they stood:

- ***The screensaver sandbox problem*** describes a four-rung ladder and a day-long spike. Options 1, 2, and 4 are unnecessary, XPC is impossible rather than untested, and the consumption-journal fallback is moot. What survives is option 3, granted, plus a port-discovery question the section does not currently contain.
- **Phase 6's line** — "can a saver inside `legacyScreenSaver` make an HTTP request? That is the whole question now" — is not the whole question, and 2026-09-07 measured both halves. It can make the request; it cannot read the preference domain that says where to send it. The second half is absent from `PLAN.md` entirely.
- ***Screensaver v1: one photo, fit, with a slow pan*** describes a v1 that includes the pan, the cross-fade, and the bouncing empty state. This plan's v1 is the photograph and nothing else, by decision on 2026-09-07.
- **"Preview peeks at the queue without draining it, which the queue supports directly"** predates *The service is the interface*. The queue supports it; the wire does not expose it.
- **The empty state has two owners and no builder.** `app/mac/FEATURES.md` lists *The empty state moves* as the app's, "built here so Phase 6 inherits it", while `Shuffle.swift:59` parks the bouncing letters as "Phase 6's treatment". Each document points at the other.
- ***The Mac app as instrument panel*** calls full screen "the screensaver's rehearsal space" where the fit, the pan, the transitions, and the empty state get tuned before Phase 6. Only the fit was.

# References

- `PLAN.md` — *The screensaver sandbox problem*, *Screensaver v1: one photo, fit, with a slow pan*, *The empty state*, *Swift everywhere, including the screensaver*, *The service is the interface*, *The database is private to the service*, *The Mac app as instrument panel*, Phase 6.
- `app/mac/FEATURES.md` — *The empty state moves*, *Saying the agent is not there*, *The app brings its own agent*.
- `Sources/PhotoGoRoundDisplay/` — `PictureClient.swift`, `AspectFit.swift`, `Pan.swift`, `ServedPicture.swift`.
- `app/mac/Sources/Shuffle.swift` and `app/mac/Sources/PictureLayerView.swift` — the two files Phase 2 moves.
- `app/saver/Sources/PGRScreenSaverView.swift` and `app/saver/Sources/DisplayShuffles.swift` — the saver and the per-display registry. `app/saver/Spike/` keeps Phase 1's stub, which still links nothing.
- `Scripts/make-saver-bundle.sh` — drives `xcodebuild` and then installs; `--spike` builds the probe.
- `/System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex` — the host, and the entitlements read from it on 2026-09-07 against macOS 27.0.
- `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/` — the host's container, present on this machine, along with an `.x86-64` sibling carrying identical entitlements.
- Apple: `ScreenSaverView` class reference; App Sandbox temporary exception entitlements.
- Apple Developer Forums, [legacyScreenSaver — blank Preview in Monterey 12.1](https://developer.apple.com/forums/thread/698019) — `FB9835060`, the timer workaround, and its fix in Ventura.
- Apple Developer Forums, [Is there any future for screensavers on macOS?](https://developer.apple.com/forums/thread/797121) — third-party savers are confined to `legacyScreenSaver` because the modern engine is private.
