#!/bin/bash
#
# Takes Photo-Go-Round off this Mac. `Build Plan.md`, *The install phases*.
#
# Syd, 2026-09-15: "we need an uninstall script for all of these agents". Three
# installs put things in three places — a LaunchAgent, a plug-in registration and
# a bundle in Screen Savers — and the one you forget is the one that keeps
# running.
#
# **It removes what was installed, not what was built.** Build directories, the
# library, the cache and the preferences are left alone: uninstalling is not the
# same as throwing away the photographs you chose. `Scripts/scrub-dev.sh` is the
# one that clears development storage.
#
# **Nothing here needs the checkout that installed it.** Everything is found by
# label, identifier and name.

set -euo pipefail

# **Three of everything, one per build configuration.** Release, Syd's Debug and
# an agent's Claude build each install under their own label, their own saver
# name and their own extension identifier, so all three can be on this Mac at
# once — and an uninstall that knew only one name would leave the other two
# running. `BuildVariant.swift` is the Swift half of these same three;
# `Plans/Xcode - Separate Build and Run.md`, *The build variant, compiled in*.
AGENT_LABELS=(
    "com.sydpolk.photogoround.server"
    "com.sydpolk.photogoround.server.debug"
    "com.sydpolk.photogoround.server.claude"
)
EXTENSION_IDS=(
    "com.sydpolk.photogoround.wallpaper.extension"
    "com.sydpolk.photogoround.wallpaper.debug.extension"
    "com.sydpolk.photogoround.wallpaper.claude.extension"
)
EXTENSION_PROCESS="Photo-Go-Round Wallpaper"
SAVERS=(
    "$HOME/Library/Screen Savers/Photo-Go-Round Screensaver.saver"
    "$HOME/Library/Screen Savers/Photo-Go-Round Screensaver (Debug).saver"
    "$HOME/Library/Screen Savers/Photo-Go-Round Screensaver (Claude).saver"
)

AGENT=0
WALLPAPER=0
SAVER_WANTED=0

usage() {
    cat <<'HELPTEXT'
Removes what Photo-Go-Round's installs put on this Mac.

USAGE
  ./Scripts/uninstall.sh [--agent] [--wallpaper] [--saver]

  With no options it removes all three.

WHAT EACH ONE REMOVES
  --agent       Boots out every LaunchAgent — release, Debug and Claude's —
                and deletes their plists from ~/Library/LaunchAgents. The built
                bundles stay where they are.
  --wallpaper   Unregisters every copy of the wallpaper extension — release,
                Debug and Claude's builds — and stops the extension processes.
                If it is the chosen wallpaper, macOS falls back to a default
                picture.
  --saver       Deletes every Photo-Go-Round Screensaver bundle from
                ~/Library/Screen Savers — release, " (Debug)" and " (Claude)" —
                and stops the hosts holding them.

WHAT IT NEVER TOUCHES
  The library, the cache, preferences, and anything under a build directory. See
  Scripts/scrub-dev.sh for development storage.
HELPTEXT
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent) AGENT=1; shift ;;
        --wallpaper) WALLPAPER=1; shift ;;
        --saver) SAVER_WANTED=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "$AGENT" -eq 0 && "$WALLPAPER" -eq 0 && "$SAVER_WANTED" -eq 0 ]]; then
    AGENT=1
    WALLPAPER=1
    SAVER_WANTED=1
fi

if [[ "$AGENT" -eq 1 ]]; then
    echo "agent:"
    found=0
    for label in "${AGENT_LABELS[@]}"; do
        if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
            launchctl bootout "gui/$UID/$label" 2>/dev/null || true
            echo "  booted out $label"
            found=1
        fi
        plist="$HOME/Library/LaunchAgents/$label.plist"
        if [[ -f "$plist" ]]; then
            rm -f "$plist"
            echo "  removed $plist"
            found=1
        fi
    done
    [[ "$found" -eq 0 ]] && echo "  no job and no plist for any configuration"
    # An agent started by hand is somebody's terminal process, not this script's
    # to end.
    others="$(pgrep -f photogoroundd 2>/dev/null || true)"
    if [[ -n "$others" ]]; then
        echo "  note: an agent is still running, started outside launchd:"
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && echo "    pid $pid — $(ps -o comm= -p "$pid" 2>/dev/null || true)"
        done <<< "$others"
    fi
fi

if [[ "$WALLPAPER" -eq 1 ]]; then
    echo "wallpaper extension:"
    found=0
    for id in "${EXTENSION_IDS[@]}"; do
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            found=1
            pluginkit -r "$path" 2>/dev/null || true
            echo "  unregistered $id"
            echo "    $path"
        done < <(pluginkit -m -D -v -p com.apple.wallpaper 2>/dev/null \
            | grep -F "$id(" \
            | sed -n 's|^[^/]*\(/.*\)$|\1|p')
    done
    [[ "$found" -eq 0 ]] && echo "  nothing was registered"
    killall "$EXTENSION_PROCESS" 2>/dev/null && echo "  stopped the extension process" || true
    # Unregistering a *selected* extension leaves WallpaperAgent failing every
    # acquire until it is restarted — measured 2026-09-15, desktop stuck on a
    # fallback picture. It is macOS's own agent and comes back on its own.
    killall WallpaperAgent 2>/dev/null && echo "  restarted WallpaperAgent" || true
fi

if [[ "$SAVER_WANTED" -eq 1 ]]; then
    echo "screensaver:"
    found=0
    for saver in "${SAVERS[@]}"; do
        if [[ -d "$saver" ]]; then
            rm -rf "$saver"
            echo "  removed $saver"
            found=1
        fi
    done
    [[ "$found" -eq 0 ]] && echo "  nothing installed"
    killall legacyScreenSaver 2>/dev/null && echo "  stopped legacyScreenSaver" || true
    killall ScreenSaverEngine 2>/dev/null && echo "  stopped ScreenSaverEngine" || true
fi

echo
echo "the library, cache and preferences are untouched"
