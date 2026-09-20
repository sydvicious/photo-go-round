# Running the wallpaper extension

The steps for the real extension: `app/wallpaper-extension`, target **Photo-Go-Round Wallpaper**, which in development is carried by the shell app `app/wallpaper-host`, target **Photo-Go-Round Wallpaper Host**. `Wallpaper Plan.md`, *The real extension, inside the app*, holds what it is and why, and `Build Plan.md` holds why the shell app exists; this file is only the steps. Written 2026-09-15; the install steps moved to `Documentation/Installing.md` on 2026-09-16. If the code and this file ever disagree, the code is right and this file is stale.

The four probes that came before it were built by `Scripts/make-wallpaper-extension-probe.sh`, retired on 2026-09-15 once the real extension did everything they had proved. Git holds it, and `Wallpaper Plan.md` holds what each probe found.

**The agent has to be running**, since every picture comes from it.

## 1. Build and install it

Scheme **Install Wallpaper Extension**, **⌘R** — `Documentation/Installing.md`. ⌘B only builds, since 2026-09-19. It builds the host, registers the appex and restarts `WallpaperAgent`. The manual route it replaced, kept for when the script is what is broken:

```bash
xcodebuild build -project app/Photo-Go-Round.xcodeproj -scheme "Photo-Go-Round Wallpaper Host" -destination "platform=macOS,arch=arm64" -configuration Debug
```

```bash
pluginkit -a "$HOME/Library/Developer/Xcode/DerivedData"/Photo-Go-Round-*/Build/Products/Debug/"Photo-Go-Round Wallpaper Host.app/Contents/Extensions/Photo-Go-Round Wallpaper.appex"
```

An appex registers only from inside a signed app bundle — measured 2026-09-15 — which is the host's whole reason to exist.

## 2. Check it is registered

```bash
pluginkit -m -D -v -p com.apple.wallpaper | grep photogoround
```

It should list **`com.sydpolk.photogoround.wallpaper.debug.extension`** once, at your DerivedData path — a Debug build's identifier. Release is `…wallpaper.extension` and an agent's build is `…wallpaper.claude.extension`; since 2026-09-16 each configuration registers under its own, so seeing more than one identifier is normal and not a conflict.

**A second copy of the same identifier at a different path** is the one to remove, with `pluginkit -r` on that path: LaunchServices keeps one record per identifier and the wrong copy may be the one loaded. A *different* identifier at a different path belongs to another configuration and is left alone — `pgr_install wallpaper` makes exactly that distinction, and removing another build's live copy is a mistake that has been made here before.

If a stale extension process is still answering, stop **only yours**. Every configuration's process has the same name, so `killall` by name stops another build's wallpaper too:

```bash
pkill -f "$HOME/Library/Developer/Xcode/DerivedData/Photo-Go-Round-"*"/Build/Products/Debug/Photo-Go-Round Wallpaper Host.app/Contents/MacOS/"
```

## 3. Run the gates

Open System Settings › Wallpaper. Choose another wallpaper first, then **Photo-Go-Round Wallpaper** in the Photo-Go-Round section.

```bash
open "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
```

- **The pane.** A Photo-Go-Round section with one item, its thumbnail the blue-and-yellow mark.
- **The desktop.** The last photograph kept, or the mark on a first install, then a new photograph.
- **The rotation.** Each display asks again on the *Shuffle All* interval. Set a short one to watch it:

```bash
pgr_ctl wallpaper set interval tenSeconds --development --debug
```

- **The lock screen.** Control-Command-Q shows the photograph the desktop is showing.

## 4. Read what happened

The extension's own lines:

```bash
/usr/bin/log show --info --last 15m --predicate 'subsystem == "com.sydpolk.photogoround" AND category == "system-wallpaper"'
```

The agent's served lines for it:

```bash
/usr/bin/log show --info --last 15m --predicate 'eventMessage CONTAINS "consumer=system-wallpaper"'
```

Everything the system said about the extension — `pkd`, `WallpaperAgent` and the rest, which name it by its bundle identifier:

```bash
/usr/bin/log show --info --last 15m --predicate 'eventMessage CONTAINS "photogoround.wallpaper"'
```

That matches all three configurations. Narrow it to one by naming it in full —
`com.sydpolk.photogoround.wallpaper.debug.extension` for a Debug build.

## 5. Put things back

Choose your usual wallpaper in System Settings › Wallpaper, and put the interval back:

```bash
pgr_ctl wallpaper set interval oneHour --development --debug
```

If the pane or the desktop hangs, restart `WallpaperAgent`:

```bash
killall WallpaperAgent
```
