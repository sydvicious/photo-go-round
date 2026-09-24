# Summary

Five products — the app, the wallpaper extension, the screensaver, the agent, and `pgr_ctl` — each built by its own Xcode target, with one script per product and one script that runs them all for CI.

**Installing stopped being a build phase on 2026-09-19.** It is what ⌘R does, by running `pgr_install` over the `PhotoGoRoundInstall` module; ⌘B only builds. `Plans/Xcode - Separate Build and Run.md` is the plan that did it, and the reversal is recorded in *Design Decisions* below rather than edited out of it.

# Rationale

The products were built four different ways when this was written: the app and the wallpaper extension from Xcode, the screensaver from a script that drives `xcodebuild`, the agent from a script that calls `swift build` rather than its own target, and `pgr_ctl` from `swift run`. **Since 2026-09-19 there is one way — `xcodebuild`, by scheme and configuration.** Syd: "what I really want is each target runnable via xcodebuild. If there are shell scripts that get called, ok."

Installing was a fifth thing again — a copy for the saver, a plist for the agent, nothing for the app, and for the extension a rule nobody had written down. That was four mental models for one project, none of them exercised by CI, and it is why a wallpaper extension got registered every time the app was run whether or not anything in it had changed. Syd, 2026-09-15: "My vision is that the target for each thing would have a build phase that would install it for dev, and for release, and different schemes would call that correctly." **That vision is what 2026-09-19 revised**: the target builds, and the scheme's Run action installs.

# Phases

- *The targets* — every product builds independently from its own scheme.
  - The agent moves from `swift build` to its `Photo-Go-Round Server` target. **Done.** `Scripts/photogoroundd` builds that target too, since 2026-09-19, so a terminal agent carries its configuration's port and label. *It is `Scripts/run-server.sh` since 2026-09-22, and the binary it runs is `Photos-Go-Round Server`.*
  - `pgr_ctl` likewise, from `swift run` to its own target. **Done.** It is built and copied onto a `PATH`; `swift run` is no longer the documented route.
  - **No target extracts App Intents metadata. `LM_SKIP_METADATA_EXTRACTION = YES` at project level, 2026-09-16.** Xcode ran `ExtractAppIntentsMetadata` on every app, extension and bundle target, and each printed "warning: Metadata extraction skipped, no AppIntents.framework dependency found" — the app, the saver, the saver spike, the agent, the wallpaper host and the wallpaper extension. Nothing here uses App Intents. Syd: "fix that warning". Verified from a clean build of each scheme: no warning, and no extraction step on the project's own targets. If App Intents is ever adopted, that target turns it back on.
  - **Every module a target imports is declared as its package product dependency. Fixed 2026-09-16 for `pgr_ctl`.** Its sources import `PhotoGoRoundDisplay` (`WallpaperCommands.swift`, `main.swift`) and the target did not declare it. Built alone, Xcode found the import and linked the module anyway; built after `Photo-Go-Round Server` in the same build folder it did not, and the link failed on `ShuffleInterval` and `WallpaperPreferences`. Reproduced in a fresh folder, fixed by declaring the product, and the same order then built. Every other target was checked the same way; `Photo-Go-RoundTests` declares nothing it imports and needs nothing, since it is hosted by the app (`BUNDLE_LOADER`).
  - **Done 2026-09-15: the app no longer embeds the wallpaper extension.** Syd: "yes, drop the embed."
- *The install phases* — **built 2026-09-15, and replaced 2026-09-19.** Three aggregate targets carried a script phase each, with `ENABLE_USER_SCRIPT_SANDBOXING = NO`. All three are deleted; the project now has no `PBXShellScriptBuildPhase` at all.
  - **`Install Wallpaper Extension`**, **`Install Agent`** and **`Install Screen Saver`** are schemes now, not targets. Each builds its product and `pgr_install`, and its Run action installs. ⌘B changes nothing.
  - The app and `pgr_ctl` still have no dev install, and need none: the app runs from Xcode, and `pgr_ctl` is a copy or symlink into `~/bin`.
  - Dev installs in place from the build directory; release is Archive, moved to `/Applications` by hand. Syd, 2026-09-19: "We use Archive to generate the app bundle."
  - **Uninstall is `Scripts/uninstall.sh`**, run by hand — a wrapper over `pgr_install uninstall` since 2026-09-19, so it holds no names of its own. *Since 2026-09-24 it says which build, and `Scripts/install.sh` is its counterpart; see* The scripts.
