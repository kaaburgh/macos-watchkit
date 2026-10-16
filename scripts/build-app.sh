#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo 'Building the menu bar app requires macOS and Xcode/Swift.' >&2
  exit 1
fi

swift build -c release --product MacOSWatchKit
BIN_DIR="$(swift build -c release --show-bin-path)"
DIST="$ROOT/.build/dist"
DEST="$DIST/macOS WatchKit.app"
mkdir -p "$DIST"
STAGING="$(mktemp -d "$DIST/.watchkit-stage.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
NEW="$STAGING/macOS WatchKit.app"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
# Sign a *new* inode instead of overwriting a binary possibly still executing.
cp "$BIN_DIR/MacOSWatchKit" "$NEW/Contents/MacOS/MacOSWatchKit"
cp "$ROOT/Resources/Info.plist" "$NEW/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$NEW"
# Replace only after staging and signing succeeded; stale bundle contents are removed.
rm -rf "$DEST"
mv "$NEW" "$DEST"

echo "Built: $DEST"
if [[ "${1:-}" == "--open" ]]; then
  echo "If an older instance is still running, quit it from the menu bar first."
  open "$DEST"
fi
