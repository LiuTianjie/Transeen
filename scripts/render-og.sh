#!/bin/zsh
# Renders each language's share card (docs/assets/og-image<suffix>.jpg) and screenshot
# (docs/assets/preview<suffix>.webp) from the live demo in scripts/site/og.html. English has no
# suffix and Simplified Chinese is -zh, the names the READMEs use.
set -euo pipefail
cd "${0:A:h:h}"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
out=build/website-preview
mkdir -p "$out"
python3 -I scripts/site/build.py

shoot() {
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor="$1" --window-size="$2" \
    --virtual-time-budget=3000 --screenshot="$3" "file://$PWD/scripts/site/og.html$4" >/dev/null 2>&1
}

python3 -I scripts/site/build.py --locales | while read -r code suffix; do
  [[ $suffix == - ]] && suffix=""
  shoot 1 1200,630 "$out/og-$code.png" "?lang=$code"
  shoot 2 1000,620 "$out/preview-$code.png" "?shot&lang=$code"
  sips -s format jpeg -s formatOptions 88 "$out/og-$code.png" --out "docs/assets/og-image$suffix.jpg" >/dev/null
  cwebp -quiet -q 90 "$out/preview-$code.png" -o "docs/assets/preview$suffix.webp"
done
python3 -I scripts/version-site-assets.py
