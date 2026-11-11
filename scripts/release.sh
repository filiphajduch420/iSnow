#!/bin/zsh
# Builds a release DMG of iSnow (universal: Apple silicon + Intel) and its SHA-256 checksum.
#   ./scripts/release.sh 1.0      →  dist/iSnow-v1.0.dmg + dist/iSnow-v1.0.dmg.sha256
# The app is signed ad hoc with the hardened runtime (no Developer ID), like other indie builds.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
NAME="iSnow"
DMG="${NAME}-v${VERSION}.dmg"

# Private temp dir, always cleaned up.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "Building ${NAME} ${VERSION}…"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${NAME}"

APP="${STAGING}/${NAME}.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${NAME}"
strip -x "$APP/Contents/MacOS/${NAME}"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
if [[ ! -f build/AppIcon.icns ]]; then
  mkdir -p build
  swift scripts/make-icon.swift build
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
  rm -rf build/AppIcon.iconset
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --sign - "$APP"
codesign --verify --verbose=2 "$APP"

# Drag-to-install DMG
ln -s /Applications "${STAGING}/Applications"
mkdir -p dist
rm -f "dist/${DMG}" "dist/${DMG}.sha256"
hdiutil create -volname "$NAME" -srcfolder "$STAGING" -ov -format UDZO "dist/${DMG}" >/dev/null

# Checksum (run from dist/ so `shasum -c` works next to the download)
(cd dist && shasum -a 256 "$DMG" | tee "${DMG}.sha256")
echo "Done: dist/${DMG} ($(du -h "dist/${DMG}" | cut -f1))"
