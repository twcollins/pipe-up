#!/usr/bin/env bash
# Builds Mic Helper.app with the Xcode command line tools (no Xcode project needed).
#   ./build.sh            -> build/Mic Helper.app
#   ./build.sh --install  -> also copies it to /Applications and launches it
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Mic Helper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  -o "$APP/Contents/MacOS/MicHelper" \
  Sources/*.swift

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x MicHelper 2>/dev/null || true
  rm -rf "/Applications/Mic Helper.app"
  cp -R "$APP" /Applications/
  open "/Applications/Mic Helper.app"
  echo "Installed to /Applications and launched — look for the mic icon in your menu bar."
fi
