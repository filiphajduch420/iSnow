#!/bin/zsh
# Renders the README screenshots into media/ – no screen recording needed.
# iSnow draws a winter desktop, runs its real snow simulation on top and renders the settings window.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
"$(swift build -c release --show-bin-path)/iSnow" --promo media
for f in hero christmas slide frost; do sips -Z 1800 "media/$f.png" >/dev/null; done
echo "Screenshots in media/"
