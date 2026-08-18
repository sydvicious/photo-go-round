#!/bin/bash
#
# Assembles the headless agent as an LSUIElement app bundle.
#
# A bundle rather than a bare executable matters for more than tidiness. TCC
# keys its grants to a bundle identifier and a code signature, so the Photos
# prompt and the Files-and-Folders grant need one.
#
# For 0.1 the agent is installed as a plain LaunchAgent with launchctl. The
# bundle still carries a LaunchAgents plist for SMAppService, which is the
# mechanism 1.0 wants because it removes the installer and puts the agent in
# System Settings → Login Items — but it reports .notFound when the executable
# is run directly rather than launched as an app, so it waits for Phase 3 to
# provide a real app to register from.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="release"
CONTAINER=""
SIGN_IDENTITY="-"
OUTPUT_DIR="$REPO/build"
INSTALL_TO=""

usage() {
    cat <<'HELPTEXT'
Assembles "Photo-Go-Round Server.app" — the headless agent.

USAGE
  ./Scripts/make-agent-bundle.sh [options]

OPTIONS
  --container <dir>   Bake a storage root into the launchd plist, so the agent
                      writes there no matter how it is started. Omit to let it
                      resolve the App Group container, then Application Support.
  --debug             Build the debug configuration instead of release.
  --sign <identity>   Codesign identity. Default "-" (ad-hoc), which is fine for
                      a machine-local build. Use a Developer ID for anything you
                      intend to keep across updates, because TCC grants are
                      recorded against the signature.
  --output <dir>      Where to build the bundle. Default: ./build
  --install-to <dir>  Copy the finished bundle here and point the LaunchAgent at
                      that copy. Use this for anything you intend to leave
                      running: a login item pointing into a git working tree
                      breaks the moment you rebuild or move the checkout.
                      Suggestion: ~/Applications
  -h, --help          This

AFTERWARDS
  The script prints the two launchctl commands to install the agent. It does not
  run them — putting a login item on a Mac is the owner's call, not a build
  script's.
HELPTEXT
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container) CONTAINER="$2"; shift 2 ;;
        --debug) CONFIGURATION="debug"; shift ;;
        --sign) SIGN_IDENTITY="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --install-to) INSTALL_TO="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option $1" >&2; usage; exit 1 ;;
    esac
done

BUNDLE_NAME="Photo-Go-Round Server"
BUNDLE_ID="com.sydpolk.photogoround.server"
EXECUTABLE="photogoroundd"
BUNDLE="$OUTPUT_DIR/$BUNDLE_NAME.app"

echo "building $CONFIGURATION…"
swift build --configuration "$CONFIGURATION" --package-path "$REPO" >/dev/null
BIN_PATH="$(swift build --configuration "$CONFIGURATION" --package-path "$REPO" --show-bin-path)"

echo "assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Library/LaunchAgents"
cp "$BIN_PATH/$EXECUTABLE" "$BUNDLE/Contents/MacOS/$EXECUTABLE"

VERSION="$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null || echo "0.1")"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$BUNDLE_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$BUNDLE_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <!-- No Dock icon and no menu bar presence. The agent is headless; a menu
         bar item appears later, and only when something needs attention. -->
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <!-- Only the server ever touches files or the Photos library, so every
         privacy grant lives on this one bundle and the user consents once. -->
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Photo-Go-Round reads your photo library so it can shuffle your photos onto your desktop and screensaver. Nothing is ever uploaded or shared.</string>
</dict>
</plist>
PLIST

# BundleProgram is resolved relative to the containing bundle, so the agent
# keeps working if the bundle is moved — which a hardcoded absolute path in
# Program would not.
ENVIRONMENT_BLOCK=""
if [[ -n "$CONTAINER" ]]; then
    ENVIRONMENT_BLOCK="
    <key>EnvironmentVariables</key>
    <dict>
        <key>PGR_CONTAINER</key>
        <string>$CONTAINER</string>
    </dict>"
    echo "baking storage root: $CONTAINER"
fi

cat > "$BUNDLE/Contents/Library/LaunchAgents/$BUNDLE_ID.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/$EXECUTABLE</string>
    <key>ProgramArguments</key>
    <array>
        <string>Contents/MacOS/$EXECUTABLE</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Restart on crash, but not on a clean exit: SuccessfulExit false means
         launchd leaves it alone when it chooses to stop. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>$ENVIRONMENT_BLOCK
</dict>
</plist>
PLIST

echo "signing with identity: $SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$BUNDLE" >/dev/null 2>&1 \
    || codesign --force --sign "$SIGN_IDENTITY" "$BUNDLE"

# Move the bundle somewhere stable before writing the plist, so the LaunchAgent
# never points at a build directory.
if [[ -n "$INSTALL_TO" ]]; then
    mkdir -p "$INSTALL_TO"
    INSTALLED="$INSTALL_TO/$BUNDLE_NAME.app"
    rm -rf "$INSTALLED"
    cp -R "$BUNDLE" "$INSTALLED"
    BUNDLE="$INSTALLED"
    echo "installed to $BUNDLE"
fi

# The 0.1 installation path: one plist and two launchctl commands. Emitted
# rather than installed, because putting a login item on someone's Mac is their
# decision to make.
ABSOLUTE_EXECUTABLE="$(cd "$BUNDLE/Contents/MacOS" && pwd)/$EXECUTABLE"
STANDALONE="$OUTPUT_DIR/$BUNDLE_ID.plist"

STANDALONE_ENVIRONMENT=""
if [[ -n "$CONTAINER" ]]; then
    STANDALONE_ENVIRONMENT="
    <key>EnvironmentVariables</key>
    <dict>
        <key>PGR_CONTAINER</key>
        <string>$CONTAINER</string>
    </dict>"
fi

cat > "$STANDALONE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$ABSOLUTE_EXECUTABLE</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>/tmp/$BUNDLE_ID.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/$BUNDLE_ID.log</string>$STANDALONE_ENVIRONMENT
</dict>
</plist>
PLIST

plutil -lint "$STANDALONE" >/dev/null

echo
echo "  built  $BUNDLE"
if [[ -z "$INSTALL_TO" ]]; then
    echo
    echo "  NOTE: the LaunchAgent points into the build directory. Rebuilding is"
    echo "        fine, but moving or deleting the checkout will break it. Use"
    echo "        --install-to ~/Applications for anything you leave running."
fi
echo
echo "  install:"
echo "    cp \"$STANDALONE\" ~/Library/LaunchAgents/"
echo "    launchctl bootstrap gui/\$UID ~/Library/LaunchAgents/$BUNDLE_ID.plist"
echo
echo "  watch it:"
echo "    tail -f /tmp/$BUNDLE_ID.log"
echo "    launchctl print gui/\$UID/$BUNDLE_ID | head -20"
echo
echo "  stop it:"
echo "    launchctl bootout gui/\$UID/$BUNDLE_ID"
echo
echo "  add a folder (while stopped, or just edit the plist's ProgramArguments):"
echo "    \"$BUNDLE/Contents/MacOS/$EXECUTABLE\" --once --add-folder ~/Pictures/YourFolder -r"
echo
