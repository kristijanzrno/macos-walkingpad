#!/bin/bash
# Builds build/WalkingPad.app (universal, ad-hoc signed).
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  build, then copy to /Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
APP=build/WalkingPad.app

# One architecture at a time, then lipo: a multi-arch `swift build` hands off
# to Xcode's build system, whose sandbox can't nest inside Homebrew's.
# --disable-sandbox does the same for SwiftPM's own sandbox.
BINS=()
for ARCH in arm64 x86_64; do
  swift build -c release --arch "$ARCH" --disable-sandbox
  BINS+=("$(swift build -c release --arch "$ARCH" --show-bin-path)/WalkingPad")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/WalkingPad"
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
