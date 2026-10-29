#!/bin/zsh
# Renders the share cards (docs/assets/og-image.jpg and og-image-zh.jpg) from scripts/site/og.html.
set -euo pipefail
cd "${0:A:h:h}"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
mkdir -p build/website-preview
for lang in en zh; do
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --window-size=1200,630 --virtual-time-budget=2000 \
    --screenshot="build/website-preview/og-$lang.png" "file://$PWD/scripts/site/og.html?lang=$lang" >/dev/null 2>&1
done
sips -s format jpeg -s formatOptions 88 build/website-preview/og-en.png --out docs/assets/og-image.jpg >/dev/null
sips -s format jpeg -s formatOptions 88 build/website-preview/og-zh.png --out docs/assets/og-image-zh.jpg >/dev/null
