#!/bin/zsh
# Builds a release DMG of iSnow (universal: Apple silicon + Intel) and its SHA-256 checksum,
# then updates the download section of README.md (version and checksum).
#   ./scripts/release.sh 1.1   →  dist/iSnow-v1.1.dmg + .dmg.sha256 + .dmg.sig (Ed25519, for the in-app updater)
# The app is signed ad hoc with the hardened runtime (no Developer ID), like other indie builds.
# Works with full Xcode or with just the Xcode Command Line Tools (see build.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>   (e.g. 1.1)}"
if [[ ! "$VERSION" =~ '^[0-9]+(\.[0-9]+)*$' ]]; then
  echo "error: version must look like 1.1 or 1.1.2, got '$VERSION'" >&2
  exit 64
fi
NAME="iSnow"
DMG="${NAME}-v${VERSION}.dmg"

# The in-app updater only installs DMGs signed with the update key (scripts/sign-update.swift).
# Check it before building: the key must be in the login Keychain and match the one built into the app.
if ! PUBKEY="$(swift scripts/sign-update.swift pubkey)"; then
  echo "error: the update signing key is missing – create it once with: swift scripts/sign-update.swift keygen" >&2
  exit 1
fi
if ! grep -qF "\"${PUBKEY}\"" Sources/iSnow/Updates.swift; then
  echo "error: the signing key in the Keychain does not match UpdateFeed.publicKey in Sources/iSnow/Updates.swift" >&2
  exit 1
fi

# Private temp dir, always cleaned up.
STAGING="$(mktemp -d)"
BEFORE="$(mktemp)"                # README.md before the update, for the printed diff
trap 'rm -rf "$STAGING" "$BEFORE"' EXIT

echo "Building ${NAME} ${VERSION}…"
./build.sh --no-sign            # universal build/iSnow.app, icon regenerated when needed

APP="${STAGING}/${NAME}.app"
cp -R "build/${NAME}.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$APP/Contents/Info.plist"

codesign --force --options runtime --sign - "$APP"
codesign --verify --verbose=2 "$APP"

# Drag-to-install DMG
ln -s /Applications "${STAGING}/Applications"
mkdir -p dist
rm -f "dist/${DMG}" "dist/${DMG}.sha256" "dist/${DMG}.sig"
hdiutil create -volname "$NAME" -srcfolder "$STAGING" -ov -format UDZO "dist/${DMG}" >/dev/null

# Checksum (run from dist/ so `shasum -c` works next to the download)
(cd dist && shasum -a 256 "$DMG" > "${DMG}.sha256")
SHA="$(cut -d' ' -f1 "dist/${DMG}.sha256")"
cat "dist/${DMG}.sha256"

# Ed25519 signature for the in-app updater (dist/iSnow-v<ver>.dmg.sig)
if ! swift scripts/sign-update.swift sign "dist/${DMG}"; then
  echo "error: signing dist/${DMG} failed – the in-app updater would reject this release" >&2
  exit 1
fi
swift scripts/sign-update.swift verify "dist/${DMG}"
echo "Done: dist/${DMG} ($(du -h "dist/${DMG}" | cut -f1))"
echo "Upload all three files to the GitHub release: ${DMG}, ${DMG}.sha256 and ${DMG}.sig"
echo "(without the .sig, the app can only offer the download page instead of updating itself)"

# README: the checksum lives between <!-- sha256 --> and <!-- /sha256 -->; the DMG name and
# "Current version" are updated wherever they appear. hdiutil output is not reproducible,
# so every run changes the checksum.
if ! grep -q '<!-- sha256 -->' README.md || ! grep -q '<!-- /sha256 -->' README.md; then
  echo "warning: README.md has no <!-- sha256 --> … <!-- /sha256 --> markers – update the checksum by hand: $SHA" >&2
  exit 0
fi
cp README.md "$BEFORE"
ISNOW_VERSION="$VERSION" ISNOW_SHA="$SHA" perl -0pi -e '
  my ($v, $sha) = ($ENV{ISNOW_VERSION}, $ENV{ISNOW_SHA});
  s{(<!-- sha256 -->.*?)[0-9a-f]{64}(.*?<!-- /sha256 -->)}{$1$sha$2}s;
  s{iSnow-v[0-9][0-9.]*?\.dmg}{iSnow-v$v.dmg}g;
  s{(\*\*Current version: )[0-9][0-9.]*(\*\*)}{$1$v$2}g;
' README.md
grep -q "$SHA" README.md || echo "warning: no 64-character checksum between the README markers – paste it by hand: $SHA" >&2
if cmp -s "$BEFORE" README.md; then
  echo "README.md already up to date."
else
  echo "Updated README.md:"
  diff -U0 "$BEFORE" README.md | grep -E '^[-+][^-+]' || true
fi
