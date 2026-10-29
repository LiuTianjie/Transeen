#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests
swiftc -O -swift-version 6 -framework AppKit -framework Vision -framework Translation Sources/Translation/*.swift Sources/Screen/ScreenLayout.swift Sources/Screen/ScreenPreciseTranslator.swift Sources/Screen/Pipeline/*.swift Sources/App/ShortcutStore.swift Sources/App/AppSettings.swift Tests/LocalModelTests.swift -o build/tests/local-models
build/tests/local-models
