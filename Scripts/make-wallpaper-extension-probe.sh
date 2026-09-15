#!/bin/bash
#
# Builds "Photo-Go-Round Wallpaper Probe.app": a host that does nothing, carrying
# one wallpaper extension. `Wallpaper Plan.md`, *The second probe*: the extension
# answers System Settings › Wallpaper with one Photo-Go-Round section holding one
# item, and draws a generated picture when that item is chosen. It asks the agent
# for nothing. *The extension probe* was the same bundle answering nothing.
#
# Phosphene's shape, not Apple's: the extension is sandboxed and carries no
# private entitlement, and the host is an unsandboxed LSUIElement app. See
# *Phosphene: a third-party extension in the pane*.
#
# swiftc and codesign rather than an Xcode target, so the project is untouched.
# This script only builds. Launching the host is what registers the extension,
# and putting an extension on a Mac is the owner's call, so the commands are
# printed rather than run.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$REPO/Scripts/wallpaper-extension-probe"
OUTPUT_DIR="$HOME/Library/Developer/Xcode/DerivedData/photo-go-round/wallpaper-extension-probe"
SIGN_IDENTITY="-"

usage() {
    cat <<'HELPTEXT'
Builds "Photo-Go-Round Wallpaper Probe.app" — the wallpaper extension probe.

USAGE
  ./Scripts/make-wallpaper-extension-probe.sh [options]

OPTIONS
  --sign <identity>   Codesign identity. Default "-" (ad-hoc). The probe is run
                      twice, once ad-hoc and once with a development identity.
                      List identities with: security find-identity -v -p codesigning
  --output <dir>      Where to build. Default:
                      ~/Library/Developer/Xcode/DerivedData/photo-go-round/wallpaper-extension-probe
  -h, --help          This.

AFTERWARDS
  The script prints the commands for each gate, with the built paths filled in.
HELPTEXT
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign) SIGN_IDENTITY="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

HOST_NAME="Photo-Go-Round Wallpaper Probe"
HOST_ID="com.sydpolk.photogoround.wallpaper-probe"
HOST_EXECUTABLE="WallpaperProbeHost"
EXTENSION_NAME="WallpaperProbeExtension"
EXTENSION_ID="$HOST_ID.extension"
EXTENSION_POINT="com.apple.wallpaper"
MINIMUM="27.0"
# Raised with each probe, so LaunchServices sees a new build and `WallpaperAgent`
# has a reason to ask again rather than reuse what it cached.
VERSION="0.2"
BUILD="2"
ARCH="$(uname -m)"

APP="$OUTPUT_DIR/$HOST_NAME.app"
APPEX="$APP/Contents/Extensions/$EXTENSION_NAME.appex"
WORK="$OUTPUT_DIR/work"

rm -rf "$APP" "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APPEX/Contents/MacOS" "$WORK"

# The module cache goes under the output too, so nothing lands in the checkout.
compile() {
    xcrun --sdk macosx swiftc -parse-as-library -O -swift-version 6 \
        -target "$ARCH-apple-macos$MINIMUM" \
        -module-cache-path "$WORK/module-cache" \
        "$@"
}

echo "compiling the host…"
compile "$SOURCES/Host.swift" -o "$APP/Contents/MacOS/$HOST_EXECUTABLE"
echo "compiling the extension…"
# What Xcode's app-extension product type sets and a bare swiftc does not:
# LD_ENTRY_POINT = _NSExtensionMain and APPLICATION_EXTENSION_API_ONLY = YES.
# The entry point matters. _NSExtensionMain hands over to ExtensionFoundation's
# _EXExtensionMain, which reads the launch arguments before the @main type
# runs; linked with an ordinary main, AppExtension.main() traps on arguments
# nobody read. Found 2026-09-14 from the probe's first crash report and a
# disassembly of ExtensionFoundation.
compile -application-extension \
    "$SOURCES/Extension.swift" "$SOURCES/PaneHandler.swift" "$SOURCES/PaneModels.swift" "$SOURCES/ProbePicture.swift" \
    -o "$APPEX/Contents/MacOS/$EXTENSION_NAME" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -Xlinker -application_extension

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$HOST_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$HOST_EXECUTABLE</string>
    <key>CFBundleIdentifier</key>
    <string>$HOST_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$HOST_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>$MINIMUM</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Photo-Go-Round Probe</string>
    <key>CFBundleExecutable</key>
    <string>$EXTENSION_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$EXTENSION_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$EXTENSION_NAME</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>$MINIMUM</string>
    <key>EXAppExtensionAttributes</key>
    <dict>
        <key>EXExtensionPointIdentifier</key>
        <string>$EXTENSION_POINT</string>
    </dict>
</dict>
</plist>
PLIST

cat > "$WORK/extension.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" "$APPEX/Contents/Info.plist" "$WORK/extension.entitlements" >/dev/null

# Inside out: the extension first, then the host that contains it.
echo "signing with identity: $SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
    --entitlements "$WORK/extension.entitlements" "$APPEX"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none "$APP"
codesign --verify --strict --deep "$APP"

echo
echo "  built  $APP"
echo "  signed $(codesign -dvv "$APP" 2>&1 | grep -E '^(Authority|Signature)=' | head -1)"
echo "  extension entitlements:"
codesign -d --entitlements - --xml "$APPEX" 2>/dev/null | plutil -p - | sed 's/^/    /'

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cat <<AFTER

  1. Put it somewhere stable and launch it once. Launching is what registers
     the extension; the host logs that it ran and quits.

       mkdir -p "\$HOME/Applications"
       rm -rf "\$HOME/Applications/$HOST_NAME.app"
       cp -R "$APP" "\$HOME/Applications/"
       open "\$HOME/Applications/$HOST_NAME.app"

  2. Check it is registered: twelve extensions, one of them $EXTENSION_ID.

       pluginkit -m -v -p $EXTENSION_POINT

  3. Gate 1, does System Settings › Wallpaper show a Photo-Go-Round section
     holding one item, Probe Picture? Gate 2, does choosing that item reach the
     extension? Open the pane, look, then choose it:

       open "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"

  4. Gate 3 is the desktop itself: does it show the blue-and-yellow probe
     picture? Then read what arrived, the probe's own lines first, then anything
     the system said about it:

       /usr/bin/log show --info --last 30m --predicate 'subsystem == "com.sydpolk.photogoround" AND category == "wallpaper-probe"'
       /usr/bin/log show --info --last 30m --predicate 'eventMessage CONTAINS "wallpaper-probe"'

  Remove it. WallpaperAgent reuses an extension process that is still running,
  suspended, even after a new build is registered, so stop it too, or the old
  code keeps answering:

       killall $EXTENSION_NAME
       "$LSREGISTER" -u "\$HOME/Applications/$HOST_NAME.app"
       rm -rf "\$HOME/Applications/$HOST_NAME.app"
AFTER
