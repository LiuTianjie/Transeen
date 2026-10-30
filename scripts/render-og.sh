#!/bin/zsh
# Renders the share cards (docs/assets/og-image.jpg, og-image-zh.jpg) and the README screenshots
# (docs/assets/preview.webp, preview-zh.webp) from the live demo in scripts/site/og.html.
set -euo pipefail
cd "${0:A:h:h}"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
out=build/website-preview
mkdir -p "$out"
python3 -I scripts/version-site-assets.py

shoot() {
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor="$1" --window-size="$2" \
    --virtual-time-budget=3000 --screenshot="$3" "file://$PWD/scripts/site/og.html$4" >/dev/null 2>&1
}

shoot 1 1200,630 "$out/og-en.png" ""
shoot 1 1200,630 "$out/og-zh.png" "?lang=zh"
shoot 2 1000,620 "$out/preview-en.png" "?shot"
shoot 2 1000,620 "$out/preview-zh.png" "?shot&lang=zh"

sips -s format jpeg -s formatOptions 88 "$out/og-en.png" --out docs/assets/og-image.jpg >/dev/null
sips -s format jpeg -s formatOptions 88 "$out/og-zh.png" --out docs/assets/og-image-zh.jpg >/dev/null
cwebp -quiet -q 90 "$out/preview-en.png" -o docs/assets/preview.webp
cwebp -quiet -q 90 "$out/preview-zh.png" -o docs/assets/preview-zh.webp
python3 -I scripts/version-site-assets.py
