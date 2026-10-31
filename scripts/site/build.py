#!/usr/bin/env python3
"""Writes the website in every language it is published in.

The facts live in scripts/site/site.toml and each language's words in scripts/site/locales/.
Pages are written with empty <!-- part:… --> blocks; version-site-assets.py, run at the end,
fills them and versions the assets. `build.py --locales` prints each language's code and image
suffix ("-" for none) for scripts/render-og.sh.

Edit the TOML files, not the pages in docs/: build.py overwrites them. For a new version, change
site.toml (version, dates, size, the two newest releases) and add the release's notes to every
locale. Then run scripts/render-og.sh, which builds the pages and renders the share cards and
README screenshots from the live demo.
"""
import html
import json
import re
import subprocess
import sys
import tomllib
from pathlib import Path

here = Path(__file__).resolve().parent
root = here.parent.parent
docs = root / "docs"
site = tomllib.loads((here / "site.toml").read_text())
locales = site["locale"]
origin = site["origin"]
version = site["version"]
repo = site["repository"]
download = site["download"]

if sys.argv[1:] == ["--locales"]:
    for loc in locales:
        print(loc["code"], loc["suffix"] or "-")
    sys.exit()

words = {loc["code"]: tomllib.loads((here / "locales" / f"{loc['code']}.toml").read_text()) for loc in locales}
english = locales[0]


def shape(value, where=""):
    """Every key path in a language file, with list lengths, so files can be compared."""
    if isinstance(value, dict):
        return {path for key, item in value.items() for path in shape(item, f"{where}.{key}")}
    if isinstance(value, list) and value and isinstance(value[0], (dict, list)):
        return {f"{where}[{len(value)}]"} | {path for n, item in enumerate(value) for path in shape(item, f"{where}[{n}]")}
    if isinstance(value, list):
        return {f"{where}[{len(value)}]"}
    return {where}


# Every language must have exactly the English file's keys, apart from month names, which only
# languages that spell months out need.
reference = {path for path in shape(words["en"]) if not path.startswith(".ui.months")}
for code, data in words.items():
    found = {path for path in shape(data) if not path.startswith(".ui.months")}
    if found != reference:
        sys.exit(f"locales/{code}.toml differs from en.toml: missing {sorted(reference - found)}, extra {sorted(found - reference)}")
    for release in site["release"]:
        if release["version"] not in data["changes"]["notes"]:
            sys.exit(f"locales/{code}.toml has no notes for {release['version']}")

REDIRECT = (r'<script>if(location.hostname.endsWith("github.io"))location.replace("https://transeen.itool.tech"'
            r'+location.pathname.replace(/^\/Transeen/i,"")+location.search+location.hash)</script>')
TOOL_ICONS = ["rectangle", "crop", "pin", "copy", "text", "viewfinder"]
FIGURES = ["fig-select", "fig-recognize", "fig-lift", "fig-set"]
CODES = {"en": "EN", "zh-Hans": "ZH-HANS", "zh-Hant": "ZH-HANT", "ja": "JA", "ko": "KO", "fr": "FR", "es": "ES", "de": "DE"}


def esc(text):
    return html.escape(str(text), quote=True)


def plain(fragment):
    """The text of an HTML fragment, for meta tags and structured data."""
    return " ".join(html.unescape(re.sub(r"<[^>]+>", "", fragment)).split())


def fill(text):
    return text.replace("{version}", version).replace("{size}", site["size_mb"]).replace("{about}", site["size_about"])


def path(loc, guide=False):
    return "".join(f"{part}/" for part in (loc["dir"], "guide" if guide else "") if part)


def address(loc, guide=False):
    return f"{origin}/{path(loc, guide)}"


def up(loc, guide=False):
    return "../" * path(loc, guide).count("/")


def link(loc, guide, target, target_guide=False, anchor=""):
    """A relative link from one page to another, or to a place on the same page."""
    here_dirs = path(loc, guide).split("/")[:-1]
    there = path(target, target_guide).split("/")[:-1]
    if here_dirs == there:
        return anchor or "./"
    common = 0
    while common < min(len(here_dirs), len(there)) and here_dirs[common] == there[common]:
        common += 1
    relative = "../" * (len(here_dirs) - common) + "".join(f"{name}/" for name in there[common:])
    return (relative or "./") + anchor


def day(w, when):
    months = w["ui"].get("months")
    return w["ui"]["date"].format(y=when.year, m=when.month, d=when.day, mon=months[when.month - 1] if months else "")


def lines(block, indent):
    return "\n".join(" " * indent + line if line else line for line in block)


def part(name, indent):
    pad = " " * indent
    return f"{pad}<!-- part:{name} -->\n{pad}<!-- /part:{name} -->"


def lang_attrs(loc, other):
    return "" if other is loc else f' hreflang="{other["hreflang"][0]}" lang="{other["lang"]}"'


