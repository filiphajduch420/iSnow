#!/bin/zsh
# Renders the README screenshots and the snowplow GIF into media/ – no screen recording needed.
# iSnow draws a winter desktop, runs its real snow simulation on top and renders every settings tab.
# The language and region are set to English (UK) so the settings show "1.0×" and °C.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
"$(swift build -c release --show-bin-path)/iSnow" --promo media -AppleLanguages '(en)' -AppleLocale en_GB
sips -Z 1800 media/hero.png >/dev/null
for f in christmas slide frost fullscreen; do sips -Z 1600 "media/$f.png" >/dev/null; done
echo "Screenshots in media/"
