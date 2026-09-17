# Installing Photo-Go-Round on a Mac

The three products that run outside Xcode — the agent, the wallpaper extension and the screensaver — each have an Install target in `app/Photo-Go-Round.xcodeproj`. Select the scheme and build it (⌘B). The targets are aggregates with no product, so Run (⌘R) does nothing. Each one builds what it installs first. `Build Plan.md`, *The install phases*, holds why they are separate targets and what each script does; this file is only the steps. Written 2026-09-16. If the scripts and this file ever disagree, the scripts are right and this file is stale.

The app itself is not installed: run the **Photo-Go-Round** scheme from Xcode. `pgr_ctl` is not installed either: `swift run pgr_ctl` from the repo root.

## Order

1. **Install Agent** — everything else fetches from it.
2. **Install Wallpaper Extension**
3. **Install Screen Saver**

## 1. Install Agent

Scheme **Install Agent**, ⌘B. The script `Scripts/install-agent.sh` boots out any running job and waits for launchd to finish removing it, writes `~/Library/LaunchAgents/com.sydpolk.photogoround.server.plist` pointing at the built bundle, bootstraps it, waits for the port, then asks Photos for access if it has never been asked. Allow the prompt. macOS may also ask for Documents and iCloud Drive if a source lives there.

The agent logs to `/tmp/com.sydpolk.photogoround.server.log`:

```bash
tail -20 /tmp/com.sydpolk.photogoround.server.log
```

It ends with `serving pictures on http://localhost:<port>/v1/next` when it is up.

## 2. Install Wallpaper Extension

Scheme **Install Wallpaper Extension**, ⌘B. It builds **Photo-Go-Round Wallpaper Host**, the shell app that carries the extension, then `Scripts/install-wallpaper-extension.sh` stops the extension process running from that bundle, removes dead registrations, registers the appex with `pluginkit`, waits for `pkd` to record it, restarts `WallpaperAgent` so the desktop is re-acquired, and checks Photos access.

A Debug build is `com.sydpolk.photogoround.wallpaper.debug.extension`, named **Photo-Go-Round Wallpaper (Debug)**; Release is `com.sydpolk.photogoround.wallpaper.extension`, **Photo-Go-Round Wallpaper**. Both appear in the same Photo-Go-Round section.

Then System Settings › Wallpaper › **Photo-Go-Round Wallpaper (Debug)**, in the Photo-Go-Round section:

```bash
open "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
```

The desktop shows the last photograph it kept, or the blue-and-yellow mark on a first install, then a photograph from the agent. It changes on the wallpaper's *Shuffle All* interval, an hour unless set otherwise in the app's Settings or with:

```bash
swift run pgr_ctl wallpaper set interval oneHour
```

A change to the interval is picked up within ten seconds.

## 3. Install Screen Saver

Scheme **Install Screen Saver**, ⌘B. `Scripts/install-saver.sh` copies `Photo-Go-Round Screensaver.saver` into `~/Library/Screen Savers`, stops the screen saver hosts holding the old copy, and checks Photos access.

Then System Settings › Screen Saver › **Photo-Go-Round Screensaver**, under *Other*. Its interval is the screensaver's *Shuffle All* in the app's Settings, ten seconds by default.

## Checking

The agent's served lines name the consumer:

```bash
grep "▸" /tmp/com.sydpolk.photogoround.server.log | tail -10
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
