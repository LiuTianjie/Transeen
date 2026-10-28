#!/usr/bin/env python3
"""Refresh static asset versions after changing website assets."""
from hashlib import sha256
from pathlib import Path
import re

docs = Path(__file__).resolve().parent.parent / "docs"
asset_reference = re.compile(
    r'((?:src|href|content)=")([^"?]*assets/([^"?]+))(?:\?v=[a-f0-9]+)?(")'
)


def version(match):
    asset = docs / "assets" / match[3]
    if not asset.is_file():
        return match[0]
    digest = sha256(asset.read_bytes()).hexdigest()[:12]
    return f"{match[1]}{match[2]}?v={digest}{match[4]}"


for page in (docs / "index.html", docs / "zh/index.html", docs / "404.html"):
    page.write_text(asset_reference.sub(version, page.read_text()))
