#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
transeen_package_identity="${TRANSEEN_SIGNING_IDENTITY:-}"
if [[ -z "$transeen_package_identity" ]]; then
  transeen_package_identities=(${(f)$(security find-identity -v -p codesigning | awk '/Developer ID Application:/ {print $2}')})
  if (( ${#transeen_package_identities} != 1 )); then
    print -u2 'Set TRANSEEN_SIGNING_IDENTITY to a Developer ID Application identity.'
    exit 1
  fi
  transeen_package_identity="$transeen_package_identities[1]"
fi
if [[ "${1:-}" != '--skip-build' ]]; then
  TRANSEEN_SIGNING_IDENTITY="$transeen_package_identity" ./scripts/build.sh Release
fi
codesign --verify --deep --strict dist/Transeen.app
transeen_package_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/Transeen.app/Contents/Info.plist)
transeen_package_staging=$(mktemp -d "$PWD/build/package.XXXXXX")
trap 'rm -rf "$transeen_package_staging"' EXIT
ditto dist/Transeen.app "$transeen_package_staging/Transeen.app"
ln -s /Applications "$transeen_package_staging/Applications"
hdiutil create -volname "Transeen $transeen_package_version" -srcfolder "$transeen_package_staging" -format UDZO -ov "dist/Transeen-$transeen_package_version.dmg"
codesign --force --sign "$transeen_package_identity" --timestamp "dist/Transeen-$transeen_package_version.dmg"
codesign --verify --strict "dist/Transeen-$transeen_package_version.dmg"
ditto -c -k --sequesterRsrc --keepParent dist/Transeen.app "dist/Transeen-$transeen_package_version.zip"
shasum -a 256 "dist/Transeen-$transeen_package_version.dmg" "dist/Transeen-$transeen_package_version.zip" > "dist/Transeen-$transeen_package_version.sha256"
print "Signed packages: dist/Transeen-$transeen_package_version.dmg and .zip (not notarized)."
