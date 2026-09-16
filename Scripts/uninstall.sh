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

AGENT_LABEL="com.sydpolk.photogoround.server"
EXTENSION_ID="com.sydpolk.photogoround.wallpaper.extension"
EXTENSION_PROCESS="Photo-Go-Round Wallpaper"
SAVER="$HOME/Library/Screen Savers/Photo-Go-Round Screensaver.saver"

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
  --agent       Boots out the LaunchAgent and deletes its plist from
                ~/Library/LaunchAgents. The built bundle stays where it is.
  --wallpaper   Unregisters every copy of the wallpaper extension and stops the
                extension process. If it is the chosen wallpaper, macOS falls
                back to a default picture.
  --saver       Deletes ~/Library/Screen Savers/Photo-Go-Round Screensaver.saver
                and stops the hosts holding it.

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
    if launchctl print "gui/$UID/$AGENT_LABEL" >/dev/null 2>&1; then
        launchctl bootout "gui/$UID/$AGENT_LABEL" 2>/dev/null || true
        echo "  booted out $AGENT_LABEL"
    else
        echo "  no job to boot out"
    fi
    plist="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
    if [[ -f "$plist" ]]; then
        rm -f "$plist"
        echo "  removed $plist"
    else
        echo "  no plist to remove"
    fi
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
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        found=1
        pluginkit -r "$path" 2>/dev/null || true
        echo "  unregistered $path"
    done < <(pluginkit -m -D -v -p com.apple.wallpaper 2>/dev/null \
        | grep -F "$EXTENSION_ID(" \
        | sed -n 's|^[^/]*\(/.*\)$|\1|p')
    [[ "$found" -eq 0 ]] && echo "  nothing was registered"
    killall "$EXTENSION_PROCESS" 2>/dev/null && echo "  stopped the extension process" || true
    # Unregistering a *selected* extension leaves WallpaperAgent failing every
    # acquire until it is restarted — measured 2026-09-15, desktop stuck on a
    # fallback picture. It is macOS's own agent and comes back on its own.
    killall WallpaperAgent 2>/dev/null && echo "  restarted WallpaperAgent" || true
fi

if [[ "$SAVER_WANTED" -eq 1 ]]; then
    echo "screensaver:"
    if [[ -d "$SAVER" ]]; then
        rm -rf "$SAVER"
        echo "  removed $SAVER"
    else
        echo "  nothing installed"
    fi
    killall legacyScreenSaver 2>/dev/null && echo "  stopped legacyScreenSaver" || true
    killall ScreenSaverEngine 2>/dev/null && echo "  stopped ScreenSaverEngine" || true
fi

echo
echo "the library, cache and preferences are untouched"
