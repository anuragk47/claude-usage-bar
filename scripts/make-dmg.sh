#!/bin/bash
# Builds a universal (Apple Silicon + Intel) "Claude Usage.app" and wraps it in a .dmg.
# Used by the GitHub release workflow; also works on any Mac with Xcode or the Command Line Tools.
#
#   scripts/make-dmg.sh [version]      e.g. scripts/make-dmg.sh 1.0.0
#
# Output: dist/ClaudeUsage.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
VERSION="${VERSION#v}"
NAME="Claude Usage"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

echo "Compiling for Apple Silicon and Intel…"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos13.0" Sources/*.swift -o "$WORK/ClaudeUsageBar-$arch"
done
lipo -create "$WORK/ClaudeUsageBar-arm64" "$WORK/ClaudeUsageBar-x86_64" -output "$APP/Contents/MacOS/ClaudeUsageBar"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$APP/Contents/Info.plist"

# Ad-hoc signature: enough for macOS to run it after "Open Anyway". A Developer ID
# signature plus notarization (Apple Developer Program) would remove that step.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Making the disk image…"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/ClaudeUsage.dmg"  # fixed name, so ".../releases/latest/download/ClaudeUsage.dmg" always works
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Created $DMG"
