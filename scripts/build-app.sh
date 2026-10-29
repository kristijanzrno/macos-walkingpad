#!/bin/bash
# Builds build/WalkingPad.app (universal, ad-hoc signed).
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  build, then copy to /Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
APP=build/WalkingPad.app

# --disable-sandbox: SwiftPM's own sandbox can't nest inside Homebrew's.
swift build -c release --arch arm64 --arch x86_64 --disable-sandbox
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/WalkingPad

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WalkingPad"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x WalkingPad || true
  rm -rf /Applications/WalkingPad.app
  cp -R "$APP" /Applications/
  open /Applications/WalkingPad.app
  echo "Installed /Applications/WalkingPad.app"
fi
