# Installing Photos-Go-Round on a Mac

Three products run outside the app: the agent, the wallpaper extension and the screensaver. **Every build of `Photos-Go-Round.app` carries all three inside its bundle and installs them itself** — at launch, and from its Help menu. That is the route this file starts with. Each product also has an `Install …` scheme in `Photos-Go-Round.xcodeproj`, the development route, further down.

## Installing from the app

**At every launch, every build:**

1. **The agent** — installed if it is not, then restarted.
2. Nothing more until it answers, up to ninety seconds — a first launch in a fresh account builds its storage from nothing, and took over twenty seconds in one. While it waits, the install log says why, once per change: no port published yet, no secret yet, a refused secret, a timeout, or a refused connection.
3. **The wallpaper** — registered again if the extension running is not this app's, if this app's registration is older than its appex, or if it is not registered but is still the chosen wallpaper.

**A Release build also**, at launch:

- registers the wallpaper if it is not registered;
- links the screensaver if nothing is at its name.

**The Help menu**, in any build: Install Agent, Install Wallpaper, Install Screensaver — each installs whatever is there — and Uninstall for each, which removes this build's copy and never another configuration's.

The window shows a spinner and what it is doing, and the controls are disabled, while any of it runs.

**Nothing is copied out of the app.**

| | What is installed | Where it points |
|---|---|---|
| Agent | `~/Library/LaunchAgents/<label>.plist` | `Photos-Go-Round.app/Contents/Helpers/Photos-Go-Round Server.app` |
| Wallpaper | a `pkd` registration | `Photos-Go-Round.app/Contents/Library/Wallpaper/Photos-Go-Round Wallpaper.appex` |
| Screensaver | a symlink in `~/Library/Screen Savers` | `Photos-Go-Round.app/Contents/Resources/Photos-Go-Round Screensaver<suffix>.saver` |

The appex is in `Contents/Library/Wallpaper`, not `Contents/Extensions`, so that building the app registers nothing: Xcode registers every app it builds with LaunchServices, which registers whatever is in `Contents/Extensions`.

**A Release build** is an archive, copied into `/Applications` and launched.

**System Settings reads the list of screensavers once, when it opens.** One left open across an install does not show the new saver until it is quit and opened again. Seen 2026-09-22.

**Photos access** is asked for in the app: Settings › Choose Collections › **Allow Access…**. An agent inside the app asks on the app's behalf, so the grant is the app's — `com.sydpolk.photosgoround`, the same in every configuration.

What each launch did, a line per product:

```bash
/usr/bin/log show --info --last 10m --predicate 'subsystem == "com.sydpolk.photosgoround" AND category == "install"'
```

**Claude's agent** is installed and managed by a script Syd runs, because launching a build installs its agent:

```bash
./Scripts/claude-agent.sh install
```

`uninstall`, `start` and `stop` too. It touches only `com.sydpolk.photosgoround.server.claude`.

## Installing from the Install schemes

**All three install on ⌘R.** ⌘B compiles and installs nothing; ⌘R runs `pgr_install`. That became true on 2026-09-19, when the three aggregate targets were replaced by schemes that build their product alongside `pgr_install` and run it. `--dry-run` on any of them prints what would happen and does none of it.

One thing ⌘B still does, and it is Xcode's doing rather than an install: **building the wallpaper host registers the extension with `pkd`**, because Xcode registers host-app builds by itself. It registers only that build's own identity, so it cannot displace another configuration's. `Build Plan.md`, *The install phases*, holds why they are separate targets and what each script does; this file is only the steps. Written 2026-09-16, revised 2026-09-19 for the build configurations. If the scripts and this file ever disagree, the scripts are right and this file is stale.

**The configuration decides the identity of everything you install.** `Debug`, `Release` and `Claude` each install under their own names, so all three can sit on one Mac at once and an install never replaces another configuration's copy. Build in `Debug` unless you mean otherwise; set it in Product → Scheme → Edit Scheme → Run → Info → Build Configuration.