# Structured data

def organization():
    return {
        "@type": "Organization",
        "@id": f"{origin}/#organization",
        "name": "Transeen",
        "url": f"{origin}/",
        "logo": {"@type": "ImageObject", "url": f"{origin}/assets/icon-512.png", "width": 512, "height": 512},
        "sameAs": [repo],
        "parentOrganization": {"@type": "Organization", "name": "iTool", "url": "https://itool.tech/"},
    }


def website():
    return {
        "@type": "WebSite",
        "@id": f"{origin}/#website",
        "url": f"{origin}/",
        "name": "Transeen",
        "inLanguage": [loc["hreflang"][0] for loc in locales],
        "publisher": {"@id": f"{origin}/#organization"},
    }


def image_of(loc):
    return f"{origin}/assets/og-image{loc['suffix']}.jpg"


def home_graph(loc, w):
    page = address(loc)
    software = w["software"]
    return [
        organization(),
        website(),
        {
            "@type": "WebPage",
            "@id": f"{page}#webpage",
            "url": page,
            "name": w["meta"]["title"],
            "description": w["meta"]["description"],
            "inLanguage": loc["hreflang"][0],
            "isPartOf": {"@id": f"{origin}/#website"},
            "about": {"@id": f"{origin}/#software"},
            "primaryImageOfPage": {"@type": "ImageObject", "url": image_of(loc), "width": 1200, "height": 630},
            "datePublished": str(site["published"]),
            "dateModified": str(site["modified"]),
        },
        {
            "@type": "SoftwareApplication",
            "@id": f"{origin}/#software",
            "name": "Transeen",
            "description": software["description"],
            "url": page,
            "applicationCategory": "UtilitiesApplication",
            "applicationSubCategory": software["category"],
            "operatingSystem": software["os"],
            "processorRequirements": software["processor"],
            "softwareVersion": version,
            "datePublished": str(site["published"]),
            "dateModified": str(site["released"]),
            "fileSize": f"{site['size_mb']} MB",
            "inLanguage": [other["hreflang"][0] for other in locales],
            "downloadUrl": download,
            "installUrl": download,
            "releaseNotes": f"{repo}/blob/main/CHANGELOG.md",
            "softwareHelp": {"@type": "CreativeWork", "url": address(loc, True)},
            "image": image_of(loc),
            "screenshot": [f"{origin}/assets/preview{loc['suffix']}.webp"],
            "featureList": software["features"],
            "license": "https://opensource.org/licenses/MIT",
            "author": {"@type": "Person", "name": "LiuTianjie", "url": "https://github.com/LiuTianjie"},
            "publisher": {"@id": f"{origin}/#organization"},
        },
        {
            "@type": "SoftwareSourceCode",
            "@id": f"{origin}/#source",
            "name": "Transeen source code",
            "codeRepository": repo,
            "programmingLanguage": "Swift",
            "runtimePlatform": "macOS 26",
            "license": "https://opensource.org/licenses/MIT",
            "targetProduct": {"@id": f"{origin}/#software"},
        },
        {
            "@type": "FAQPage",
            "@id": f"{page}#faq",
            "inLanguage": loc["hreflang"][0],
            "isPartOf": {"@id": f"{origin}/#website"},
            "mainEntity": [
                {"@type": "Question", "name": plain(item["q"]),
                 "acceptedAnswer": {"@type": "Answer", "text": plain(fill(item["a"]))}}
                for item in w["faq"]["items"]
            ],
        },
    ]


def guide_graph(loc, w):
    page = address(loc, True)
    g = w["guide"]
    ids = [section["id"] for section in g["sections"]]
    return [
        organization(),
        website(),
        {
            "@type": "TechArticle",
            "@id": f"{page}#article",
            "headline": plain(g["title"]),
            "description": w["meta"]["guide_description"],
            "inLanguage": loc["hreflang"][0],
            "url": page,
            "mainEntityOfPage": page,
            "image": image_of(loc),
            "datePublished": str(site["published"]),
            "dateModified": str(site["modified"]),
            "author": {"@type": "Person", "name": "LiuTianjie", "url": "https://github.com/LiuTianjie"},
            "publisher": {"@id": f"{origin}/#organization"},
            "about": {"@id": f"{origin}/#software"},
            "isPartOf": {"@id": f"{origin}/#website"},
            "proficiencyLevel": "Beginner",
        },
        {
            "@type": "HowTo",
            "@id": f"{page}#howto",
            "name": g["howto"]["name"],
            "inLanguage": loc["hreflang"][0],
            "image": image_of(loc),
            "supply": [{"@type": "HowToSupply", "name": g["howto"]["supply"]}],
            "tool": [{"@type": "HowToTool", "name": name} for name in g["howto"]["tools"]],
            "step": [
                {"@type": "HowToStep", "position": n + 1, "name": step["name"], "url": f"{page}#{ids[n]}",
                 "text": step["text"]}
                for n, step in enumerate(g["howto"]["steps"])
            ],
        },
        {
            "@type": "BreadcrumbList",
            "@id": f"{page}#breadcrumb",
            "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": "Transeen", "item": address(loc)},
                {"@type": "ListItem", "position": 2, "name": g["name"], "item": page},
            ],
        },
    ]