- *The scripts* — **mostly overtaken.** The five-scripts shape assumed a script was how a product got built; `xcodebuild` is, and a script is only what a target calls or a convenience over one.
  - `make-saver-bundle.sh` survives, defaults its output to DerivedData, and its `--install` calls `pgr_install saver`.
  - `make-agent-bundle.sh` is deleted, 2026-09-19. It hand-assembled a bundle the `Photo-Go-Round Server` target already produces, and wrote a second copy of the LaunchAgent plist. `SMAppService` went with it — see *Design Decisions*.
  - `make-app.sh`, `make-wallpaper-extension.sh` and `make-pgr-ctl.sh` were never written and are not wanted: each is `xcodebuild -scheme`.
  - **Every script Syd runs to install, uninstall or delete takes `--variant` or `--all`. Built 2026-09-24.**
    - `Scripts/install.sh`, new: builds a configuration and installs its agent, saver and wallpaper, as an Install scheme's ⌘R does.
    - `Scripts/uninstall.sh`: no longer removes every configuration's copy unasked.
    - `Scripts/scrub-data.sh`, renamed from `scrub-dev.sh`: deletes a build's library, cache and preferences, current and retired names alike.
    - `Scripts/claude-agent.sh` is deleted; `install.sh --variant claude --agent` and `pgr_install start|stop --variant claude` replace it.
    - `Scripts/variants.sh`, sourced by all three: the option handling, the names, and the one `pgr_install` build.
    - Uninstalling one configuration no longer reports another's launchd agent as hand-started, nor restarts `WallpaperAgent` or the screensaver hosts when it removed nothing.
- *The combining script* — `Scripts/build-all.sh`, which runs the five in order and is what CI calls.
  - It builds; it installs nothing unless asked.
  - Its exit status is the build's, so a red CI run means a broken build and nothing else.

# Build hygiene lives in `CLAUDE.md`

Written 2026-09-17, at Syd's "I guess I need to put build hygene into this project's CLAUDE.md", after an agent built the `Install Screen Saver` scheme "to check it compiles" and its script replaced Syd's installed saver. `CLAUDE.md` at the top of the repo holds the rules any builder follows on his machine. This plan stays the *why*; that file is the *don't*.

**Rewritten 2026-09-19, and much shorter.** The three settings an agent used to pass per product are a build configuration now, so the rule is `-configuration Claude` and build into `~/.claude/build/photo-go-round`. `Scripts/install-*.sh` no longer exist. Building an `Install …` scheme is ordinary — ⌘R is what installs, and pressing it is Syd's. The one thing ⌘B still does is Xcode's own: building the wallpaper host registers the extension with `pkd`, under that build's own identifier, so an agent unregisters afterwards.

# Design Decisions

- **One target, one scheme, one script per product.** Anything buildable is buildable alone, from Xcode and from a terminal, with the same result.
- **Installing was a build phase, not a script's job. Reversed 2026-09-19.** It was: the scripts call the same phases the schemes do, so CI and Xcode cannot drift apart. Syd, 2026-09-15. What it cost was that asking "does this compile?" of an install target changed the machine — and on 2026-09-17 an agent building `Install Screen Saver` replaced Syd's installed saver. Syd, 2026-09-16: "we should think about separating build and install for everything, so command-b builds and command-r runs", and on 2026-09-19: "all of the install targets install on command R."

  **What replaced it keeps the property the original was for.** One implementation, `PhotoGoRoundInstall`, driven by `pgr_install`; the schemes run it and so does every script, so CI and Xcode still cannot drift apart. `Plans/Xcode - Separate Build and Run.md`.
