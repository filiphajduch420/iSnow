#!/bin/zsh
# Builds Vločka.app (release, universal: Apple silicon + Intel), signs it ad hoc and optionally installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Vlocka"
APP="build/Vločka.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vlocka"
strip -x "$APP/Contents/MacOS/Vlocka"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
  rm -rf build/AppIcon.iconset
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Vlocka 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/Vločka.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/Vločka.app
  echo "Installed and launched: ~/Applications/Vločka.app"
fi