# Page parts

def head(loc, guide, w, graph):
    m = w["meta"]
    key = "guide_" if guide else ""
    title, description, keywords = m[key + "title"], m[key + "description"], m[key + "keywords"]
    og_title, og_description = m[key + "og_title"], m[key + "og_description"]
    prefix = up(loc, guide)
    out = [
        '<meta charset="utf-8" />',
        REDIRECT,
        '<meta name="viewport" content="width=device-width, initial-scale=1" />',
        f"<title>{esc(title)}</title>",
        f'<meta name="description" content="{esc(description)}" />',
        f'<meta name="keywords" content="{esc(keywords)}" />',
        '<meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1" />',
        '<meta name="author" content="LiuTianjie" />',
        '<meta name="theme-color" content="#08090a" />',
        '<meta name="color-scheme" content="dark" />',
        '<meta name="applicable-device" content="pc,mobile" />',
        '<meta name="format-detection" content="telephone=no" />',
    ]
    if loc.get("baidu"):
        out += ['<meta http-equiv="Cache-Control" content="no-transform" />',
                '<meta http-equiv="Cache-Control" content="no-siteapp" />']
    out.append(f'<link rel="canonical" href="{address(loc, guide)}" />')
    for other in locales:
        out += [f'<link rel="alternate" hreflang="{code}" href="{address(other, guide)}" />' for code in other["hreflang"]]
    out.append(f'<link rel="alternate" hreflang="x-default" href="{address(english, guide)}" />')
    out += [
        f'<meta property="og:type" content="{"article" if guide else "website"}" />',
        '<meta property="og:site_name" content="Transeen" />',
        f'<meta property="og:url" content="{address(loc, guide)}" />',
        f'<meta property="og:title" content="{esc(og_title)}" />',
        f'<meta property="og:description" content="{esc(og_description)}" />',
        f'<meta property="og:image" content="{image_of(loc)}" />',
        '<meta property="og:image:type" content="image/jpeg" />',
        '<meta property="og:image:width" content="1200" />',
        '<meta property="og:image:height" content="630" />',
        f'<meta property="og:image:alt" content="{esc(m["image_alt"])}" />',
        f'<meta property="og:locale" content="{loc["og"]}" />',
    ]
    out += [f'<meta property="og:locale:alternate" content="{other["og"]}" />' for other in locales if other is not loc]
    if guide:
        out.append(f'<meta property="article:published_time" content="{site["published"]}" />')
        out.append(f'<meta property="article:modified_time" content="{site["modified"]}" />')
    out += [
        '<meta name="twitter:card" content="summary_large_image" />',
        f'<meta name="twitter:title" content="{esc(og_title)}" />',
        f'<meta name="twitter:description" content="{esc(og_description)}" />',
        f'<meta name="twitter:image" content="{image_of(loc)}" />',
        f'<meta name="twitter:image:alt" content="{esc(m["image_alt"])}" />',
        '<script type="application/ld+json">',
    ]
    data = json.dumps({"@context": "https://schema.org", "@graph": graph}, ensure_ascii=False, indent=2)
    out += ["  " + line for line in data.replace("</", "<\\/").splitlines()]
    out += [
        "</script>",
        f'<link rel="icon" href="{prefix}favicon.ico" sizes="48x48" />',
        f'<link rel="icon" href="{prefix}assets/app-icon.svg" type="image/svg+xml" />',
        f'<link rel="apple-touch-icon" href="{prefix}assets/apple-touch-icon.png" />',
        f'<link rel="manifest" href="{prefix}site.webmanifest" />',
        f'<link rel="preload" href="{prefix}assets/fonts/geist-1.8.2.woff2" as="font" type="font/woff2" crossorigin />',
        f'<link rel="stylesheet" href="{prefix}assets/site.css" />',
        '<script>document.documentElement.classList.add("js")</script>',
    ]
    return lines(out, 4)


def language_menu(loc, guide, w):
    out = [
        '<details class="langmenu">',
        f'  <summary aria-label="{esc(w["ui"]["language"])}: {esc(loc["name"])}"><svg aria-hidden="true"><use href="#ui-globe" /></svg><span>{loc["name"]}</span></summary>',
        '  <ul role="list">',
    ]
    for other in locales:
        current = ' aria-current="page"' if other is loc else ""
        out.append(f'    <li><a href="{link(loc, guide, other, guide)}"{lang_attrs(loc, other)}{current}>{other["name"]}</a></li>')
    return out + ["  </ul>", "</details>"]