- **An install ran from a target of its own, not from a phase on the product's target. Moot since 2026-09-19**, because no install runs from a build phase at all. **The measurement behind it still matters and is why:** a Run Script phase always runs *before* its own target is code-signed, and `pkd` refuses an appex inside an unsigned bundle — "plug-ins outside containing apps must be protected by SIP". Measured 2026-09-15, after the phase-on-the-target version failed exactly this way. An install that runs after the build, from a Run action, never meets the problem.
- **Dev and release differ by configuration, not by a separate phase.** A Debug build installs where a developer wants it; a Release build does nothing and leaves packaging to the release script.
- **In dev the extension lives in a shell app of its own, built into DerivedData.** Syd, 2026-09-15: "for dev, we can make a shell app to put it in, and install it from the DerivedData build of that app", and "finish the shell app". An appex has to be inside a signed app bundle to register, and this keeps that bundle out of the real app, so building or running `Photo-Go-Round` never touches the extension. Claude's names: target `Photo-Go-Round Wallpaper Host`, bundle identifier `com.sydpolk.photogoround.wallpaper`, `LSUIElement`, no interface. It is a dev container and ships in nothing. **Built and measured working 2026-09-15.**
- **The extension's bundle identifier is `com.sydpolk.photogoround.wallpaper.extension`.** Xcode refuses to embed an appex whose identifier is not prefixed by its container's, so the sibling pair `…wallpaper-host` and `…wallpaper-extension` could not work. This spelling satisfies the host now and the real app's `com.sydpolk.photogoround` in the release wrapper later. Renamed 2026-09-15 from `com.sydpolk.photogoround.wallpaper-extension`. **Since 2026-09-16 that is Release's;** Debug builds are `com.sydpolk.photogoround.wallpaper.debug.extension` in a host `…wallpaper.debug`, and Claude's builds pass `WALLPAPER_ID_SUFFIX=.claude` for `…wallpaper.claude.extension`, so no build registers over another's. `Wallpaper Plan.md`, *Debug builds under their own identity*.
- **Release puts every bundle inside the app wrapper, and the app installs them.** Syd, 2026-09-15: "The Release schema will put all of the necessary bundles in the app wrapper, and the app will have to install them. But that's a later goal." So the Release story ends with one app carrying the saver, the extension and the agent, and an installer inside it — later. Dev is what this plan builds now. **Reaffirmed 2026-09-16**, when Syd asked how to install prod and Claude offered Release install targets as a stopgap: "app bundle for release seems correct." Until it is built there is no way to install a Release build — the install targets skip Release, and the app has not carried the extension since 2026-09-15.
- **An install clears only registrations whose bundles are gone.** Syd, 2026-09-15: "only remove copies whose paths no longer exist." It first removed every other copy holding the identifier, reasoning that one record per identifier means the wrong copy may answer — and that turned out to hijack: a build from one directory silently unregistered the copy another directory had installed, and the last build won. It happened to Syd's DerivedData registration while Claude was verifying a target dependency from its own build directory. A registration pointing at a bundle that no longer exists is dead and worth clearing; one pointing at a bundle somebody else built is theirs.
  - **Not measured:** which copy `WallpaperAgent` loads when two live copies share an identifier. Leaving both registered is now possible, and nothing here establishes what happens then.
  - **Unregistering a selected extension wedges the pane.** Claude's hijacking build on 2026-09-15 left `WallpaperAgent` failing every `acquire` with 4099 and never attempting a launch, with the desktop fallen back to a stock picture. It recovered after `killall WallpaperAgent` and re-selecting; which of the two was needed is untested. Another reason an install must not touch a copy it did not build. *2026-09-16: killing the extension process alone, which every install does, also left the desktop dark grey until the wallpaper was chosen again — `WallpaperAgent` does not re-acquire from the new process by itself. The install script now restarts `WallpaperAgent` once `pkd` has the new copy, and the next install re-acquired the desktop in the same second. `Wallpaper Plan.md`, *The app's loop, removed*.*
  - A stale *process* is still stopped: `killall` on the extension, which the probes showed will otherwise keep answering after a rebuild.
