#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/website-preview
swiftc -swift-version 6 -framework AppKit -framework Vision -framework Translation -framework ScreenCaptureKit Sources/Translation/*.swift Sources/Screen/*.swift Sources/Screen/Pipeline/*.swift Sources/App/ShortcutStore.swift Sources/App/AppSettings.swift Sources/App/AppleGlass.swift scripts/WebsitePreview.swift -o build/website-preview/render
build/website-preview/render
for name in original translated toolbar toolbar-annotate preview; do
  cwebp -quiet -lossless "build/website-preview/$name.png" -o "docs/assets/$name.webp"
done