def header(loc, guide, w):
    u = w["ui"]
    home = lambda anchor="": link(loc, guide, loc, False, anchor)
    current = ' aria-current="page"' if guide else ""
    out = [
        '<header class="nav">',
        '  <div class="wrap nav-inner">',
        f'    <a class="brand" href="{home()}" aria-label="{esc(u["home"])}"><img src="{up(loc, guide)}assets/app-icon.png" width="22" height="22" alt="" />Transeen</a>',
        f'    <nav class="nav-links" aria-label="{esc(u["main_nav"])}">',
        f'      <a href="{home("#how")}">{u["how"]}</a>',
        f'      <a href="{home("#apps")}">{u["apps"]}</a>',
        f'      <a href="{home("#tools")}">{u["tools"]}</a>',
        f'      <a href="{home("#languages")}">{u["languages"]}</a>',
        f'      <a href="{link(loc, guide, loc, True)}"{current}>{u["guide"]}</a>',
        "    </nav>",
        '    <div class="nav-end">',
    ]
    out += ["      " + line for line in language_menu(loc, guide, w)]
    out += [
        f'      <a class="button small" href="{download}">{u["download"]}</a>',
        "    </div>",
        "  </div>",
        "</header>",
    ]
    return lines(out, 4)


def footer(loc, guide, w):
    u = w["ui"]
    home = lambda anchor="": link(loc, guide, loc, False, anchor)
    manual = lambda anchor="": link(loc, guide, loc, True, anchor)
    others = []
    for other in locales:
        current = ' aria-current="page"' if other is loc else ""
        others.append(f'<a href="{link(loc, guide, other, guide)}"{lang_attrs(loc, other)}{current}>{other["name"]}</a>')
    out = [
        '<footer class="footer">',
        '  <div class="wrap">',
        '    <div class="footer-grid">',
        '      <div class="footer-brand">',
        f'        <a class="brand" href="{home()}"><img src="{up(loc, guide)}assets/app-icon.png" width="22" height="22" alt="" />Transeen</a>',
        f"        <p>{u['tagline']}</p>",
        "      </div>",
        '      <nav aria-labelledby="footer-product">',
        f'        <h2 id="footer-product">{u["product"]}</h2>',
        "        <ul>",
        f'          <li><a href="{home("#how")}">{u["how"]}</a></li>',
        f'          <li><a href="{home("#apps")}">{u["apps"]}</a></li>',
        f'          <li><a href="{home("#tools")}">{u["tools"]}</a></li>',
        f'          <li><a href="{home("#activation")}">{u["activation"]}</a></li>',
        "        </ul>",
        "      </nav>",
        '      <nav aria-labelledby="footer-help">',
        f'        <h2 id="footer-help">{u["help"]}</h2>',
        "        <ul>",
        f'          <li><a href="{manual()}">{u["setup_guide"]}</a></li>',
        f'          <li><a href="{manual("#shortcuts")}">{u["shortcuts"]}</a></li>',
        f'          <li><a href="{repo}/discussions">{u["questions"]}</a></li>',
        f'          <li><a href="{repo}/issues">{u["report"]}</a></li>',
        "        </ul>",
        "      </nav>",
        '      <nav aria-labelledby="footer-source">',
        f'        <h2 id="footer-source">{u["source"]}</h2>',
        "        <ul>",
        f'          <li><a href="{repo}">GitHub</a></li>',
        f'          <li><a href="{repo}/releases">{u["releases"]}</a></li>',
        f'          <li><a href="{repo}/blob/main/CHANGELOG.md">{u["changelog"]}</a></li>',
        f'          <li><a href="{repo}/blob/main/LICENSING.md">{u["licensing"]}</a></li>',
        "        </ul>",
        "      </nav>",
        '      <nav aria-labelledby="footer-more">',
        f'        <h2 id="footer-more">{u["more"]}</h2>',
        "        <ul>",
        '          <li><a href="https://itool.tech/">iTool</a></li>',
        '          <li><a href="https://stupidmirror.itool.tech/">StupidMirror</a></li>',
        "        </ul>",
        "      </nav>",
        "    </div>",
        f'    <nav class="footer-langs" aria-label="{esc(u["language"])}">',
        f'      <svg aria-hidden="true"><use href="#ui-globe" /></svg>',
    ]
    out += ["      " + item for item in others]
    out += [
        "    </nav>",
        '    <div class="footer-end">',
        f"      <p>{u['copyright']}</p>",
        f"      <p>{u['trademarks']}</p>",
        "    </div>",
        "  </div>",
        "</footer>",
    ]
    return lines(out, 4)


