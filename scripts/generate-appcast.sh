#!/usr/bin/env bash
# Writes the Sparkle appcast for a notarized release archive.
#
# Usage: scripts/generate-appcast.sh <archive.zip> [output.xml]
#
# The archive is signed with the EdDSA key in the login keychain under the Sparkle
# account "transeen" (created once with `$(scripts/sparkle-tools.sh)/bin/generate_keys
# --account transeen`). Its public half is SUPublicEDKey in Info.plist. The feed points
# at the GitHub Release asset, so copy it to docs/updates/appcast.xml only after that
# release is public: installed apps read https://transeen.itool.tech/updates/appcast.xml.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

archive="${1:?usage: scripts/generate-appcast.sh <archive.zip> [output.xml]}"
keychain_account="${SPARKLE_KEYCHAIN_ACCOUNT:-transeen}"
repository="${GITHUB_REPOSITORY:-LiuTianjie/Transeen}"
[ -f "$archive" ] || { echo "Archive not found: $archive" >&2; exit 1; }

tools="$(bash scripts/sparkle-tools.sh)"

# Sparkle compares CFBundleVersion, so read the numbers from the archived app itself.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$archive" "$work"
info="${work}/Transeen.app/Contents/Info.plist"
[ -f "$info" ] || { echo "The archive does not contain Transeen.app" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$info" 2>/dev/null || true; }
short_version="$(plist CFBundleShortVersionString)"
build_version="$(plist CFBundleVersion)"
minimum_system="$(plist LSMinimumSystemVersion)"
feed_url="$(plist SUFeedURL)"
public_key="$(plist SUPublicEDKey)"
output="${2:-dist/appcast-${short_version}.xml}"
case "$feed_url" in
  https://*) ;;
  *) echo "The archived app has no SUFeedURL; build it with a Developer ID identity." >&2; exit 1 ;;
esac
[ -n "$public_key" ] || { echo "The archived app has no SUPublicEDKey." >&2; exit 1; }

# The signing key must be the one the app trusts.
keychain_public_key="$("${tools}/bin/generate_keys" --account "$keychain_account" -p)"
if [ "$keychain_public_key" != "$public_key" ]; then
  echo "Keychain key ${keychain_account} does not match the app's SUPublicEDKey." >&2
  exit 1
fi
# `sign_update` prints: sparkle:edSignature="..." length="..."
signature_attributes="$("${tools}/bin/sign_update" --account "$keychain_account" "$archive")"
case "$signature_attributes" in
  *'sparkle:edSignature="'*'length="'*) ;;
  *) echo "sign_update did not return a signature: ${signature_attributes}" >&2; exit 1 ;;
esac
signature="$(printf '%s' "$signature_attributes" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
"${tools}/bin/sign_update" --account "$keychain_account" --verify "$archive" "$signature" >/dev/null

download_url="https://github.com/${repository}/releases/download/v${short_version}/$(basename "$archive")"
pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
# A file, not a heredoc inside $(...): bash 3.2 misreads the backticks in it there.
notes_script="${work}/release-notes.py"
cat > "$notes_script" <<'PY'
import html, re, sys
version = sys.argv[1]
text = open("CHANGELOG.md", encoding="utf-8").read()
match = re.search(r"^## " + re.escape(version) + r"\b.*?$(.*?)(?=^## |\Z)", text, re.S | re.M)
if not match:
    sys.exit(f"CHANGELOG.md has no section for {version}")
items, current = [], None
for line in match.group(1).splitlines():
    if line.startswith("- "):
        current = [line[2:].strip()]
        items.append(current)
    elif line.strip() and current is not None:
        current.append(line.strip())
if not items:
    sys.exit(f"CHANGELOG.md section {version} has no items")
def render(parts):
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(" ".join(parts)))
print("<ul>" + "".join(f"<li>{render(item)}</li>" for item in items) + "</ul>")
PY
release_notes="$(/usr/bin/python3 "$notes_script" "$short_version")"

mkdir -p "$(dirname "$output")"
cat > "$output" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Transeen</title>
    <link>${feed_url}</link>
    <description>Transeen updates</description>
    <language>en</language>
    <item>
      <title>Transeen ${short_version}</title>
      <pubDate>${pub_date}</pubDate>
      <sparkle:version>${build_version}</sparkle:version>
      <sparkle:shortVersionString>${short_version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${minimum_system}</sparkle:minimumSystemVersion>
      <description><![CDATA[${release_notes}]]></description>
      <enclosure url="${download_url}" type="application/octet-stream" ${signature_attributes} />
    </item>
  </channel>
</rss>
XML
/usr/bin/xmllint --noout "$output"
echo "$output"
