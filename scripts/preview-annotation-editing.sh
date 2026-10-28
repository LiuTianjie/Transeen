#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
preview_app="$PWD/build/tests/Transeen Annotation Preview.app"
mkdir -p "$preview_app/Contents/MacOS"
swiftc -D DEBUG -swift-version 6 -framework AppKit -framework Vision -framework Translation -framework ScreenCaptureKit Sources/Translation/*.swift Sources/Screen/*.swift Sources/Screen/Pipeline/*.swift Sources/App/ShortcutStore.swift Sources/App/AppSettings.swift Sources/App/AppleGlass.swift Tests/AnnotationInteractionPreview.swift -o "$preview_app/Contents/MacOS/annotation-preview"
cat > "$preview_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.transeen.annotation-preview</string><key>CFBundleExecutable</key><string>annotation-preview</string><key>CFBundleName</key><string>Transeen Annotation Preview</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
open "$preview_app"
