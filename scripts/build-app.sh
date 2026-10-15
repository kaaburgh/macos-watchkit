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
DEST="$ROOT/.build/dist/macOS WatchKit.app"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BIN_DIR/MacOSWatchKit" "$DEST/Contents/MacOS/MacOSWatchKit"
cp "$ROOT/Resources/Info.plist" "$DEST/Contents/Info.plist"

# Locally compiled executable; ad-hoc signing requires no credentials.
codesign --force --sign - --timestamp=none "$DEST"

echo "Built: $DEST"
if [[ "${1:-}" == "--open" ]]; then
  open "$DEST"
fi
