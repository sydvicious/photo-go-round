#!/bin/bash
#
# Builds and installs "Photos-Go-Round Screensaver.saver" — the Mac screensaver.
#
# The bundle is an Xcode target now, so this drives xcodebuild rather than
# assembling anything itself. Xcode builds, because that is where the thing can
# be debugged; this script deploys, because Xcode has no idea about
# ~/Library/Screen Savers or about the two caches that have to be cleared before
# a rebuild is the thing that actually runs.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO/Photos-Go-Round.xcodeproj"
# **Build artifacts never land in the repository.** Syd, 2026-09-19: "I really
# don't want build artifacts in the repo directory", and "I would prefer ALL
# generated artifacts to be in DerivedData and not .build directories". Override
# with --output; an agent building on Syd's Mac points it at its own directory,
# per CLAUDE.md.
DERIVED_DATA="${PGR_BUILD_ROOT:-$HOME/Library/Developer/Xcode/DerivedData/Photos-Go-Round-scripts}"
BUILD_DIR="$DERIVED_DATA/saver"
CONFIGURATION="Debug"
INSTALL=0

usage() {
    cat <<'HELPTEXT'
Builds "Photos-Go-Round Screensaver.saver" — the Mac screensaver.

USAGE
  ./Scripts/make-saver-bundle.sh [options]

OPTIONS
  --output <dir>    Where to build. Default:
                    ~/Library/Developer/Xcode/DerivedData/Photos-Go-Round-scripts/saver
                    or $PGR_BUILD_ROOT/saver. Never the repository.
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
        --predicate 'subsystem == "com.sydpolk.photosgoround" AND category == "saver"'
HELPTEXT
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) BUILD_DIR="$2"; shift 2 ;;
        --release) CONFIGURATION="Release"; shift ;;
        --install) INSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

SCHEME="Photos-Go-Round Saver"

# By scheme, not -target: a -target build gives the local package targets a
# "Conditional compilation flags do not have values in Swift" warning that a
# scheme build, which is how Xcode itself builds, does not. Measured 2026-09-15.
# xcodebuild makes a scheme for every target on its own.
#
# arm64 alone, because "platform=macOS" matches this Mac twice on macOS 27 —
# once per architecture — so xcodebuild warns and builds both. Syd, 2026-09-15:
# "there is a difference between dev and shipping the product… for dev purposes,
# I don't want to waste the time or disk space." A shipping build is where
# Intel is decided, not here.
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=macOS,arch=arm64" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR" \
    >/dev/null

# **One implementation of installing, not two.** Syd, 2026-09-19: "there should
# not be multiple versions of the build scripts. the targets and the command
# line builds should share their guts, and behave the same, based on input
# parameters." This script kept its own copy of the copy-and-kill-the-hosts
# steps until then, on the grounds that it was the route for a machine with no
# Xcode project open — which stopped being a reason once the install became a
# binary, because a binary runs anywhere. `Plans/Xcode - Separate Build and
# Run.md`, Phase 5.
if [[ "$INSTALL" -eq 1 ]]; then
    xcodebuild build \
        -project "$PROJECT" \
        -scheme pgr_install \
        -destination "platform=macOS,arch=arm64" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$BUILD_DIR" \
        >/dev/null
fi

# **The name comes from what was built, not from a constant.** Each
# configuration produces a differently named bundle — "Photos-Go-Round
# Screensaver.saver" for Release, " (Debug)" and " (Claude)" for the other two —
# so a hard-coded name would miss the build and, on install, remove another
# configuration's saver. `BuildVariant.swift`.
PRODUCTS="$BUILD_DIR/Build/Products/$CONFIGURATION"
BUNDLE="$(find "$PRODUCTS" -maxdepth 1 -name "Photos-Go-Round Screensaver*.saver" 2>/dev/null | head -1)"
[[ -n "$BUNDLE" && -d "$BUNDLE" ]] \
    || { echo "expected a Photos-Go-Round Screensaver bundle in $PRODUCTS and there is none" >&2; exit 1; }
NAME="$(basename "$BUNDLE" .saver)"
echo "built $BUNDLE"

if [[ "$INSTALL" -eq 1 ]]; then
    "$PRODUCTS/pgr_install" saver --from "$BUNDLE"
fi
