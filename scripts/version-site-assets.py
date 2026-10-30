#!/usr/bin/env python3
"""Refresh the shared page parts and the static asset versions after changing the website."""
from hashlib import sha256
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
docs = root / "docs"
parts_dir = root / "scripts" / "site"

# Shared parts live once in scripts/site as <name>.svg or <name>.html and are copied between
# <!-- part:name --> and <!-- /part:name --> markers, indented like the opening marker.
parts = {path.stem: path.read_text().strip() for path in parts_dir.glob("*.svg")}
parts |= {path.stem: path.read_text().strip() for path in parts_dir.glob("*.html") if path.stem != "og"}
part_block = re.compile(r"^([ \t]*)<!-- part:([\w-]+) -->\n.*?^[ \t]*<!-- /part:\2 -->$", re.M | re.S)


def fill(match):
    indent, name = match[1], match[2]
    body = "\n".join(indent + line if line else line for line in parts[name].splitlines())
    return f"{indent}<!-- part:{name} -->\n{body}\n{indent}<!-- /part:{name} -->"


# Every attribute that points into assets/ gets a content hash, so the 30-day asset cache never
# serves a stale file. Fonts are left alone: their file names carry the version and must match
# the url() in site.css, or the preload fetches a second copy.
asset_reference = re.compile(r'(=")([^"?]*assets/((?!fonts/)[^"?]+))(?:\?v=[a-f0-9]+)?(")')


def version(match):
    asset = docs / "assets" / match[3]
    if not asset.is_file():
        return match[0]
    digest = sha256(asset.read_bytes()).hexdigest()[:12]
    return f"{match[1]}{match[2]}?v={digest}{match[4]}"


# The share card page reuses the demo but points at docs/assets by relative path, so it only
# needs its parts.
share = parts_dir / "og.html"
share.write_text(part_block.sub(fill, share.read_text()))

# docs/design/lab holds local scratch pages that are not published.
for page in sorted(path for path in docs.rglob("*.html") if "lab" not in path.relative_to(docs).parts):
    text = part_block.sub(fill, page.read_text())
    page.write_text(asset_reference.sub(version, text))
