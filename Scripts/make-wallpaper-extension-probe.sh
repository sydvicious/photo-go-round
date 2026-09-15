#!/bin/bash
#
# Builds "Photo-Go-Round Wallpaper Probe.app": a host that does nothing, carrying
# one wallpaper extension. `Wallpaper Plan.md`, *The second probe*: the extension
# answers System Settings › Wallpaper with one Photo-Go-Round section holding one
# item, and draws a generated picture when that item is chosen. It asks the agent
# for nothing. *The extension probe* was the same bundle answering nothing; *The
# third probe* adds a snapshot of the picture, for the export WallpaperAgent makes;
# *The fourth probe* asks the agent for a photograph, which needs the network and
# read-only preference exceptions in the extension's entitlements.
#
# Phosphene's shape, not Apple's: the extension is sandboxed and carries no
# private entitlement, and the host is an unsandboxed LSUIElement app. See
# *Phosphene: a third-party extension in the pane*.
#
# swiftc and codesign rather than an Xcode target, so the project is untouched.
# After building, it replaces the installed copy in ~/Applications and registers
# it, and stops there: choosing the wallpaper in System Settings is Syd's. Syd,
# 2026-09-15: "there is no reason that the build script should not do everything
# until I have to open the settings panel." --build-only skips the install, for
# builds nobody is about to run. The steps after it are in
# Documentation/Wallpaper Extension Probe.md.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$REPO/Scripts/wallpaper-extension-probe"
OUTPUT_DIR="$HOME/Library/Developer/Xcode/DerivedData/photo-go-round/wallpaper-extension-probe"
# Syd's development identity, 2026-09-15: "This is unlikely to change anytime
# soon." --sign - for an ad-hoc build.
SIGN_IDENTITY="Apple Development: Sydney Polk (W8E4GRMLBV)"
BUILD_ONLY=0

usage() {
    cat <<'HELPTEXT'
Builds "Photo-Go-Round Wallpaper Probe.app" — the wallpaper extension probe.

USAGE
  ./Scripts/make-wallpaper-extension-probe.sh [options]

OPTIONS
  --sign <identity>   Codesign identity. Default "Apple Development: Sydney Polk
                      (W8E4GRMLBV)"; "-" for ad-hoc.
                      List identities with: security find-identity -v -p codesigning
  --output <dir>      Where to build. Default:
                      ~/Library/Developer/Xcode/DerivedData/photo-go-round/wallpaper-extension-probe
  --build-only        Build and sign, and install nothing.
  -h, --help          This.

AFTERWARDS
  Unless --build-only, the probe is installed in ~/Applications and registered.
  Then open System Settings › Wallpaper: Documentation/Wallpaper Extension Probe.md.
HELPTEXT
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign) SIGN_IDENTITY="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --build-only) BUILD_ONLY=1; shift ;;
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
VERSION="0.4"
BUILD="6"
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
    "$SOURCES/Extension.swift" "$SOURCES/PaneHandler.swift" "$SOURCES/PaneModels.swift" "$SOURCES/ProbePicture.swift" "$SOURCES/AgentPicture.swift" \
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
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.temporary-exception.shared-preference.read-only</key>
    <array>
        <string>com.sydpolk.photogoround.dev</string>
        <string>com.sydpolk.photogoround</string>
    </array>
    <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
    <array>
        <string>/Library/Preferences/com.sydpolk.photogoround.dev.plist</string>
        <string>/Library/Preferences/com.sydpolk.photogoround.plist</string>
    </array>
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

if [[ "$BUILD_ONLY" -eq 1 ]]; then
    echo
    echo "  not installed (--build-only)"
    exit 0
fi

# Replace the installed copy, and register the new one. WallpaperAgent keeps
# using an extension process that is still running, even after a new build is
# registered, so that process goes first.
INSTALLED="$HOME/Applications/$HOST_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
echo
echo "installing to $INSTALLED"
if killall "$EXTENSION_NAME" 2>/dev/null; then
    echo "  stopped the running extension"
else
    echo "  no extension was running"
fi
if [[ -d "$INSTALLED" ]]; then
    "$LSREGISTER" -u "$INSTALLED"
    rm -rf "$INSTALLED"
fi
mkdir -p "$HOME/Applications"
cp -R "$APP" "$HOME/Applications/"
# Opening the host is what registers the extension. It quits by itself.
open "$INSTALLED"

# Registration takes a moment. Fail loudly rather than leave an older build
# answering.
registered=""
for _ in $(seq 1 15); do
    registered="$(pluginkit -m -v -p "$EXTENSION_POINT" | grep -F "$EXTENSION_ID($VERSION)" || true)"
    [[ -n "$registered" ]] && break
    sleep 1
done
if [[ -z "$registered" ]]; then
    echo "  $EXTENSION_ID $VERSION was not registered after 15 seconds" >&2
    exit 1
fi
echo "  registered $EXTENSION_ID $VERSION"
echo
echo "  next: open System Settings › Wallpaper. Documentation/Wallpaper Extension Probe.md"
