#!/bin/zsh
# Renders the README screenshots and the snowplow GIF into media/ – no screen recording needed.
# iSnow draws a winter desktop, runs its real snow simulation on top and renders every settings tab and the
# welcome window. The 1.3 scenes: penguin, build, fight, newyear, advent (+ advent-tree), reindeer, christmas-eve, welcome.
# One scene only: ISNOW_PROMO_ONLY=penguin,welcome scripts/screenshots.sh (settings: add "settings").
# The language and region are set to English (UK) so the settings show "1.0×" and °C.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
"$(swift build -c release --show-bin-path)/iSnow" --promo media -AppleLanguages '(en)' -AppleLocale en_GB
if [[ -f media/hero.png ]]; then sips -Z 1800 media/hero.png >/dev/null; fi
for f in christmas christmas-eve slide frost fullscreen newyear advent; do
  if [[ -f "media/$f.png" ]]; then sips -Z 1600 "media/$f.png" >/dev/null; fi
done
echo "Screenshots in media/"