- **The whole dev install runs from the command line.** Build the app and the extension as separate schemes, copy the appex into the app's `Contents/Extensions/`, and `pluginkit -a` it — nothing launched, no Xcode. `pluginkit -r` backs it out. Measured end to end 2026-09-15. The one constraint is that the appex must be inside an app bundle when it is registered; a bare `.appex` is refused silently, exit 0 and no record.
- **Dev builds are arm64 only.** Done 2026-09-15; see `TODO.md`, *Build for arm64 only*.
- **Build products never land in the repo.** `TODO.md`, *Build products out of the repo*, which this plan absorbs.
- **Every install checked that the agent has Photos access. Reversed 2026-09-19.** It was Syd, 2026-09-15, of the saver's install: "it also needs to make sure the agent has photos access", held once in `Scripts/ensure-photos-access.sh` and called by all three. That script is deleted and no install asks.

  **The rule that replaced it is general.** Syd, 2026-09-19: "all access is controlled either by the toy app I have now, the app we are going to develop, any potential app-store friendly apps, or any potential menubar apps." A grant is asked for by something with a window; an installer has none, and the agent cannot ask at all, because reading its own authorization status is a TCC preflight that shows nothing. The app already owns the ask — `SourceService.postPhotosAuthorization`, and `CollectionPickerView.unauthorized` for the refused state.

  **What it leaves:** somebody who installs and never opens the app gets a half-blind agent, which is the 2026-09-15 failure over again — folder sources working, Photos sources dark, and nothing on screen to say so. Syd, 2026-09-19: "this limitation should be fine." **Written down rather than left to be rediscovered**: `Documentation/Installing.md`, *The gap this leaves, which is accepted*, and a shorter note in `Documentation/pgr_install.md`.
- **Uninstalling is a script, never a target.** Syd, 2026-09-15: "I am willing to run that on the command line." `Scripts/uninstall.sh` removes all three — the job and its plist, every registration of the extension, the saver bundle — or one at a time with `--agent`, `--wallpaper`, `--saver`. It leaves the library, the cache, preferences and every build directory alone, and it reports rather than kills an agent somebody started by hand.
- **A script that changes the system says which build.** Syd, 2026-09-24: "I want all installers and uninstallers that I run to take a --variant argument, and accept --all for all three variants." `--variant` may repeat; with neither, the script refuses rather than choosing.
- **Deleting data is its own script, not an option on uninstall.** `scrub-data.sh` stops the build's agent first, and names come only from `--variant`, never from a path or `PGR_BUILD_ROOT`.
- **An uninstall asks launchd whose each running agent is.** A process a loaded job owns, of any configuration, is not reported as hand-started.
- **No third-party build tooling.** `xcodebuild`, `codesign`, `pluginkit`, `launchctl`, and shell. Nothing else. **`swift build` came off this list on 2026-09-19**: it has only `debug` and `release`, so it cannot produce the `Claude` identity, and anything built that way binds Syd's Debug port and carries his label. `swift test` likewise — `xcodebuild test -scheme "Package Tests"` runs all five package test targets.

# Background

- The project is one Swift package plus one Xcode project. The package holds `PhotoGoRoundAgentAPI`, `PhotoGoRoundKit`, `PhotoGoRoundDisplay`, `Console`, `photogoroundd` and `pgr_ctl`; the Xcode project holds the app, the saver, the saver spike, the agent, `pgr_ctl` and, since 2026-09-15, the wallpaper extension. *Renamed 2026-09-22: the modules are `PhotosGoRound…`, and `photogoroundd` is `PhotosGoRoundServer`.*
- `Scripts/make-saver-bundle.sh` and `Scripts/make-agent-bundle.sh` already existed and were the model the rest were to follow — options, an `--install` that is the owner's call, and output under DerivedData. **That model was overtaken on 2026-09-19**: a product is built by its scheme, and the only script left that builds one is the saver's.
- The wallpaper extension is an appex embedded in the app. `Wallpaper Plan.md`, *The real extension, inside the app*.
- Syd, 2026-09-15, on what prompted this: "I don't want the wallpaper extension installed every time I run the app even if there is no source change in it."

# Detailed discussions

## What was measured, 2026-09-15

Four things, all on Syd's MacBook Pro, and all of them shape the decisions above.

