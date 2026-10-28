#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests
swiftc -D DEBUG -swift-version 6 -framework AppKit -framework Vision -framework Translation -framework ScreenCaptureKit Sources/Translation/*.swift Sources/Screen/*.swift Sources/Screen/Pipeline/*.swift Sources/App/ShortcutStore.swift Sources/App/GlobalShortcuts.swift Sources/App/AppSettings.swift Sources/App/AppleGlass.swift Tests/CaptureLifecycleTests.swift -o build/tests/lifecycle
build/tests/lifecycle
