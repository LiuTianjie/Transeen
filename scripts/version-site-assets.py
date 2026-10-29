#!/usr/bin/env python3
"""Refresh the shared page parts and the static asset versions after changing the website."""
from hashlib import sha256
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parent.parent
docs = root / "docs"
parts_dir = root / "scripts" / "site"

# Shared parts live once in scripts/site and are copied between <!-- part:name --> and
# <!-- /part:name --> markers, indented like the opening marker.
def json_script(element_id, value):
    data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    return f'<script type="application/json" id="{element_id}">{data}</script>'


def load(name):
    # The render page is built before these exist; it does not use them.
    path = parts_dir / name
    return json.loads(path.read_text()) if path.is_file() else None


# What the website's demonstrations know about the sample page: its size, the default capture, where
# the selection snaps (the production region finder), every text block with its translations, and
# the lines recognised in the default capture. All of it comes from scripts/preview-website.sh.
scene = {
    "page": [800, 729],
    "capture": [432, 93, 348, 294],
    "languages": load("kumo-strings.json")["languages"],
    "regions": load("regions-ja.json"),
    "blocks": load("blocks-ja.json"),
    "lines": {"en": load("stage-lines-en.json"), "zh-Hans": load("stage-lines-zh.json")},
}
parts = {
    "sprite": (parts_dir / "sprite.svg").read_text().strip(),
    "kumo-sprite": (parts_dir / "kumo-sprite.svg").read_text().strip(),
    "kumo-scene": (parts_dir / "kumo-scene.html").read_text().strip(),
    "scene-data": json_script("scene-data", scene),
}
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


for page in sorted(docs.rglob("*.html")) + [parts_dir / "kumo-render.html"]:
    text = part_block.sub(fill, page.read_text())
    if page.is_relative_to(docs):
        text = asset_reference.sub(version, text)
    page.write_text(text)
