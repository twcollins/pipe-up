#!/usr/bin/env bash
# Builds Pipe Up.app with the Xcode command line tools (no Xcode project needed).
#   ./build.sh            -> build/Pipe Up.app
#   ./build.sh --install  -> also copies it to /Applications and launches it
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Pipe Up.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  -o "$APP/Contents/MacOS/PipeUp" \
  Sources/*.swift

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x PipeUp 2>/dev/null || true
  # Remove the app's old name (Mic Helper) if present.
  pkill -x MicHelper 2>/dev/null || true
  rm -rf "/Applications/Mic Helper.app"
  rm -rf "/Applications/Pipe Up.app"
  cp -R "$APP" /Applications/
  open "/Applications/Pipe Up.app"
  echo "Installed to /Applications and launched — look for the mic icon in your menu bar."
fi
