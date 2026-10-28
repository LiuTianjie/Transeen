#!/usr/bin/env python3
"""Refresh static asset versions after changing website assets."""
from hashlib import sha256
from pathlib import Path
import re

docs = Path(__file__).resolve().parent.parent / "docs"
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


for page in sorted(docs.rglob("*.html")):
    page.write_text(asset_reference.sub(version, page.read_text()))