def section_head(fig, title_id, lede, extra=None, reveal=True):
    cls = "section-head reveal" if reveal else "section-head"
    out = [f'<div class="{cls}">', f'  <p class="fig">{fig}</p>', f'  <h2 class="lede" id="{title_id}">{lede}</h2>']
    if extra:
        out.append(f'  <p class="body-copy">{extra}</p>')
    return out + ["</div>"]


def home_main(loc, w):
    u, d, h = w["ui"], w["demo"], w["hero"]
    code = loc["code"]
    default = "en" if code == "ja" else code
    targets = [other for other in locales if other["code"] != "ja"]
    targets.sort(key=lambda other: other["code"] != default)
    chips = []
    for other in targets:
        attr = "" if other is loc else f' lang="{other["code"]}"'
        chips.append(f'<button class="chip" type="button" data-lang="{other["code"]}"{attr} aria-pressed="{str(other["code"] == default).lower()}">{other["name"]}</button>')
    meta = "".join(f"<span>{fill(item)}</span>" for item in h["meta"])

    out = [
        '<section class="hero" aria-labelledby="hero-title">',
        "  <span data-top></span>",
        '  <div class="wrap">',
        f'    <h1 class="hero-title load" id="hero-title">{h["title"]}</h1>',
        f'    <p class="hero-lead load" style="--d: 120">{h["lead"]}</p>',
        '    <div class="hero-actions load" style="--d: 220">',
        f'      <a class="button" href="{download}"><svg aria-hidden="true"><use href="#ui-download" /></svg>{u["download_mac"]}</a>',
        f'      <a class="link-arrow" href="{link(loc, False, loc, True)}">{u["setup_guide"]}</a>',
        "    </div>",
        f'    <p class="hero-meta load" style="--d: 300">{meta}</p>',
        "",
        '    <div class="hero-stage load" style="--d: 380">',
        f'      <div class="demo" tabindex="0" role="group" aria-roledescription="{esc(d["role"])}" aria-labelledby="demo-label">',
        f'        <p class="sr-only" id="demo-label">{d["label"]}</p>',
        '        <div class="demo-viewport">',
        "PART:demo:10",
        "        </div>",
        "      </div>",
        '      <div class="demo-controls">',
        f'        <div class="langs" role="group" aria-label="{esc(d["chips"])}">',
        '          <span class="langs-label">JA →</span>',
    ]
    out += ["          " + chip for chip in chips]
    out += [
        "        </div>",
        f'        <p class="demo-hint"><span>{d["hint"]}</span><button class="replay" type="button"><svg aria-hidden="true"><use href="#ui-replay" /></svg>{d["replay"]}</button></p>',
        "      </div>",
        "    </div>",
        "  </div>",
        "</section>",
        "",
    ]
    sections = [out]

    how = w["how"]
    block = ['<section class="section" id="how" aria-labelledby="how-title">', '  <div class="wrap">']
    block += ["    " + line for line in section_head(f"Fig 1.0 &nbsp;{how['fig']}", "how-title", how["lede"])]
    block.append('    <ol class="grid grid-4 reveal figs" role="list">')
    for n, (cell, figure) in enumerate(zip(how["cells"], FIGURES)):
        style = f"--d: {n * 120}; --n: {n}" if n else "--n: 0"
        block += [
            f'      <li class="cell" style="{style}">',
            f"PART:{figure}:8",
            f'        <p class="fig">1.{n + 1} &nbsp;{cell["label"]}</p>',
            f"        <h3>{cell['title']}</h3>",
            f"        <p>{cell['text']}</p>",
            "      </li>",
        ]
    block += ["    </ol>", "  </div>", "</section>", ""]
    sections.append(block)

    apps = w["apps"]
    block = ['<section class="section" id="apps" aria-labelledby="apps-title">', '  <div class="wrap">']
    block += ["    " + line for line in section_head(f"Fig 2.0 &nbsp;{apps['fig']}", "apps-title", apps["lede"])]
    block += [
        '    <div class="apps-layout">',
        '      <figure class="apps-figure reveal figs" style="--n: 0">',
        "PART:fig-apps:8",
        f'        <figcaption class="matrix-caption">{apps["caption"]}</figcaption>',
        "      </figure>",
        '      <ul class="apps-list reveal" role="list" style="--d: 150">',
    ]
    block += [f"        <li><b>{item['title']}</b><span>{item['text']}</span></li>" for item in apps["items"]]
    block += ["      </ul>", "    </div>", "  </div>", "</section>", ""]
    sections.append(block)

    keys = w["keys"]
    block = ['<section class="section" aria-labelledby="keys-title">', '  <div class="wrap">']
    block += ["    " + line for line in section_head(f"Fig 3.0 &nbsp;{keys['fig']}", "keys-title", keys["lede"])]
    block.append('    <div class="keys-panel reveal">')
    for item in keys["items"]:
        caps = "".join(f"<kbd>{key.replace('{space}', keys['space'])}</kbd>" for key in item["keys"])
        block.append(f'      <div class="key-cell"><span class="caps">{caps}</span><p><b>{item["title"]}</b>{item["text"]}</p></div>')
    block += ["    </div>", "  </div>", "</section>", ""]
    sections.append(block)

    tools = w["tools"]
    block = ['<section class="section" id="tools" aria-labelledby="tools-title">', '  <div class="wrap">']
    block += ["    " + line for line in section_head(f"Fig 4.0 &nbsp;{tools['fig']}", "tools-title", tools["lede"])]
    block.append('    <ul class="grid grid-3 reveal" role="list">')
    for item, icon in zip(tools["items"], TOOL_ICONS):
        block += [
            '      <li class="cell">',
            f'        <svg class="cell-icon" aria-hidden="true"><use href="#ui-{icon}" /></svg>',
            f"        <h3>{item['title']}</h3>",
            f"        <p>{item['text']}</p>",
            "      </li>",
        ]
    block += ["    </ul>", "  </div>", "</section>", ""]
    sections.append(block)

    services = w["services"]
    block = ['<section class="section" id="services" aria-labelledby="services-title">', '  <div class="wrap">']
    block += ["    " + line for line in section_head(f"Fig 5.0 &nbsp;{services['fig']}", "services-title", services["lede"])]
    block.append('    <ul class="grid grid-3 providers reveal" role="list">')
    for item in services["items"]:
        block += [
            '      <li class="cell">',
            f'        <h3>{item["title"]} <span class="tag">{item["tag"]}</span></h3>',
            f"        <p>{item['text']}</p>",
            "      </li>",
        ]
    block += [
        "    </ul>",
        f'    <p class="privacy reveal"><svg aria-hidden="true"><use href="#ui-lock" /></svg><span>{services["privacy"]}</span></p>',
        "  </div>",
        "</section>",
        "",
    ]
    sections.append(block)

    langs = w["langs"]
    names = sorted(locales, key=lambda other: other is not loc)
    block = [
        '<section class="section" id="languages" aria-labelledby="languages-title">',
        '  <div class="wrap lang-layout">',
        '    <div class="reveal">',
    ]
    block += ["      " + line for line in section_head(f"Fig 6.0 &nbsp;{langs['fig']}", "languages-title", langs["lede"],
                                                      langs["body"], reveal=False)]
    block.append('      <ul class="lang-list" role="list">')
    for other in names:
        attr = "" if other is loc else f' lang="{other["code"]}"'
        block.append(f'        <li{attr}>{other["name"]} <small>{CODES[other["code"]]}</small></li>')
    block += [
        "      </ul>",
        "    </div>",
        '    <figure class="reveal" style="--d: 150">',
        "PART:matrix:6",
        f'      <figcaption class="matrix-caption">{langs["caption"]}</figcaption>',
        "    </figure>",
        "  </div>",
        "</section>",
        "",
    ]
    sections.append(block)

    changes = w["changes"]
    block = ['<section class="section" id="changes" aria-labelledby="changes-title">', '  <div class="wrap">']
    block += ["    " + line for line in section_head(f"Fig 7.0 &nbsp;{changes['fig']}", "changes-title", changes["lede"])]
    block.append('    <div class="notes reveal">')
    for release in site["release"]:
        block += [
            '      <article class="note">',
            f'        <p class="note-meta"><b>{release["version"]}</b><time datetime="{release["date"]}">{day(w, release["date"])}</time></p>',
            "        <ul>",
        ]
        block += [f"          <li>{note}</li>" for note in changes["notes"][release["version"]][:2]]
        block += ["        </ul>", "      </article>"]
    block += [
        "    </div>",
        f'    <p class="reveal" style="margin-top: 28px"><a class="link-arrow" href="{repo}/blob/main/CHANGELOG.md">{changes["full"]}</a></p>',
        "  </div>",
        "</section>",
        "",
    ]
    sections.append(block)

    act = w["activation"]
    block = ['<section class="section" id="activation" aria-labelledby="activation-title">', '  <div class="wrap">']
    block += ["    " + line for line in section_head(f"Fig 8.0 &nbsp;{act['fig']}", "activation-title", act["lede"])]
    block += [
        '    <div class="license reveal">',
        '      <div class="license-code">',
        f'        <p class="code-line" aria-label="{esc(act["code_label"])}">TR<span>-</span>XXXX<span>-</span>XXXX<span>-</span>XXXX<span>-</span>XXXX<span>-</span>XXXX<span>-</span>XXXX</p>',
        '        <div class="license-price">',
        f"          <b>{act['license']}</b>",
        f"          <span>{act['where']}</span>",
        "        </div>",
        '        <div class="license-actions">',
        f'          <a class="button" href="{repo}/discussions">{act["ask"]}</a>',
        f'          <a class="link-arrow" href="{link(loc, False, loc, True, "#activate")}">{act["how"]}</a>',
        "        </div>",
        "      </div>",
        '      <ul class="license-list" role="list">',
    ]
    for n, item in enumerate(act["items"]):
        icon = "xmark" if n == len(act["items"]) - 1 else "check"
        block.append(f'        <li><svg aria-hidden="true"><use href="#ui-{icon}" /></svg><span>{item}</span></li>')
    block += ["      </ul>", "    </div>", "  </div>", "</section>", ""]
    sections.append(block)

    faq = w["faq"]
    block = ['<section class="section" id="faq" aria-labelledby="faq-title">', '  <div class="wrap faq-layout">']
    block += ["    " + line for line in section_head(f"Fig 9.0 &nbsp;{faq['fig']}", "faq-title", faq["lede"])]
    block.append('    <div class="faq reveal">')
    for item in faq["items"]:
        block += ["      <details>", f"        <summary>{item['q']}</summary>", f"        <p>{fill(item['a'])}</p>", "      </details>"]
    block += ["    </div>", "  </div>", "</section>", ""]
    sections.append(block)

    closing = w["closing"]
    meta = "".join(f"<span>{fill(item)}</span>" for item in closing["meta"])
    sections.append([
        '<section class="closing" aria-labelledby="closing-title">',
        '  <div class="wrap reveal">',
        '    <span class="f1" aria-hidden="true">F1</span>',
        f'    <h2 class="hero-title" id="closing-title">{closing["title"]}</h2>',
        f'    <p class="hero-lead">{closing["lead"]}</p>',
        '    <div class="hero-actions">',
        f'      <a class="button" href="{download}"><svg aria-hidden="true"><use href="#ui-download" /></svg>{u["download_mac"]}</a>',
        f'      <a class="link-arrow" href="{repo}">{closing["source"]}</a>',
        "    </div>",
        f'    <p class="hero-meta">{meta}</p>',
        "  </div>",
        "</section>",
    ])
    return [line for block in sections for line in block]