| | Release | Debug | Claude |
|---|---|---|---|
| Agent port | 20000 + hash of user name | 23000 + hash | 26000 + hash |
| LaunchAgent label | `com.sydpolk.photosgoround.server` | `….server.debug` | `….server.claude` |
| Screensaver | `Photos-Go-Round Screensaver.saver` | `… (Debug).saver` | `… (Claude).saver` |
| Wallpaper extension | `…wallpaper.extension` | `…wallpaper.debug.extension` | `…wallpaper.claude.extension` |
| Container, cache, domain | `~/Library/…/com.sydpolk.photosgoround[.dev]` | `….debug[.dev]` | `….claude[.dev]` |

`Claude` is what an agent working on this project builds; you will not normally choose it.

The app itself is not installed: run the **Photos-Go-Round** scheme from Xcode. **Launching it installs and restarts its own agent**, pointing the plist at the copy inside the app — so after a ⌘R of the app, an agent the **Install Agent** scheme installed is replaced by the app's.

`pgr_ctl` is not installed either. Build the **pgr_ctl** scheme and put the product on your `PATH` — a copy or a symlink into `~/bin`. Do not reach for `swift run pgr_ctl`: it writes a `.build` directory into the checkout, and nothing generated belongs there.

**`pgr_ctl` addresses one configuration's library at a time**, and defaults to its own build's and to production. Against a Debug agent installed by the steps below, that means:

```bash
pgr_ctl status --development --debug
```

### Order

1. **Install Agent** — everything else fetches from it.
2. **Install Wallpaper Extension**
3. **Install Screen Saver**

### 1. Install Agent

Scheme **Install Agent**, **⌘R** — not ⌘B, which since 2026-09-19 only builds. `pgr_install agent` reports any agent running that it did not start and leaves it alone, boots out the job of this configuration's label, waits up to ten seconds for launchd to finish removing it, writes `~/Library/LaunchAgents/<label>.plist` — the label read from the built bundle's `PGRLaunchAgentLabel`, so `com.sydpolk.photosgoround.server.debug` for a Debug build — pointing at that bundle, and bootstraps it. `--dry-run` prints all of that and does none of it. macOS may ask for Documents and iCloud Drive if a source lives there.

**Photos access is granted in the app, not by an install.** Open **Photos-Go-Round** and add a Photos source; the prompt comes from there. No install asks, because a grant is asked for by something with a window and an installer has none — and the agent cannot ask at all, since reading its authorization status is a TCC preflight that shows nothing.

#### The gap this leaves, which is accepted

**Install everything and never open the app, and the agent is permanently half-blind.** Folder sources work; every Photos source stays unavailable, and the only sign is a line in the log. Measured 2026-09-15, before the app owned the ask: a fresh install sat at 867 of 9183 photographs with both Photos sources dark, reporting nothing on screen.

Nothing recovers from it on its own, because nothing will ever prompt. Opening the app once fixes it for good. **Whose grant it is depends on where the agent runs.** An agent the app installs runs from inside the app, and macOS records its Photos grant against the app, `com.sydpolk.photosgoround`; one `pgr_install agent` installs from a build directory is recorded against `com.sydpolk.photosgoround.server`. Neither identifier varies by build configuration, so each is answered once and not once per build.

Syd, 2026-09-19, deciding it: "all access is controlled either by the toy app I have now, the app we are going to develop, any potential app-store friendly apps, or any potential menubar apps", and "this limitation should be fine". The alternative was a second implementation of the prompt inside every install, which is what was deleted.

The agent logs to the unified log, subsystem `com.sydpolk.photosgoround`. It writes no file:

```bash
/usr/bin/log show --info --last 5m --predicate 'subsystem == "com.sydpolk.photosgoround"'
```

It says `serving pictures on http://localhost:<port>/v1/next` when it is up. To watch it live:

```bash
/usr/bin/log stream --info --predicate 'subsystem == "com.sydpolk.photosgoround"'
```

`--info` is needed: a release build logs per-picture lines below the level `log show` prints by
default.

### 2. Install Wallpaper Extension

Scheme **Install Wallpaper Extension**, **⌘R** — not ⌘B, which since 2026-09-19 only builds. It builds **Photos-Go-Round Wallpaper Host**, the shell app that carries the extension, then `pgr_install wallpaper` removes registrations that are dead — the bundle gone, or the bundle now holding a different identifier — while leaving every other configuration's live copy alone, stops only the extension process running from this bundle, registers the appex with `pluginkit`, waits up to thirty seconds for `pkd` to record it, and restarts `WallpaperAgent` so the desktop is re-acquired.

