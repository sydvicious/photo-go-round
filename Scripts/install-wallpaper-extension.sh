#!/bin/bash
#
# Registers the wallpaper extension for development, from wherever it was just
# built. `Build Plan.md`, *The install phases*.
#
# Called by the `Photo-Go-Round Wallpaper Host` target's install phase, and
# usable by hand with one argument: the path to the built `.appex`.
#
# **Why a host app at all.** An appex registers only from inside a signed app
# bundle — measured 2026-09-15: `pluginkit -a` on a bare `.appex`, or on a bundle
# holding nothing but an `Info.plist`, exits 0 and registers nothing. The shell
# app is that bundle, so that building or running `Photo-Go-Round` never installs
# or re-registers the extension. Syd: "I don't want the wallpaper extension
# installed every time I run the app even if there is no source change in it."
#
# **Only copies whose bundles are gone are removed.** Syd, 2026-09-15. An earlier
# version removed every other copy holding this identifier, on the reasoning that
# LaunchServices keeps one record per identifier and the wrong one may answer.
# What that actually did, measured the same day, was hijack: a build from one
# directory unregistered the copy another directory had installed, silently, and
# the last build won. A registration pointing at a bundle that no longer exists
# is dead and worth clearing; one pointing at a bundle somebody else built is
# theirs.
#
# **It needs `ENABLE_USER_SCRIPT_SANDBOXING = NO`**, which the install target
# sets. Under the sandbox `pluginkit -a` still registers, but `pluginkit -m`
# returns nothing, so this script cannot see its own work and fails an install
# that in fact succeeded. Measured 2026-09-15.

set -euo pipefail

EXTENSION_ID="com.sydpolk.photogoround.wallpaper.extension"
EXTENSION_PROCESS="Photo-Go-Round Wallpaper"

APPEX="${1:-${BUILT_PRODUCTS_DIR:-}/${CONTENTS_FOLDER_PATH:-}/Extensions/Photo-Go-Round Wallpaper.appex}"

if [[ ! -d "$APPEX" ]]; then
    echo "install-wallpaper-extension: no bundle at $APPEX" >&2
    exit 1
fi

# Every copy holding this identifier, whatever path it was built at.
#
# `pluginkit -m -D -v` prints one record per line: identifier(version), a UUID,
# then a date whose own fields vary, then the path. Counting fields gets the date
# wrong — measured, it left "+0000 " glued to the front of the path — so the path
# is taken as everything from the first slash on, which is unambiguous because a
# bundle path is absolute and nothing before it contains one.
registered_paths() {
    pluginkit -m -D -v -p com.apple.wallpaper 2>/dev/null \
        | grep -F "$EXTENSION_ID(" \
        | sed -n 's|^[^/]*\(/.*\)$|\1|p'
}

while IFS= read -r other; do
    [[ -n "$other" ]] || continue
    [[ "$other" == "$APPEX" ]] && continue
    if [[ -d "$other" ]]; then
        echo "install-wallpaper-extension: leaving another live copy registered"
        echo "  $other"
        continue
    fi
    echo "install-wallpaper-extension: removing a registration whose bundle is gone"
    echo "  $other"
    pluginkit -r "$other" 2>/dev/null || true
done < <(registered_paths)

# A suspended extension process keeps answering after a rebuild, which cost a
# debugging round during the probes. It is launched again on demand.
killall "$EXTENSION_PROCESS" 2>/dev/null || true

pluginkit -a "$APPEX"

# `pluginkit -a` returns before `pkd` has written the record — measured
# 2026-09-15, where an immediate check found nothing and the same check seconds
# later found it. Run from a build it is slower still: the same install that
# verifies first time from a terminal took longer than ten seconds to appear
# while Xcode was finishing. So the check waits, and says what it is waiting for
# rather than failing silently.
for attempt in $(seq 1 30); do
    if registered_paths | grep -qF "$APPEX"; then
        echo "install-wallpaper-extension: registered $EXTENSION_ID"
        echo "  $APPEX"
        # WallpaperAgent does not re-acquire the desktop from the new process
        # on its own — measured 2026-09-16: the extension was killed above, the
        # desktop went dark grey, and it stayed that way until Syd chose
        # another wallpaper and chose this one again. Restarted, the agent
        # comes straight back under launchd and re-acquires every surface from
        # the store, which is what `uninstall.sh` relies on too.
        killall WallpaperAgent 2>/dev/null && echo "install-wallpaper-extension: restarted WallpaperAgent" || true
        # A wallpaper with no library behind it fails the way a saver does, so
        # the same check runs here. Syd, 2026-09-15, of the saver's install.
        "$(dirname "${BASH_SOURCE[0]}")/ensure-photos-access.sh"
        exit 0
    fi
    [[ $((attempt % 5)) -eq 0 ]] && echo "install-wallpaper-extension: waiting for pkd, ${attempt}s"
    sleep 1
done

echo "install-wallpaper-extension: $EXTENSION_ID did not register from $APPEX after 30 seconds" >&2
echo "  pkd logs the reason: /usr/bin/log show --last 5m --predicate 'process == \"pkd\"'" >&2
exit 1
