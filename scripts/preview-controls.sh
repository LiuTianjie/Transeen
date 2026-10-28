#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests
swiftc -swift-version 6 -framework AppKit -framework Vision -framework Translation -framework ScreenCaptureKit Sources/Translation/*.swift Sources/Screen/*.swift Sources/Screen/Pipeline/*.swift Sources/App/ShortcutStore.swift Sources/App/AppSettings.swift Sources/App/AppleGlass.swift Tests/CaptureVisualPreview.swift -o build/tests/visual-preview
build/tests/visual-preview
