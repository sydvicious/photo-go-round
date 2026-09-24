#!/bin/bash
#
# Builds a Release "Photos-Go-Round.app" that can be handed to another person:
# signed with Developer ID, notarized, stapled, and wrapped in a DMG that is
# signed, notarized and stapled in turn.
#
# Syd's to run, not an agent's: it builds the Release identity, and it uploads
# the build to Apple's notary service. It launches nothing and installs nothing.
#
# Needs, once per Mac:
#   - a Developer ID Application certificate for team R5PQPZARC5 in the login
#     keychain (Xcode -> Settings -> Accounts -> Manage Certificates), and
#   - notarytool credentials in the keychain:
#       xcrun notarytool store-credentials "pgr-notary" \
#           --apple-id "sydvicious@mac.com" --team-id "R5PQPZARC5"

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO/Photos-Go-Round.xcodeproj"
TEAM_ID="R5PQPZARC5"
# **Build artifacts never land in the repository.** Syd, 2026-09-19. See
# make-saver-bundle.sh and CLAUDE.md.
DERIVED_DATA="${PGR_BUILD_ROOT:-$HOME/Library/Developer/Xcode/DerivedData/Photos-Go-Round-scripts}"
BUILD_DIR="$DERIVED_DATA/release"
PROFILE="pgr-notary"
NOTARIZE=1

usage() {
    cat <<'HELPTEXT'
Builds a Developer ID signed, notarized Release of Photos-Go-Round in a DMG.

USAGE
  ./Scripts/release-build.sh [options]

OPTIONS
  --output <dir>              Where to build. Default:
                              ~/Library/Developer/Xcode/DerivedData/Photos-Go-Round-scripts/release
                              or $PGR_BUILD_ROOT/release. Never the repository.
  --keychain-profile <name>   The notarytool credentials to submit with.
                              Default: pgr-notary.
  --no-notarize               Sign and package, but upload nothing to Apple.
                              Gatekeeper refuses the result on any other Mac.
  -h, --help                  This.

NEEDS, ONCE PER MAC
  A Developer ID Application certificate for team R5PQPZARC5, and:

    xcrun notarytool store-credentials "pgr-notary" \
        --apple-id "sydvicious@mac.com" --team-id "R5PQPZARC5"

RESULT
  <output>/Photos-Go-Round-<version>.dmg, and the stapled app beside it in
  <output>/export. Launching the app installs and restarts its agent, as every
  build does.
HELPTEXT
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) BUILD_DIR="$2"; shift 2 ;;
        --keychain-profile) PROFILE="$2"; shift 2 ;;
        --no-notarize) NOTARIZE=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$BUILD_DIR" in
    "$REPO"|"$REPO"/*) echo "refusing to build inside the repository: $BUILD_DIR" >&2; exit 2 ;;
esac

IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\"/\1/p" | head -1)"
if [[ -z "$IDENTITY" ]]; then
    echo "no Developer ID Application certificate for team $TEAM_ID in the keychain." >&2
    echo "Create one in Xcode -> Settings -> Accounts -> Manage Certificates." >&2
    exit 1
fi

ARCHIVE="$BUILD_DIR/Photos-Go-Round.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/Photos-Go-Round.app"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$BUILD_DIR/dmg"
mkdir -p "$BUILD_DIR"

echo "==> Archiving Release"
xcodebuild archive -project "$PROJECT" -scheme "Photos-Go-Round" \
    -configuration Release -destination "generic/platform=macOS" \
    -derivedDataPath "$BUILD_DIR/DerivedData" -archivePath "$ARCHIVE" -quiet

echo "==> Exporting with Developer ID"
OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates -quiet

# Notarization refuses anything without the hardened runtime, and a hardened
# agent without the Photos entitlement finds no photographs. Check both here,
# where the answer is a line of output rather than a rejection from Apple or a
# blank desktop on somebody else's Mac.
echo "==> Checking signatures"
codesign --verify --deep --strict "$APP"
SERVER="$APP/Contents/Helpers/Photos-Go-Round Server.app"
for bundle in "$APP" "$SERVER" \
        "$APP/Contents/Library/Wallpaper/Photos-Go-Round Wallpaper.appex" \
        "$APP/Contents/Resources/Photos-Go-Round Screensaver.saver"; do
    info="$(codesign -dv "$bundle" 2>&1)"
    grep -q "Authority=Developer ID Application" <<<"$info" \
        || { echo "not signed with Developer ID: $bundle" >&2; exit 1; }
    grep -q "flags=.*runtime" <<<"$info" \
        || { echo "no hardened runtime: $bundle" >&2; exit 1; }
done
for bundle in "$APP" "$SERVER"; do
    codesign -d --entitlements - --xml "$bundle" 2>/dev/null \
        | grep -q "com.apple.security.personal-information.photos-library" \
        || { echo "no Photos entitlement: $bundle" >&2; exit 1; }
done

notarize() {
    local file="$1" result status id
    echo "==> Notarizing $(basename "$file")"
    result="$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" \
        --wait --output-format json)"
    status="$(plutil -extract status raw - <<<"$result")"
    id="$(plutil -extract id raw - <<<"$result")"
    if [[ "$status" != "Accepted" ]]; then
        echo "notarization $status for $(basename "$file"):" >&2
        xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
        exit 1
    fi
}

if [[ $NOTARIZE -eq 1 ]]; then
    ZIP="$BUILD_DIR/Photos-Go-Round.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    rm -f "$ZIP"
    xcrun stapler staple "$APP"
fi

VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
DMG="$BUILD_DIR/Photos-Go-Round-$VERSION.dmg"
echo "==> Packaging $(basename "$DMG")"
mkdir -p "$BUILD_DIR/dmg"
ditto "$APP" "$BUILD_DIR/dmg/Photos-Go-Round.app"
ln -s /Applications "$BUILD_DIR/dmg/Applications"
rm -f "$DMG"
hdiutil create -volname "Photos-Go-Round" -srcfolder "$BUILD_DIR/dmg" \
    -ov -format UDZO "$DMG" -quiet
rm -rf "$BUILD_DIR/dmg"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ $NOTARIZE -eq 1 ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    echo "==> Gatekeeper"
    spctl --assess --type execute -vv "$APP"
    spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi

echo "$DMG"
