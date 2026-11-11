#!/bin/zsh
# Builds iSnow.app (release, universal: Apple silicon + Intel), signs it and optionally installs it to ~/Applications.
# Signing uses your "Apple Development" certificate when you have one – macOS then keeps the
# Accessibility permission across rebuilds. Without a certificate the app is signed ad hoc.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/iSnow"
APP="build/iSnow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iSnow"
strip -x "$APP/Contents/MacOS/iSnow"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
  rm -rf build/AppIcon.iconset
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Signed ad hoc (no Apple Development certificate found)"
fi
if [[ "${1:-}" == "--install" ]]; then
  pkill -x iSnow 2>/dev/null || true
  pkill -x Vlocka 2>/dev/null || true          # the app was called Vločka before
  rm -rf ~/Applications/Vločka.app
  mkdir -p ~/Applications
  rm -rf ~/Applications/iSnow.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/iSnow.app
  echo "Installed and launched: ~/Applications/iSnow.app"
fi
