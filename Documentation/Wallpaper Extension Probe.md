# Running the wallpaper extension probe

The steps for `Scripts/make-wallpaper-extension-probe.sh`, in order. `Wallpaper Plan.md` holds what each probe asks and what it found; this file is only the steps.

The probe built now is **the fourth: pictures from the agent**, as **version 0.4**. The desktop shows the generated picture at once, then asks the agent for a photograph as `system-wallpaper` and shows it instead. Written 2026-09-15. If the script and this file ever disagree, the script is right, and this file is stale.

**The agent has to be running** — the app's, which publishes its port in `com.sydpolk.photogoround.dev`.

## 1. Build and install it

```bash
./Scripts/make-wallpaper-extension-probe.sh
```

The script builds and signs with your development identity, stops the running extension, replaces the copy in `~/Applications`, opens it to register the extension, and waits until `pluginkit` shows the new version. It should end with `registered com.sydpolk.photogoround.wallpaper-probe.extension 0.4`. If it says the extension was not registered, stop there.

## 2. Run the gates

Open System Settings › Wallpaper. Choose another wallpaper first, then **Probe Picture** in the **Photo-Go-Round** section.

```bash
open "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
```

- **The desktop.** The blue-and-yellow picture first; within a few seconds, one of your photographs in its place.
- **Gate 1, the port.** The probe's `agent:` lines in step 3 show which reads found `servicePort`.
- **Gate 2, the agent.** The agent's served line in step 3 shows `consumer=system-wallpaper`.
- **Gate 3, the photograph.** The desktop shows it, and the probe logs the new picture enqueued.

## 3. Read what happened

The probe's own lines:

```bash
/usr/bin/log show --info --last 15m --predicate 'subsystem == "com.sydpolk.photogoround" AND category == "wallpaper-probe"'
```

The agent's served lines for this wallpaper:

```bash
/usr/bin/log show --info --last 15m --predicate 'eventMessage CONTAINS "consumer=system-wallpaper"'
```

Everything the system said about the probe:

```bash
/usr/bin/log show --info --last 15m --predicate 'eventMessage CONTAINS "wallpaper-probe"'
```

The probe's lines should begin with a new pid and "extension started". If they do not, an old process is still answering; run step 1 again.

## 4. Put things back

Choose your usual wallpaper in System Settings › Wallpaper. That restores the lock screen too.

If the pane or the desktop hangs, restart `WallpaperAgent`:

```bash
killall WallpaperAgent
```