A Debug build is `com.sydpolk.photosgoround.wallpaper.debug.extension`, named **Photos-Go-Round Wallpaper (Debug)**; Release is `com.sydpolk.photosgoround.wallpaper.extension`, **Photos-Go-Round Wallpaper**. Both appear in the same Photos-Go-Round section.

Then System Settings › Wallpaper › **Photos-Go-Round Wallpaper (Debug)**, in the Photos-Go-Round section:

```bash
open "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
```

The desktop shows the last photograph it kept, or the blue-and-yellow mark on a first install, then a photograph from the agent. It changes on the wallpaper's *Shuffle All* interval, an hour unless set otherwise in the app's Settings or with:

```bash
pgr_ctl wallpaper set interval oneHour --development --debug
```

A change to the interval is picked up within ten seconds.

### 3. Install Screen Saver

Scheme **Install Screen Saver**, **⌘R** — not ⌘B, which since 2026-09-19 only builds. `pgr_install saver` copies the built bundle — `Photos-Go-Round Screensaver (Debug).saver` in Debug — into `~/Library/Screen Savers`, replacing only the one of its own name, and stops the screen saver hosts holding the old copy — only the ones actually running, which it names.

Then System Settings › Screen Saver › **Photos-Go-Round Screensaver**, under *Other*. Its interval is the screensaver's *Shuffle All* in the app's Settings, ten seconds by default.

## Checking

The agent's served lines name the consumer:

```bash
/usr/bin/log show --last 15m --predicate 'subsystem == "com.sydpolk.photosgoround" AND eventMessage BEGINSWITH "served status="'
```

`system-wallpaper` is the extension on the desktop, `screensaver` is the saver. The extension's own lines:

```bash
/usr/bin/log show --info --last 15m --predicate 'subsystem == "com.sydpolk.photosgoround" AND category == "system-wallpaper"'
```

## Reinstalling

⌘R the same scheme again. `pgr_install` replaces its own configuration's product and nothing else: the agent's plist is rewritten, the extension's dead registrations — those whose bundle no longer exists, or now holds a different identifier — are removed and the new copy registered, the saver's old bundle is replaced. Selections in System Settings survive.

## After a rebuild, or a Clean Build Folder

**Rebuilding the app drops the wallpaper extension's registration**, and the desktop goes grey: `pkd` removes a registration whose bundle changed, and `WallpaperAgent` does not start the extension again. Measured 2026-09-21. The app's next launch registers it again, because it is still the chosen wallpaper.

⇧⌘K deletes the built products, and the registration goes with them. If `WallpaperAgent` gives up on it first — at a login, say — it falls back to one of Apple's, Golden Gate, measured 2026-09-17, and the choice has to be made again in System Settings.

Installed from the schemes instead: ⌘R all three, in the order above.

## Removing

```bash
./Scripts/uninstall.sh
```

Or one at a time with `--agent`, `--wallpaper`, `--saver`. `--dry-run` says what would go and removes nothing. The app's Help menu removes one piece of its own build. The library, cache and preferences are left alone — `Scripts/scrub-dev.sh` is what clears development storage.

It finds every configuration's copy, not just the one you last built: three labels, three saver names, three extension identifiers, all from `BuildVariant`.

## What is doing the installing

The app and `pgr_install` both run `PhotosGoRoundInstall`. The app links it and installs what it carries; `pgr_install` is what an `Install …` scheme runs on ⌘R, installs from a build directory, copies the saver rather than linking it, and ships in nothing.

`Documentation/pgr_install.md` is its man page. `--dry-run` works on every command, and prints what would happen without doing any of it — which is the quickest way to see what an install is about to change.

## SEE ALSO

`pgr_install(1)`, `Documentation/pgr_install.md` — every install and the uninstall.

`Photos-Go-Round Server(1)`, `Documentation/Photos-Go-Round Server.md` — the agent itself, and running it in a terminal instead.

`Plans/Xcode - Separate Build and Run.md` — why ⌘B stopped installing.

`Plans/Release App Installer.md` — the app as the installer.
