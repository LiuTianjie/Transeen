#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Keep the build product and deliverable under the same stable TCC identity.
# With multiple Developer ID certificates, the caller chooses explicitly.
transeen_signing_identity="${TRANSEEN_SIGNING_IDENTITY:-}"
if [[ -z "$transeen_signing_identity" ]]; then
  transeen_identities=(${(f)$(security find-identity -v -p codesigning | awk '/Developer ID Application:/ {print $2}')})
  if (( ${#transeen_identities} == 1 )); then
    transeen_signing_identity="$transeen_identities[1]"
  fi
fi
transeen_signing_args=("CODE_SIGN_IDENTITY=${transeen_signing_identity:--}")
if [[ -n "$transeen_signing_identity" ]]; then
  transeen_signing_args+=("ENABLE_HARDENED_RUNTIME=YES" "OTHER_CODE_SIGN_FLAGS=--timestamp")
else
  print 'Building with ad-hoc signing. Set TRANSEEN_SIGNING_IDENTITY for stable screen-recording permissions.'
fi
./scripts/build-llama.sh
xcodegen generate
xcodebuild -project Transeen.xcodeproj -scheme Transeen -configuration "${1:-Release}" -derivedDataPath build build "${transeen_signing_args[@]}"
mkdir -p dist
rm -rf dist/Transeen.app
ditto "build/Build/Products/${1:-Release}/Transeen.app" dist/Transeen.app
codesign --verify --strict dist/Transeen.app
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$PWD/dist/Transeen.app"