- **An incremental app build re-copies and re-signs the extension even with no source change.** A second `xcodebuild` of the app scheme, with nothing edited, still ran `Copy … Photo-Go-Round Wallpaper.appex` and re-signed the app. So "nothing changed" does not mean "nothing happened", and an install driven by the app's build runs every time.
- **`pluginkit -a` registers an appex with nothing launched** — but only observably when its bundle identifier is not already registered by another copy. Two earlier attempts appeared to fail; both reused the identifier of the DerivedData build, and LaunchServices showed one record. Rebuilt with `PRODUCT_BUNDLE_IDENTIFIER=…-idtest`, the same command registered it immediately. **That appex was inside an app bundle.**
- **A bare appex cannot be registered; one inside an app can.** With the embed dropped, the extension scheme produces `Photo-Go-Round Wallpaper.appex` on its own. `pluginkit -a` on it exits 0 and registers nothing — no record by identifier, by extension point, or anywhere. Copy that same appex into a separately built `Photo-Go-Round.app/Contents/Extensions/` and the same command registers it immediately, with nothing launched. Both measured 2026-09-15 with `PRODUCT_BUNDLE_IDENTIFIER=…-baretest`, so no existing registration could mask either result.
- **So the install is three commands, and no part of it needs Xcode or a running app:** build the scheme, `cp` the appex into an app bundle, `pluginkit -a`. Removing it is `pluginkit -r`.
- **`pluginkit -a` returns before the record exists.** An immediate check finds nothing and a check a few seconds later finds it, so anything verifying its own install has to wait rather than call it a failure.
- **An install target needs `ENABLE_USER_SCRIPT_SANDBOXING = NO`.** The project sets it `YES`, and under it `pluginkit -a` still registers but `pluginkit -m` returns nothing at all — so a script cannot see the install it just performed. Thirty seconds of polling from inside the build found nothing while the record was plainly there from a terminal a moment later. Measured 2026-09-15; the same build with sandboxing off verified on its first try. The setting is on the install target alone, not the project.
- **An install script is a shared-state change, and needs to behave like one.** Building an install target from a scratch directory reached into the Mac's one LaunchServices record and took it: the plug-in database is machine-wide, so "install what I just built" and "leave everyone else alone" are different instructions, and only the second is safe to run from anywhere. The same applies to the agent's install, which boots a job out by label.
- **A Run Script phase cannot see its own target's signature.** The build log order is: script phase, then `CodeSign`. An install phase on the host target therefore registered an unsigned bundle every time, which `pkd` rejected with "plug-ins outside containing apps must be protected by SIP" — the same message a bare appex gets, which made it look like the host had not been built at all.
- **`lsregister -f` did not visibly register the extension** in the same colliding-identifier conditions. Whether it would with a free identifier was not tested, because `pluginkit -a` answered the question.
- **Building the extension's scheme alone still produces a host app.** `Photo-Go-Round Wallpaper.appex` came out inside `Photo-Go-Round.app`, since the appex is embedded by the app target. Building the extension alone therefore yields something registrable, which is what an install phase needs.

## An incremental build after a concurrency-feature change does not link

**Measured 2026-09-17**, turning on `NonisolatedNonsendingByDefault` for the package and the project. An incremental `xcodebuild` of `Photo-Go-Round Server` failed with "symbol(s) not found": `Deadline.run` and the other `nonisolated async` functions mangle differently once the feature is on, and the agent's own sources had been rebuilt against a package module that had not. `xcodebuild clean build` succeeded. Worth knowing for any later change of this kind; nothing to fix.

## What Apple does, and why we cannot

Apple's own wallpaper extensions are standalone `.appex` bundles in `/System/Library/ExtensionKit/Extensions/` — `WallpaperImageExtension.appex`, `WallpaperAerialsExtension.appex` and a dozen more, each holding only `Info.plist`, `MacOS`, `Resources` and `_CodeSignature`, with no host app anywhere. That directory is scanned by the system, which is why an Apple engineer building a wallpaper extension needs no container app at all. Syd, 2026-09-15: "I can't imagine the Apple engineers working on their wallpaper extensions need this hack." They do not; the directory is SIP-protected and not available to us.

What is available was measured the same day, in three steps:

- a bare `.appex` on its own — `pluginkit -a` exits 0 and registers nothing;
- a hand-made `.app` holding only an `Info.plist`, with no executable and no signature — the same silent refusal;
- a built, signed app with the appex inside `Contents/Extensions/` — registers at once, nothing launched.

So a third-party extension needs a real signed app bundle around it, and the only question is which one. The shell app is that bundle for development, and it exists because the alternative — the real app — would re-register the extension on every run.

## Photos, and why the agent goes half-blind without a prompt

Measured 2026-09-15, installing the agent as a job for the first time.