def guide_main(loc, w):
    u, g = w["ui"], w["guide"]
    out = [
        '<section class="guide-hero" aria-labelledby="guide-title">',
        "  <span data-top></span>",
        '  <div class="wrap">',
        f'    <nav class="crumbs load" aria-label="{esc(u["breadcrumb"])}"><a href="{link(loc, True, loc)}">Transeen</a><span aria-hidden="true">/</span><span aria-current="page">{g["name"]}</span></nav>',
        f'    <h1 class="load" id="guide-title" style="--d: 60">{g["title"]}</h1>',
        f'    <p class="hero-lead load" style="--d: 140">{g["lead"]}</p>',
        '    <div class="hero-actions load" style="--d: 220">',
        f'      <a class="button" href="{download}"><svg aria-hidden="true"><use href="#ui-download" /></svg>{u["download_mac"]}</a>',
        f'      <a class="link-arrow" href="#shortcuts">{g["all_shortcuts"]}</a>',
        "    </div>",
        "  </div>",
        "</section>",
        "",
        '<div class="wrap guide">',
        '  <nav class="toc" aria-labelledby="toc-title">',
        f'    <p id="toc-title">{g["toc"]}</p>',
        "    <ol>",
    ]
    out += [f'      <li><a href="#{section["id"]}">{plain(section["title"])}</a></li>' for section in g["sections"]]
    out += ["    </ol>", "  </nav>", "", '  <article class="doc">']
    for n, section in enumerate(g["sections"]):
        sid = section["id"]
        out.append(f'    <section id="{sid}" aria-labelledby="{sid}-title">')
        out.append(f'      <h2 id="{sid}-title"><small>{n + 1:02d}</small>{section["title"]}</h2>')
        # Lines inside <pre> keep their own indentation: a leading NUL tells expand() so.
        inside = False
        for line in fill(section["body"]).strip().splitlines():
            out.append("\0" + line if inside else "      " + line)
            inside = (inside or "<pre>" in line) and "</pre>" not in line
        out += ["    </section>", ""]
    out[-1:] = [
        "  </article>",
        "</div>",
        "",
        '<section class="guide-next" aria-labelledby="next-title">',
        '  <div class="wrap">',
        f'    <h2 id="next-title">{fill(g["next_title"])}</h2>',
        f"    <p>{g['next_text']}</p>",
        '    <div class="hero-actions">',
        f'      <a class="button" href="{download}"><svg aria-hidden="true"><use href="#ui-download" /></svg>{u["download_mac"]}</a>',
        f'      <a class="link-arrow" href="{link(loc, True, loc)}">{g["back"]}</a>',
        "    </div>",
        "  </div>",
        "</section>",
    ]
    return out


