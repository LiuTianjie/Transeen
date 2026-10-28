#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests
swiftc -O -framework AppKit -framework Vision Sources/Translation/AppLanguage.swift Sources/Screen/ScreenLayout.swift Sources/Screen/Pipeline/*.swift Tests/ScreenPipelineTests.swift -o build/tests/pipeline
build/tests/pipeline
swiftc -O Sources/Screen/Pipeline/Pixels.swift Sources/Screen/ScreenRegionFinder.swift Tests/ScreenRegionFinderTests.swift -o build/tests/regions
build/tests/regions
swiftc -O -framework AppKit -framework Vision Sources/Translation/AppLanguage.swift Sources/Screen/ScreenLayout.swift Sources/Screen/Pipeline/*.swift Sources/Screen/ScreenPreciseTranslator.swift Tests/PreciseTranslationTests.swift -o build/tests/precise
build/tests/precise
swiftc -framework AppKit Sources/Screen/Annotations.swift Tests/FrameFingerprint.swift Sources/Screen/CaptureCrop.swift Sources/Translation/ModelHTTP.swift Tests/CaptureTests.swift -o build/tests/capture
build/tests/capture