- **A status read never prompts.** Every source refresh reads `PHPhotoLibrary.authorizationStatus`, which `tccd` logs as `preflight=yes`: it answers "is this allowed?" and shows nothing. `.notDetermined` comes back, each Photos source is marked "Photos access has not been granted yet", and the refresh moves on.
- **So a fresh install is permanently half-blind.** The job ran, the folder sources worked, and the pool sat at 867 of 9183 photographs with both Photos sources dark. The only sign was a line in `/tmp/com.sydpolk.photogoround.server.log`. Syd saw prompts for iCloud and Documents — file access, from launchd — and reasonably expected one for Photos.
- **`POST /v2/photos/authorization` is the only call that can raise it**, and its own comment says so. One `curl` produced the prompt; granting it and ringing `pgr_ctl notify sources` brought both sources back, 942 then 9183 dealable.
- **`pgr_ctl status` mid-refresh lies a little.** It reported "1 unavailable" while source 5 was still being scanned, and 0 a few seconds later. A count taken during a refresh is a snapshot of an unfinished job.
- **Not established:** whether a rebuilt agent is asked again. TCC records a grant against the code signature, and a DerivedData build is re-signed on every build, so the grant may or may not survive. Worth watching rather than assuming. **Since 2026-09-19 the route with a stable identity is Archive**, moved to `/Applications` by hand; `make-agent-bundle.sh` is deleted.

## What "install" means, per product

Each of these is a decision to take on its own, and none is taken yet.

- **The app.** Nothing, in dev: it runs from Xcode. Release is a signed, notarized copy in `/Applications`. *First made 2026-09-23:* Developer ID signed and notarized through Organizer's *Direct Distribution*, installed, and running production. `Scripts/release-build.sh` is the command-line route, with a DMG. `PLAN.md`, *Shipping it*.
- **The wallpaper extension.** Dev: the `Photo-Go-Round Wallpaper Host` target embeds it, so building that scheme produces a registrable bundle; `pgr_install wallpaper`, run by ⌘R on the `Install Wallpaper Extension` scheme since 2026-09-19, runs `pluginkit -r` on registrations it judges dead, then `pluginkit -a` on the host's embedded appex, straight from DerivedData. *Since 2026-09-15 only registrations whose bundle is gone are removed, and since 2026-09-16 also those whose bundle now holds a different identifier; the identifier is read from the appex.* Nothing is copied and nothing is launched. Release: it ships inside the app wrapper and the app installs it. **Decided 2026-09-15**, Syd: "for dev, we can make a shell app to put it in". **Measured working the same day**: the host built, carried the appex, registered from DerivedData with nothing running, and unregistered again cleanly.
- **The screensaver.** Dev: the `Install Screen Saver` scheme builds `Photo-Go-Round Saver` and runs `pgr_install saver` on ⌘R, which copies the bundle into `~/Library/Screen Savers` and stops `legacyScreenSaver` and `ScreenSaverEngine` — both cache a loaded bundle for the life of the process, so without the kill a rebuild runs the previous build and looks like a change that did nothing. Built 2026-09-15; **moved to `pgr_install saver` on ⌘R, 2026-09-19**, and `make-saver-bundle.sh --install` calls the same binary rather than keeping a copy. A symlink instead of a copy is still unmeasured.
- **The agent.** Dev: **full install**, decided 2026-09-15 — Syd chose it over building the bundle alone and over writing the plist without starting it. The `Install Agent` scheme builds `Photo-Go-Round Server` and runs `pgr_install agent` on ⌘R, which boots the job out, waits for launchd to forget the label, writes `~/Library/LaunchAgents/<label>.plist` pointing at the built binary, and boots it back in. **The label carries the build configuration since 2026-09-19** — `…server`, `…server.debug`, `…server.claude` — read from the bundle's own `PGRLaunchAgentLabel`, because launchd allows one job per label per user and a shared one meant a Debug install displaced a Release one. Syd, 2026-09-10: "whatever launchctl needs should be put into ~/Library/LaunchAgents so multiple users don't clobber each other."
  - **It waits for launchd to finish removing the old job.** `launchctl bootout` returns before the job is gone: on 2026-09-16 the bootstrap at 13:29:11.409 failed with "37: Operation already in progress", launchd removed the old service at .417, and Xcode showed "Bootstrap failed: 5: Input/output error" with no agent running. The script now polls `launchctl print` for up to ten seconds and fails loudly if the label is still loaded.
  - **It does not kill an agent the owner started.** A terminal agent holding the port is reported with its pid and left alone; the job cannot bind until it goes. Syd killed his by hand on 2026-09-15 rather than have a build do it.
  - **The plist points into DerivedData**, which is right for development and wrong for anything left running — a clean build directory takes the agent with it. `pgr_install agent` says so when the path is one. **Archive is the stable route**, 2026-09-19.
  - **Three ways to run the agent existed before this**, and that is what the decision ends: a terminal process from `Scripts/photogoroundd`, the package's `photogoroundd` scheme in Xcode, which fights the first for the port and exits, and a LaunchAgent nobody had installed.
  - **The install asks for Photos, because the agent cannot ask on its own.** Syd, 2026-09-15: "can we do something to ask for Photos access for the agent during the install script?" It waits for the job to publish its port, reads `GET /v2/photos/authorization`, and POSTs the same path only when the answer is undecided — the one call in the project that raises a prompt, and a no-op for anyone who has already decided.
