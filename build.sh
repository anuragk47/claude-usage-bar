#!/bin/bash
# Builds Claude Usage and installs it to /Applications, replacing any earlier copy.
# Needs only Apple's Command Line Tools (run `xcode-select --install` once if swiftc is missing).
set -euo pipefail
cd "$(dirname "$0")"

NAME="Claude Usage"
BUNDLE_ID="com.anurag.claudeusagebar"
DEST="/Applications/$NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if ! command -v swiftc >/dev/null; then
  echo "swiftc not found. Run: xcode-select --install   (then re-run this script)"
  exit 1
fi

# Build in a temporary folder, so no extra copy of the app is left lying around
# for Launchpad and Spotlight to pick up.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/ClaudeUsageBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null

echo "Quitting the running copy…"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x ClaudeUsageBar >/dev/null || break
  sleep 0.3
done
pkill -x ClaudeUsageBar 2>/dev/null || true

echo "Installing…"
rm -rf "$DEST" "/Applications/Claude Usage Bar.app"
ditto "$APP" "$DEST"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

# One-time tidy-up: forget copies left by earlier builds (old build/ folders and the old name).
"$LSREGISTER" -dump 2>/dev/null \
  | sed -n 's/^path:[[:space:]]*\(.*\/Claude Usage\( Bar\)\{0,1\}\.app\).*/\1/p' \
  | sort -u \
  | while IFS= read -r old; do
      [ "$old" = "$DEST" ] && continue
      "$LSREGISTER" -u "$old" >/dev/null 2>&1 || true
      case "$old" in
        */build/*) rm -rf "$old" ;;  # leftovers from earlier versions of this script
      esac
    done
rm -rf build

open "$DEST"
echo "Installed to $DEST — look for the gauge in your menu bar."
