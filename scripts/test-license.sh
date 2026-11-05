#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests
swiftc -swift-version 6 -framework AppKit -framework Security -framework AuthenticationServices -framework Network Sources/Licensing/LicenseManager.swift Sources/Licensing/LicenseAuth.swift Sources/Licensing/LoopbackOAuth.swift Sources/Translation/AppLanguage.swift Sources/Translation/Localization.swift Sources/App/UpdateChecker.swift Tests/LicenseTests.swift -o build/tests/license
build/tests/license