- **`pgr_ctl`.** Dev: nothing, or a symlink into somewhere on `PATH`. It never ships. `PLAN.md`, *`pgr_ctl`, the command-line tool*.

## The embedding question, answered 2026-09-15

**Syd: "yes, drop the embed."** Option 2 below. The app target no longer carries the extension, no longer depends on it, and building or running the app does nothing to it. What follows is the reasoning as it stood when the question was put.


An appex has to sit inside a host app to be registered at all, so the app target embeds the extension and depends on it. That is what makes a plain Xcode run of the app register the extension — and it is exactly what Syd objected to, because it happens on every run.

Three ways out, none chosen:

1. **Keep the embed, and let the dev install phase own registration.** The copy still happens on every app build; registration stops being a side effect of running the app only if the extension is unregistered when it should not be active, which means an explicit *uninstall* step as well.
2. **Drop the embed.** The extension builds alone, its install phase registers it from wherever it was built, and running the app touches nothing. A fresh clone then has an app with no extension until the extension's own script has run once. This is the option that most directly answers the objection.
3. **A host app of its own**, as the four probes had. The main app never carries the extension; `Photo-Go-Round Wallpaper.app` does. It is a second product to build, sign and install, and it is not the shape that ships.

The measurement that matters here is the first one above: with the embed in place, *something* runs on every app build no matter what. Only option 2 removes that.

## Why the scripts exist as well as the phases

Syd, 2026-09-15: "and also maintain separate scripts as well". A build phase serves Xcode; a script serves a terminal, a second Mac, and CI. Keeping both risks the two drifting, so the rule is that the script invokes the scheme and the scheme runs the phase — the script never reimplements what the phase does. A script that needs behaviour the phase does not have is a sign the phase is wrong.

`Scripts/build-all.sh` is then thin: five `xcodebuild` invocations, one per scheme, arm64, into one derived data path, with `--release` switching configuration. CI runs it and the package's tests; nothing else.

## The scripts take a variant, 2026-09-24

**Why.** A Debug app from Sep 23, found by Spotlight in Xcode's DerivedData and launched after a reboot, installed its own old agent beside the Release one. Removing just that agent meant calling `pgr_install uninstall --variant debug` by hand: `uninstall.sh` rejected `--variant`, and without it removed every configuration's copy. Syd asked for every installer and uninstaller he runs to take `--variant` or `--all`, and for `scrub-dev.sh` to become `scrub-data.sh` over "older versions of data files and current ones."

**`Scripts/variants.sh`** is sourced by the three scripts. It parses `--variant` (repeatable) and `--all` into `VARIANTS`, refuses a run with neither, and spells each configuration's Xcode configuration and suffixes — `BuildVariant.swift`'s names, written again because a shell script cannot read Swift. It builds `pgr_install` once, as Debug, under `$BUILD_ROOT/tools`; which build a command acts on is its `--variant` or `--from`, never the configuration `pgr_install` was built as.

**`install.sh`** builds each chosen configuration under `$BUILD_ROOT/<variant>` — `PGR_BUILD_ROOT`, by default `~/Library/Developer/Xcode/DerivedData/Photos-Go-Round-scripts` — and runs `pgr_install agent|saver|wallpaper --from` on what it built: the `Photos-Go-Round Server` scheme's app, the saver bundle with the configuration's name suffix, and the appex inside the Wallpaper Host. `--dry-run` still builds, because `pgr_install` reads the label and name from the bundle; building the host registers it with `pkd`, as every host-app build does. A Release installed this way runs from that build folder rather than `/Applications`, under the same label, until the app's next launch points it back.