def expand(block, indent):
    """Indents a page body and turns PART:name:n lines into empty part markers."""
    out = []
    for line in block:
        if line.startswith("\0"):
            out.append(line[1:])
        elif line.startswith("PART:"):
            _, name, pad = line.split(":")
            out.append(part(name, indent + int(pad)))
        else:
            out.append(" " * indent + line if line else line)
    return "\n".join(out)


def page(loc, guide):
    w = words[loc["code"]]
    graph = guide_graph(loc, w) if guide else home_graph(loc, w)
    body = guide_main(loc, w) if guide else home_main(loc, w)
    return "\n".join([
        "<!doctype html>",
        f'<html lang="{loc["lang"]}">',
        "  <head>",
        head(loc, guide, w, graph),
        "  </head>",
        "  <body>",
        part("sprite", 4),
        f'    <a class="skip" href="#main">{w["ui"]["skip"]}</a>',
        header(loc, guide, w),
        "",
        '    <main id="main">',
        expand(body, 6),
        "    </main>",
        "",
        footer(loc, guide, w),
        f'    <script src="{up(loc, guide)}assets/site.js" defer></script>',
        "  </body>",
        "</html>",
        "",
    ])


# Site-wide files

def sitemap():
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">']
    for guide in (False, True):
        for loc in locales:
            out += ["  <url>", f"    <loc>{address(loc, guide)}</loc>", f"    <lastmod>{site['modified']}</lastmod>"]
            out.append(f"    <image:image><image:loc>{image_of(loc)}</image:loc></image:image>")
            if not guide:
                out.append(f"    <image:image><image:loc>{origin}/assets/preview{loc['suffix']}.webp</image:loc></image:image>")
            for other in locales:
                out += [f'    <xhtml:link rel="alternate" hreflang="{code}" href="{address(other, guide)}" />' for code in other["hreflang"]]
            out.append(f'    <xhtml:link rel="alternate" hreflang="x-default" href="{address(english, guide)}" />')
            out.append("  </url>")
    return "\n".join(out + ["</urlset>", ""])


