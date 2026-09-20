# Installing Photo-Go-Round on a Mac

The three products that run outside Xcode — the agent, the wallpaper extension and the screensaver — each have an Install scheme in `app/Photo-Go-Round.xcodeproj`. Each one builds what it installs first.

**The saver installs on ⌘R; the other two still install on ⌘B.** Separating building from installing is being done one product at a time — `Plans/Xcode - Separate Build and Run.md` — and the screensaver went first, on 2026-09-19. For it, ⌘B compiles and changes nothing, and ⌘R runs `pgr_install`. For the agent and the wallpaper extension, ⌘B still installs and ⌘R does nothing, because their targets are still aggregates with no product. `Build Plan.md`, *The install phases*, holds why they are separate targets and what each script does; this file is only the steps. Written 2026-09-16, revised 2026-09-19 for the build configurations. If the scripts and this file ever disagree, the scripts are right and this file is stale.

**The configuration decides the identity of everything you install.** `Debug`, `Release` and `Claude` each install under their own names, so all three can sit on one Mac at once and an install never replaces another configuration's copy. Build in `Debug` unless you mean otherwise; set it in Product → Scheme → Edit Scheme → Run → Info → Build Configuration.

| | Release | Debug | Claude |
|---|---|---|---|
| Agent port | 9427 | 9428 | 9429 |
| LaunchAgent label | `com.sydpolk.photogoround.server` | `….server.debug` | `….server.claude` |
| Screensaver | `Photo-Go-Round Screensaver.saver` | `… (Debug).saver` | `… (Claude).saver` |
| Wallpaper extension | `…wallpaper.extension` | `…wallpaper.debug.extension` | `…wallpaper.claude.extension` |
| Container, cache, domain | `~/Library/…/com.sydpolk.photogoround[.dev]` | `….debug[.dev]` | `….claude[.dev]` |

`Claude` is what an agent working on this project builds; you will not normally choose it.

The app itself is not installed: run the **Photo-Go-Round** scheme from Xcode.

`pgr_ctl` is not installed either. Build the **pgr_ctl** scheme and put the product on your `PATH` — a copy or a symlink into `~/bin`. Do not reach for `swift run pgr_ctl`: it writes a `.build` directory into the checkout, and nothing generated belongs there.

**`pgr_ctl` addresses one configuration's library at a time**, and defaults to its own build's and to production. Against a Debug agent installed by the steps below, that means:

```bash
pgr_ctl status --development --debug
```

## Order

1. **Install Agent** — everything else fetches from it.
2. **Install Wallpaper Extension**
3. **Install Screen Saver**

## 1. Install Agent

Scheme **Install Agent**, ⌘B. The script `Scripts/install-agent.sh` boots out any running job and waits for launchd to finish removing it, writes `~/Library/LaunchAgents/<label>.plist` — the label read from the built bundle's `PGRLaunchAgentLabel`, so `com.sydpolk.photogoround.server.debug` for a Debug build — pointing at that bundle, and bootstraps it. macOS may ask for Documents and iCloud Drive if a source lives there.

**Photos access is granted in the app, not by an install.** Open **Photo-Go-Round** and add a Photos source; the prompt comes from there. No install asks, because a grant is asked for by something with a window and an installer has none — and the agent cannot ask at all, since reading its authorization status is a TCC preflight that shows nothing.

The agent logs to the unified log, subsystem `com.sydpolk.photogoround`. It writes no file:

```bash
/usr/bin/log show --info --last 5m --predicate 'subsystem == "com.sydpolk.photogoround"'
```

It says `serving pictures on http://localhost:<port>/v1/next` when it is up. To watch it live:

```bash
/usr/bin/log stream --info --predicate 'subsystem == "com.sydpolk.photogoround"'
```

`--info` is needed: a release build logs per-picture lines below the level `log show` prints by
default.

## 2. Install Wallpaper Extension

Scheme **Install Wallpaper Extension**, ⌘B. It builds **Photo-Go-Round Wallpaper Host**, the shell app that carries the extension, then `Scripts/install-wallpaper-extension.sh` stops the extension process running from that bundle, removes dead registrations, registers the appex with `pluginkit`, waits for `pkd` to record it, and restarts `WallpaperAgent` so the desktop is re-acquired.

A Debug build is `com.sydpolk.photogoround.wallpaper.debug.extension`, named **Photo-Go-Round Wallpaper (Debug)**; Release is `com.sydpolk.photogoround.wallpaper.extension`, **Photo-Go-Round Wallpaper**. Both appear in the same Photo-Go-Round section.

Then System Settings › Wallpaper › **Photo-Go-Round Wallpaper (Debug)**, in the Photo-Go-Round section:

```bash
open "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
```

The desktop shows the last photograph it kept, or the blue-and-yellow mark on a first install, then a photograph from the agent. It changes on the wallpaper's *Shuffle All* interval, an hour unless set otherwise in the app's Settings or with:

```bash
pgr_ctl wallpaper set interval oneHour --development --debug
```

A change to the interval is picked up within ten seconds.

## 3. Install Screen Saver

Scheme **Install Screen Saver**, **⌘R** — not ⌘B, which since 2026-09-19 only builds. `pgr_install saver` copies the built bundle — `Photo-Go-Round Screensaver (Debug).saver` in Debug — into `~/Library/Screen Savers`, replacing only the one of its own name, and stops the screen saver hosts holding the old copy — only the ones actually running, which it names.

Then System Settings › Screen Saver › **Photo-Go-Round Screensaver**, under *Other*. Its interval is the screensaver's *Shuffle All* in the app's Settings, ten seconds by default.

## Checking

The agent's served lines name the consumer:

```bash
/usr/bin/log show --last 15m --predicate 'subsystem == "com.sydpolk.photogoround" AND eventMessage BEGINSWITH "served status="'
```

`system-wallpaper` is the extension on the desktop, `screensaver` is the saver. The extension's own lines:

```bash
/usr/bin/log show --info --last 15m --predicate 'subsystem == "com.sydpolk.photogoround" AND category == "system-wallpaper"'
```

## Reinstalling

Build the same target again. Each script replaces its own product and nothing else: the agent's plist is rewritten, the extension's dead registrations — those whose bundle no longer exists, or now holds a different identifier — are removed and the new copy registered, the saver's old bundle is replaced. Selections in System Settings survive.

## After a Clean Build Folder

⇧⌘K deletes the built products, and the wallpaper extension's registration goes with them: `pkd` drops a registration whose bundle is gone, so at the next login `WallpaperAgent` cannot build our wallpaper and falls back to one of Apple's — Golden Gate. Measured 2026-09-17.

Rebuild and reinstall all three, in the order above, and choose the wallpaper again in System Settings.

## Removing

```bash
./Scripts/uninstall.sh
```

Or one at a time with `--agent`, `--wallpaper`, `--saver`. The library, cache and preferences are left alone.
