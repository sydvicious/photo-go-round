#!/bin/bash
#
# Assembles the Phase 1 spike as "Photo-Go-Round.saver".
#
# swiftc rather than an Xcode target, deliberately. The spike links nothing —
# not the display library, not the kit — because a stub that fails to load tells
# you nothing if it had four chances to fail. One file, two frameworks, and a
# plist is the whole of it, and it keeps the project file untouched until Phase 3
# knows what shape the real target wants.
#
# Three settings carry the entire risk of a Swift .saver, and all three are here
# rather than in code: the wrapper extension is .saver, NSPrincipalClass matches
# @objc(PGRScreenSaverView) exactly, and the linker emits a loadable bundle. Get
# any of them wrong and the saver silently does not appear in System Settings,
# with no error anywhere.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO/app/saver/Sources/PGRScreenSaverView.swift"
PLIST="$REPO/app/saver/Info.plist"
OUTPUT_DIR="$REPO/build"
SIGN_IDENTITY="-"
INSTALL=0

usage() {
    cat <<'HELPTEXT'
Assembles "Photo-Go-Round.saver" — the Phase 1 sandbox spike.

USAGE
  ./Scripts/make-saver-bundle.sh [options]

OPTIONS
  --output <dir>    Where to build. Default: ./build
  --sign <identity> Codesign identity. Default "-" (ad-hoc), which the host
                    accepts because it sets disable-library-validation.
  --install         Copy the result to ~/Library/Screen Savers and stop the
                    hosts holding the previous build.
  -h, --help        This.

AFTERWARDS
  Start an agent on the pinned port the spike asks for:

    ./Scripts/photogoroundd --port 9000

  Run the saver without waiting for an idle timer:

    open -a /System/Library/CoreServices/ScreenSaverEngine.app

  Read what it found:

    /usr/bin/log show --info --last 10m \
        --predicate 'subsystem == "com.sydpolk.photogoround" AND category == "saver"'
HELPTEXT
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --sign) SIGN_IDENTITY="$2"; shift 2 ;;
        --install) INSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

BUNDLE="$OUTPUT_DIR/Photo-Go-Round.saver"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$PLIST" "$BUNDLE/Contents/Info.plist"

# -bundle is what makes this loadable by another process rather than a dylib
# something links. The deployment target matches Package.swift's macOS floor so
# the spike runs on the same machines everything else does.
xcrun swiftc \
    -sdk "$SDK" \
    -target arm64-apple-macosx26.0 \
    -O \
    -module-name PhotoGoRoundSaver \
    -framework ScreenSaver \
    -framework AppKit \
    -Xlinker -bundle \
    -o "$BUNDLE/Contents/MacOS/PhotoGoRound" \
    "$SOURCE"

# Ad-hoc is enough because the host disables library validation, but a bundle
# assembled after the linker signed the binary has an invalid signature until
# this runs — and an invalid one does not load at all.
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$BUNDLE" >/dev/null 2>&1

echo "built $BUNDLE"

if [[ "$INSTALL" -eq 1 ]]; then
    DESTINATION="$HOME/Library/Screen Savers"
    mkdir -p "$DESTINATION"
    rm -rf "$DESTINATION/Photo-Go-Round.saver"
    cp -R "$BUNDLE" "$DESTINATION/"
    echo "installed to $DESTINATION"

    # Both hosts cache loaded bundles for the life of the process, and System
    # Settings caches the list it shows. Without this a rebuild runs the previous
    # build and looks like a change that did nothing.
    killall legacyScreenSaver 2>/dev/null || true
    killall ScreenSaverEngine 2>/dev/null || true
    echo "stopped the hosts holding the previous build"
fi
