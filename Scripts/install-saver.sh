#!/bin/bash
#
# Installs the screensaver for development. `Build Plan.md`, *The install phases*.
#
# Called by the `Install Screen Saver` target, and usable by hand with one
# argument: the path to the built `Photo-Go-Round Screensaver.saver`.
#
# It does what `Scripts/make-saver-bundle.sh --install` has always done, in the
# place the other installs now live. That script keeps its own copy of these
# steps because it is also the route for a machine with no Xcode project open.
#
# **The hosts have to be stopped.** `legacyScreenSaver` and `ScreenSaverEngine`
# cache a loaded bundle for the life of the process, and System Settings caches
# the list it shows. Without the kill, a rebuild runs the previous build and looks
# exactly like a change that did nothing — which cost a debugging round once
# already.
#
# **It replaces only our own bundle**, by name, in the user's own Screen Savers
# folder. Nothing else there is touched.

set -euo pipefail

NAME="Photo-Go-Round Screensaver"
DESTINATION="$HOME/Library/Screen Savers"

SAVER="${1:-${BUILT_PRODUCTS_DIR:-}/$NAME.saver}"

if [[ ! -d "$SAVER" ]]; then
    echo "install-saver: no bundle at $SAVER" >&2
    exit 1
fi

mkdir -p "$DESTINATION"
rm -rf "$DESTINATION/$NAME.saver"
cp -R "$SAVER" "$DESTINATION/"

if [[ ! -d "$DESTINATION/$NAME.saver" ]]; then
    echo "install-saver: the copy did not arrive in $DESTINATION" >&2
    exit 1
fi

echo "install-saver: installed $NAME.saver"
echo "  $DESTINATION/$NAME.saver"

# Stopping a screensaver host is not the same as stopping something the owner
# started: these are macOS's, they restart on demand, and holding the old build
# is the whole problem.
if killall legacyScreenSaver 2>/dev/null; then
    echo "install-saver: stopped legacyScreenSaver, which was holding a previous build"
fi
if killall ScreenSaverEngine 2>/dev/null; then
    echo "install-saver: stopped ScreenSaverEngine"
fi

# A saver with no photographs behind it looks broken in exactly the way a saver
# with no access looks broken. Syd, 2026-09-15: the install "also needs to make
# sure the agent has photos access".
"$(dirname "${BASH_SOURCE[0]}")/ensure-photos-access.sh"
