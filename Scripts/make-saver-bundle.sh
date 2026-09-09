#!/bin/bash
#
# Builds and installs "Photo-Go-Round.saver" — the Mac screensaver.
#
# The bundle is an Xcode target now, so this drives xcodebuild rather than
# assembling anything itself. Xcode builds, because that is where the thing can
# be debugged; this script deploys, because Xcode has no idea about
# ~/Library/Screen Savers or about the two caches that have to be cleared before
# a rebuild is the thing that actually runs.
#
# --spike builds the Phase 1 probe instead, which links nothing at all and still
# answers "is the sandbox letting us out" on a macOS release that changes the
# host's entitlements under us.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO/app/Photo-Go-Round.xcodeproj"
BUILD_DIR="$REPO/build/xcode"
CONFIGURATION="Debug"
INSTALL=0
SPIKE=0

usage() {
    cat <<'HELPTEXT'
Builds "Photo-Go-Round.saver" — the Mac screensaver.

USAGE
  ./Scripts/make-saver-bundle.sh [options]

OPTIONS
  --spike           Build the sandbox probe instead: "Photo-Go-Round Spike.saver".
  --output <dir>    Where to build. Default: ./build/xcode. Point it outside the
                    checkout to leave nothing behind in it.
  --release         Build the Release configuration instead of Debug.
  --install         Copy the result to ~/Library/Screen Savers and stop the
                    hosts holding the previous build.
  -h, --help        This.

AFTERWARDS
  The saver is a client and needs the agent running:

    ./Scripts/photogoroundd

  Choose it in System Settings, under Screen Saver -> Other. Nothing loads a
  saver that is not selected, and an unselected one looks exactly like one that
  failed to load - an empty log and no error anywhere:

    open "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension"

  Run it without waiting for an idle timer:

    open -a /System/Library/CoreServices/ScreenSaverEngine.app

  Watch what it did:

    /usr/bin/log show --info --last 10m \
        --predicate 'subsystem == "com.sydpolk.photogoround" AND category == "saver"'
HELPTEXT
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --spike) SPIKE=1; shift ;;
        --output) BUILD_DIR="$2"; shift 2 ;;
        --release) CONFIGURATION="Release"; shift ;;
        --install) INSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "$SPIKE" -eq 1 ]]; then
    TARGET="Photo-Go-Round Saver Spike"
    NAME="Photo-Go-Round Spike"
else
    TARGET="Photo-Go-Round Saver"
    NAME="Photo-Go-Round"
fi

xcodebuild build \
    -project "$PROJECT" \
    -target "$TARGET" \
    -configuration "$CONFIGURATION" \
    SYMROOT="$BUILD_DIR/Products" \
    OBJROOT="$BUILD_DIR/Intermediates.noindex" \
    >/dev/null

BUNDLE="$BUILD_DIR/Products/$CONFIGURATION/$NAME.saver"
[[ -d "$BUNDLE" ]] || { echo "expected a bundle at $BUNDLE and there is none" >&2; exit 1; }
echo "built $BUNDLE"

if [[ "$INSTALL" -eq 1 ]]; then
    DESTINATION="$HOME/Library/Screen Savers"
    mkdir -p "$DESTINATION"
    rm -rf "$DESTINATION/$NAME.saver"
    cp -R "$BUNDLE" "$DESTINATION/"
    echo "installed to $DESTINATION"

    # Both hosts cache loaded bundles for the life of the process, and System
    # Settings caches the list it shows. Without this a rebuild runs the previous
    # build and looks like a change that did nothing.
    killall legacyScreenSaver 2>/dev/null || true
    killall ScreenSaverEngine 2>/dev/null || true
    echo "stopped the hosts holding the previous build"
fi
