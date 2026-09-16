# Running the wallpaper extension

The steps for the real extension: `app/wallpaper-extension`, target **Photo-Go-Round Wallpaper**, which in development is carried by the shell app `app/wallpaper-host`, target **Photo-Go-Round Wallpaper Host**. `Wallpaper Plan.md`, *The real extension, inside the app*, holds what it is and why, and `Build Plan.md` holds why the shell app exists; this file is only the steps. Written 2026-09-15. If the code and this file ever disagree, the code is right and this file is stale.

The four probes that came before it were built by `Scripts/make-wallpaper-extension-probe.sh`, retired on 2026-09-15 once the real extension did everything they had proved. Git holds it, and `Wallpaper Plan.md` holds what each probe found.

**The agent has to be running**, since every picture comes from it.

## 1. Build the host

In development the extension lives in a shell app of its own, **Photo-Go-Round Wallpaper Host**, so that building or running `Photo-Go-Round` never touches it. Build that scheme in Xcode, or:

```bash
xcodebuild build -project app/Photo-Go-Round.xcodeproj -scheme "Photo-Go-Round Wallpaper Host" -destination "platform=macOS,arch=arm64" -configuration Debug
```

The host carries the extension at `Photo-Go-Round Wallpaper Host.app/Contents/Extensions/`. An appex registers only from inside a signed app bundle — measured 2026-09-15 — which is the host's whole reason to exist.

## 2. Register it

Nothing needs launching. Point `pluginkit` at the built appex, replacing the path with your own DerivedData path if you built in Xcode:

```bash
pluginkit -a "$HOME/Library/Developer/Xcode/DerivedData"/Photo-Go-Round-*/Build/Products/Debug/"Photo-Go-Round Wallpaper Host.app/Contents/Extensions/Photo-Go-Round Wallpaper.appex"
```

Then check macOS sees it:

```bash
pluginkit -m -D -v -p com.apple.wallpaper | grep photogoround
```

It should list `com.sydpolk.photogoround.wallpaper.extension`. If an older copy holds that identifier, remove it with `pluginkit -r` on its path first — two copies of one identifier cannot both be seen. If a stale extension process is still answering, stop it:

```bash
killall "Photo-Go-Round Wallpaper"
```

## 3. Run the gates

Open System Settings › Wallpaper. Choose another wallpaper first, then **Photo-Go-Round** in the Photo-Go-Round section.

```bash
open "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
```

- **The pane.** A Photo-Go-Round section with one item, its thumbnail the blue-and-yellow mark.
- **The desktop.** The mark first, then one of your photographs in its place.
- **The rotation.** Each display asks again on the *Shuffle All* interval. Set a short one to watch it:

```bash
swift run pgr_ctl wallpaper set interval tenSeconds
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

Everything the system said about the extension:

```bash
/usr/bin/log show --info --last 15m --predicate 'eventMessage CONTAINS "wallpaper-extension"'
```

## 5. Put things back

Choose your usual wallpaper in System Settings › Wallpaper, and put the interval back:

```bash
swift run pgr_ctl wallpaper set interval oneHour
```

If the pane or the desktop hangs, restart `WallpaperAgent`:

```bash
killall WallpaperAgent
```
