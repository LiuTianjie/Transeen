#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
transeen_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/transeen-capture-tools.XXXXXX")
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$transeen_test_dir"' EXIT
swiftc -O -swift-version 6 -module-cache-path "$transeen_test_dir/modules" -framework AppKit -framework Vision \
  Sources/Translation/AppLanguage.swift Sources/Translation/Localization.swift \
  Sources/Screen/Annotations.swift Sources/Screen/CaptureHistory.swift Sources/Screen/ScrollStitcher.swift \
  Tests/FrameFingerprint.swift Tests/CaptureToolsTests.swift -o "$transeen_test_dir/capture-tools"
"$transeen_test_dir/capture-tools"