def llms():
    homes = ", ".join(f"{loc['name']} {address(loc)}" for loc in locales[1:])
    guides = ", ".join(f"{loc['name']} {address(loc, True)}" for loc in locales[1:])
    text = (here / "templates" / "llms.txt").read_text()
    return (text.replace("{version}", version).replace("{size}", site["size_mb"])
            .replace("{homes}", homes).replace("{guides}", guides))


def not_found():
    w = words["en"]
    homes = "\n".join(f'        <a href="/{path(loc)}"{lang_attrs(english, loc)}>{loc["name"]}</a>' for loc in locales)
    return f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    {REDIRECT}
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Page not found | Transeen</title>
    <meta name="robots" content="noindex" />
    <meta name="theme-color" content="#08090a" />
    <meta name="color-scheme" content="dark" />
    <link rel="icon" href="/favicon.ico" sizes="48x48" />
    <link rel="icon" href="/assets/app-icon.svg" type="image/svg+xml" />
    <link rel="preload" href="/assets/fonts/geist-1.8.2.woff2" as="font" type="font/woff2" crossorigin />
    <link rel="stylesheet" href="/assets/site.css" />
  </head>
  <body>
    <header class="nav">
      <div class="wrap nav-inner">
        <a class="brand" href="/" aria-label="Transeen home"><img src="/assets/app-icon.png" width="22" height="22" alt="" />Transeen</a>
        <div class="nav-end">
          <a class="button small" href="{download}">Download</a>
        </div>
      </div>
    </header>
    <main class="lost" id="main">
      <p class="code-line">404 <span>· Nothing to translate here</span></p>
      <h1>This page isn’t here.</h1>
      <p>The address may have changed. Every language’s home page is one click away.</p>
      <div class="hero-actions">
        <a class="button" href="/">Transeen home</a>
        <a class="link-arrow" href="/guide/">{w["ui"]["setup_guide"]}</a>
      </div>
      <nav class="lost-langs" aria-label="Language">
{homes}
      </nav>
    </main>
  </body>
</html>
"""


def share_card():
    titles = {loc["code"]: [loc["lang"], words[loc["code"]]["hero"]["title"]] for loc in locales}
    # The template lives in a folder of its own: every .html directly in scripts/site is a part.
    text = (here / "templates" / "og.html").read_text()
    return text.replace("{titles}", json.dumps(titles, ensure_ascii=False))


for loc in locales:
    for guide in (False, True):
        target = docs / path(loc, guide) / "index.html"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(page(loc, guide))
(docs / "sitemap.xml").write_text(sitemap())
(docs / "llms.txt").write_text(llms())
(docs / "404.html").write_text(not_found())
(here / "og.html").write_text(share_card())
subprocess.run([sys.executable, "-I", str(root / "scripts" / "version-site-assets.py")], check=True)
print(f"wrote {len(locales) * 2} pages in {len(locales)} languages")
