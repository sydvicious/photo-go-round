#!/bin/bash
#
# Takes Photos-Go-Round off this Mac. `Build Plan.md`, *The install phases*.
#
# Syd, 2026-09-15: "we need an uninstall script for all of these agents". Three
# installs put things in three places — a LaunchAgent, a plug-in registration and
# a bundle in Screen Savers — and the one you forget is the one that keeps
# running. Three build configurations mean three of each.
#
# **It is a wrapper, not an implementation.** Syd, 2026-09-19: "there should not
# be multiple versions of the build scripts. the targets and the command line
# builds should share their guts, and behave the same, based on input
# parameters." Everything this does lives in `PhotosGoRoundInstall` and is driven
# by `pgr_install uninstall`, which is the same code `Install …` schemes run and
# the same code the app will link when it becomes the installer.
#
# **It removes what was installed, not what was built.** Build directories, the
# library, the cache and the preferences are left alone: uninstalling is not the
# same as throwing away the photographs you chose. `Scripts/scrub-dev.sh` is the
# one that clears the retired development libraries' leftovers.
#
# **Nothing here needs the checkout that installed it.** Everything is found by
# label, identifier and name — so it removes a Release install as readily as a
# Debug one, whoever built them.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO/Photos-Go-Round.xcodeproj"
DERIVED_DATA="${PGR_BUILD_ROOT:-$HOME/Library/Developer/Xcode/DerivedData/Photos-Go-Round-scripts}/uninstall"

usage() {
    cat <<'HELPTEXT'
Removes what Photos-Go-Round's installs put on this Mac.

USAGE
  ./Scripts/uninstall.sh [--agent] [--wallpaper] [--saver] [--dry-run]

  With none of the three, it removes all of them. Every build configuration's
  copy is found — release, Debug and Claude — not just the one you last built.

WHAT EACH ONE REMOVES
  --agent       Boots out every LaunchAgent and deletes its plist from
                ~/Library/LaunchAgents. An agent somebody started by hand is
                reported and left alone. The built bundles stay where they are.
  --wallpaper   Unregisters every copy of the wallpaper extension and stops the
                extension processes. If it is the chosen wallpaper, macOS falls
                back to a default picture.
  --saver       Deletes every Photos-Go-Round Screensaver bundle from
                ~/Library/Screen Savers and stops the hosts holding them.
  --dry-run     Says what would go and removes nothing.

WHAT IT NEVER TOUCHES
  The library, the cache, preferences, and anything under a build directory. See
  Scripts/scrub-dev.sh for the retired development libraries' leftovers.
HELPTEXT
}

for argument in "$@"; do
    case "$argument" in
        --agent|--wallpaper|--saver|--dry-run) ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $argument" >&2; usage >&2; exit 2 ;;
    esac
done

# Built rather than assumed present: this script is run from a checkout, and the
# binary it drives is one of that checkout's products.
# Silent when it works, and the whole log when it does not. xcodebuild warns
# about matching several macOS destinations whatever is asked for, and that
# warning is noise in front of an uninstall.
if ! build_log="$(xcodebuild build \
    -project "$PROJECT" \
    -scheme pgr_install \
    -destination "generic/platform=macOS" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" 2>&1)"; then
    echo "$build_log" >&2
    echo "uninstall: could not build pgr_install; nothing was removed" >&2
    exit 1
fi

exec "$DERIVED_DATA/Build/Products/Debug/pgr_install" uninstall "$@"
