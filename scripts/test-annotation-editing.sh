#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests
swiftc -swift-version 6 -framework AppKit Sources/Translation/AppLanguage.swift Sources/Translation/Localization.swift Sources/Screen/Annotations.swift Tests/FrameFingerprint.swift Tests/AnnotationEditingTests.swift -o build/tests/annotation-editing
build/tests/annotation-editing
