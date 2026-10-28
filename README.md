<p align="center"><img src="docs/assets/app-icon.png" alt="Transeen" width="96" /></p>
<h1 align="center">Transeen</h1>
<p align="center"><strong>Translation, right where it belongs.</strong><br />Capture, annotate, and translate any part of your screen. Native to your Mac.</p>
<p align="center">
  <a href="project.yml"><img src="https://img.shields.io/badge/macOS-26%2B-343b48?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="macOS 26+" /></a>
  <a href="https://github.com/LiuTianjie/Transeen/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/LiuTianjie/Transeen/ci.yml?style=flat-square&amp;label=build" alt="Build" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-64748b?style=flat-square" alt="MIT license" /></a>
</p>
<p align="center">
  <a href="https://github.com/LiuTianjie/Transeen/releases/latest">Download</a> ·
  <a href="https://transeen.itool.tech/">Website</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>
<p align="center"><img src="docs/assets/preview.webp" alt="Transeen native translation rendering and toolbar" width="820" /></p>
<p align="center"><sub>Production rendering and native toolbar, with authored sample content and a fixed translation.</sub></p>

Transeen is a macOS menu bar app that keeps translation close to what you are reading. Select a screen region or open an image, translate the text in place, compare it with the original, then annotate, copy, save, or pin the result.

**The official app requires a Transeen TR- activation code.** Activate this Mac without signing in, or optionally bind the license to your iTool account. The source code is MIT licensed, including commercial use. [Licensing](LICENSING.md).

## What it does

- **Translate in place.** Local Vision OCR, pixel-aware text layout, and original/translation comparison. A full text view keeps longer translations readable.
- **Annotate independently.** Arrows, shapes, pen strokes, and numbered markers stay on a separate layer with undo and redo.
- **Choose a provider.** Apple on-device translation or an OpenAI-compatible local/remote model. Model mode sends recognized text only, not screenshots.
- **Keep a small footprint.** Menu bar access, configurable shortcuts, pinned images, PNG export, and clipboard copy. No screenshot history or continuous capture.
- **Check for updates.** Choose “检查更新…” in the menu bar or launcher to find the latest GitHub release and its download.

## Get started

1. Download the universal Mac app from GitHub Releases, move it to Applications, and open it. Requires macOS 26 or later.
2. Open “激活与账号…” and enter your TR- code. SM- and IT- codes are different products.
3. Allow Screen Recording when prompted, then select your translation languages. Apple may need to download language packs first.
4. Press Control–Option–2 to select a region. Control–Option–3 captures for annotation; Tab compares original and translation.

| Action | Default shortcut |
| --- | --- |
| Capture with the default mode | `⌃⌥2` |
| Capture for annotation | `⌃⌥3` |
| Compare original and translation | `Tab` / `⌃⌥Space` |
| Copy / save PNG | `⌘C` / `⌘S` |
| Undo / redo | `⌘Z` / `⌘⇧Z` |

The current app interface is in Simplified Chinese. Translation supports the languages listed in the app.

## Build from source

Use Xcode 26.4 or later, Swift 6, and XcodeGen.

```sh
brew install xcodegen
./scripts/build.sh
```

The app is written to `dist/Transeen.app`. Without a Developer ID identity, the build uses ad-hoc signing. Set `TRANSEEN_SIGNING_IDENTITY` for a signed local build. Hosted activation access is separate from the MIT source license; configure your own licensing backend for an independent distribution.

```sh
./scripts/test.sh
./scripts/test-license.sh
./scripts/test-lifecycle.sh
```

The tests cover image layout, translation protocol, activation state, version comparisons, and capture lifecycle. Real Apple translation can be checked separately with `TRANSEEN_TEST_APPLE=1 ./scripts/test-lifecycle.sh` after installing the language packs.

## Privacy and limits

Screenshots and OCR stay on the Mac. External model mode sends extracted text to the endpoint you choose. Licensing uses a random installation ID and a Keychain receipt, not hardware serial numbers. Update checks contact GitHub.

Dense layouts, specialist terminology, and formulas can still need correction. Translation quality depends on the provider. Always compare important details with the original.

## License

[MIT](LICENSE) © 2026 LiuTianjie.
