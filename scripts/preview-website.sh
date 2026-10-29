#!/bin/zsh
# Renders the website artwork: Chrome draws the sample page in scripts/site at 2x, then the
# production pipeline, annotation layer and toolbar (scripts/WebsitePreview.swift) work on it.
# TRANSEEN_SOURCES picks the app sources to build against, for example a clean export of the
# released commit while the working tree has changes in progress.
set -euo pipefail
cd "${0:A:h:h}"
src="${TRANSEEN_SOURCES:-Sources}"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
out=build/website-preview
mkdir -p "$out"

python3 -I scripts/version-site-assets.py
"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size=800,729 \
  --screenshot="$out/kumo-ja.png" "file://$PWD/scripts/site/kumo-render.html" >/dev/null 2>&1

swiftc -swift-version 6 -O -framework AppKit -framework Vision -framework Translation -framework ScreenCaptureKit \
  "$src"/Translation/*.swift "$src"/Screen/*.swift "$src"/Screen/Pipeline/*.swift "$src"/App/ShortcutStore.swift \
  "$src"/App/AppSettings.swift "$src"/App/AppleGlass.swift "$src"/App/PermissionGuide.swift scripts/WebsitePreview.swift \
  -o "$out/render"
"$out/render"

cd "$out"
for name in stage-original stage-lifted-en stage-lifted-zh stage-redrawn-en stage-redrawn-zh permission \
  capture-read-en capture-read-zh capture-mark-en capture-mark-zh capture-keep-en capture-keep-zh \
  select-en select-zh toolbar-en toolbar-zh preview-zh \
  page-ja page-en page-zh-hans page-zh-hant page-ko page-fr page-es page-de; do
  cwebp -quiet -lossless -z 9 "$name.png" -o "../../docs/assets/$name.webp"
done
cwebp -quiet -lossless preview-en.png -o ../../docs/assets/preview.webp
cp stage-lines-en.json stage-lines-zh.json regions-ja.json blocks-ja.json ../../scripts/site/
