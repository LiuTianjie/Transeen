# Changelog

## 0.8.0

- Add a first-run guide for activation, Screen Recording, translation languages, and shortcuts. It shows which Apple language packs are installed and downloads missing ones before the first capture; Settings lists them too, and model mode gains a connection test.
- Replace the default capture mode with two shortcuts: ⌃⌥2 captures and translates, ⌃⌥3 captures for annotation. Users who had chosen screenshot as the default keep ⌃⌥2 for screenshots.
- Drag a capture's edges or corners to adjust the area. It re-crops the frozen screen, keeps annotations in place, and translates again on release.
- Copy is available while a translation is still running.
- Selection corner marks follow the rounded outline instead of sticking out past it.

## 0.7.0

- Add Transeen activation codes, secure Keychain receipts, and optional iTool account binding and restoration.
- Require activation for capture, image import, annotation, and translation.
- Add manual update checks using GitHub Releases.
- Publish MIT source, bilingual documentation, and the product website.

## 0.6.1

- Fix a crash caused by empty or out-of-bounds OCR pixel regions.
- Improve Retina OCR tiling, text style estimation, inline code preservation, and layout boundaries.
- Refine the launcher spacing and preserve complete translations in the text view.

## 0.6.0

- Fix Apple Translation sessions outliving their SwiftUI download host.
- Handle installed on-device language assets across macOS translation strategies.