**`uninstall.sh`** passes each variant to `pgr_install uninstall --variant`, or nothing for `--all`, which `pgr_install` reads as every configuration.

**`scrub-data.sh`**, for each variant, deletes the container, cache and preference domain of `com.sydpolk.photosgoround<suffix>` and of its retired `.dev` library, and the preference domains `.screensaver` and `.wallpaper` with their retired `.dev` and `.prod` forms. It stops the variant's agent with `pgr_install stop` — unloaded, so `KeepAlive` does not restart it — and kills any agent started by hand that has one of those containers open. It then restarts `cfprefsd`, whose cached copy would otherwise outlive the file. The screensaver's and wallpaper's remembered pictures are inside sandbox containers macOS protects: they are tried, and a refusal is reported without failing the run. The agent is left stopped; its plist stays, so it returns at the next login or with `pgr_install start`.

**Three defects found on the first real run.** `uninstall.sh --variant debug` removed the Debug agent correctly, and then:

- **It reported Syd's Release agent as "still running outside launchd" and printed `kill 964`.** `Launchctl.agentsOutsideLaunchd` lists every agent process, launchd's included, and `Uninstall` never filtered; removing all three configurations had hidden it. `Uninstall.handStarted` now leaves out every process a loaded job of any configuration owns, read from `launchctl print`'s `pid = N` (`Launchctl.pid(of:)`). Tested: *An agent a loaded job owns is not reported as started by hand*.
- **It restarted `WallpaperAgent` with nothing unregistered**, blanking the Release desktop for a moment. Now only after an unregistration.
- **It would have stopped the screensaver hosts with nothing removed**, ending a Release screensaver mid-show. Now only after a saver is removed.

## What this leaves stale elsewhere

- **`TODO.md`, *Build products out of the repo*. Done and deleted, 2026-09-19.** Every default moved to DerivedData, and the item's real question — where development storage lives once no build writes into the repo — was answered by moving it to `~/Library/Containers/<identifier>[.dev]`, keyed by build configuration so three agents never share a database. Syd: "all of the datafiles have to run in the users home directory so that this will work for two different users on the same machine."
- **`make-saver-bundle.sh` builds the Spike scheme by default**, which is a spike, not the product.
- **`PLAN.md`, *Builds with no warnings: no C++, and schemes rather than targets*** holds the scheme rule this plan follows, and should point here once this is built.
- **The probe script is retired.** `Scripts/make-wallpaper-extension-probe.sh` and `Scripts/wallpaper-extension-probe/` were deleted on 2026-09-15 — Syd: "retire the probe script" — once the real extension did everything the four probes had proved. Git holds them. `Documentation/Wallpaper Extension Probe.md` was renamed `Documentation/Wallpaper Extension.md` the same day, and the probe steps file it briefly pointed at was never written.

# References

- `PLAN.md` — *Builds with no warnings: no C++, and schemes rather than targets*; *`pgr_ctl`, the command-line tool*; *The agent: registration and permissions*; *Two Mac products, sandboxed and Pro*.
- `TODO.md` — *Build products out of the repo*; *Build for arm64 only*; *Installing by launching the app*.
- `Wallpaper Plan.md` — *The real extension, inside the app*; *What the fourth probe found*.
- `Screensaver Plan.md` — how the saver is built and installed today.
- `Scripts/make-saver-bundle.sh`, `Scripts/run-server.sh` (`Scripts/photogoroundd` until 2026-09-22), `Scripts/install.sh`, `Scripts/uninstall.sh`, `Scripts/scrub-data.sh` (`Scripts/scrub-dev.sh` until 2026-09-24), `Scripts/variants.sh`. `make-agent-bundle.sh` was deleted 2026-09-19, `claude-agent.sh` 2026-09-24.
- `Documentation/pgr_install.md` — the binary every install runs now.
- `Plans/Xcode - Separate Build and Run.md` — the plan that separated building from installing, and the measurements behind it.
- `Photo-Go-Round.xcodeproj` — targets `Photo-Go-Round`, `Photo-Go-Round Wallpaper`, `Photo-Go-Round Saver`, `Photo-Go-Round Saver Spike`, `Photo-Go-Round Server`, `pgr_ctl`.
- `pluginkit(8)` — `-a`, `-r`, `-m -D -v`, and `-e use|ignore|default`.
