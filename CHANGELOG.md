# Changelog

## 0.11.2

- A picture next to the text, such as a row of screenshot thumbnails, is no longer read as words, erased and covered with a translation ("望开！"). A line the recogniser is unsure of is read again, magnified, and kept only if it reads the same.
- Chinese words inside an English sentence ("defaulting to 简体中文", "the hero counts 已翻译 8 处") are read as Chinese and kept, instead of turning into Latin garbage that was then translated.
- A drawing tool always draws. An arrow started on a number or a box used to pick that mark up and switch to the pointer, so the next stroke dragged the whole capture away instead. The capture now stays where it was taken; only a pin moves with the mouse. With a drawing tool chosen, the picture's edge draws too, and the capture is resized from just outside it.

## 0.11.1

- Every sentence on the screen is translated in place. A long paragraph that a local model did not answer in time is sent again on its own, with more time, instead of keeping its original.
- Code in a bordered pill (`check`) is recognised as code and moves with its sentence. When a translator rewrites the code, the sentence is still translated and the pill is cleared with the rest of the original.
- Letters that reach below the line (g, y, p) are erased with their own line and no longer leave marks in the translation.
- A floating button over the text, such as a scroll-down arrow, no longer turns into stray characters ("r • +") in the translation.
- The capture shortcut freezes the screen as it is, before anything changes: another app's open menu, popover or tooltip stays in the picture, Transeen no longer takes focus from the app you are capturing, and Transeen's own windows stay where they are instead of hiding.
- More misreadings of "I'll" are corrected, and a label without a full stop gets a translation without one.

## 0.11.0

- The interface follows your native language. Choose it in the first-run guide or Settings, and every window, menu and message switches to it: English, 简体中文, 繁體中文, 日本語, 한국어, Français, Deutsch or Español. On first launch it is taken from the Mac's preferred languages.
- A page already in your native language is translated into your other one: English for most readers, Chinese for English readers.
- Translations appear as they arrive. Apple Translation works through the text in groups of 8 and local or remote models report each answer, so the first paragraphs show before the last are done, with a count in the toolbar.
- Windows that Transeen hides while you select an area come back when the capture closes.
- The home window, menu-bar panel, first-run guide and Settings use a native macOS look: coloured symbol tiles, shortcuts drawn as key caps, grouped cards and a translucent background.
- A paragraph in grey quoted text is translated whole again, instead of breaking where a word measured slightly bolder or lighter.
- A flag or coloured icon before a word stays as it is and no longer turns into a bullet ("•France").

## 0.10.0

- Add local translation models. In Settings → Translation, choose 本地翻译模型 and download Index-Translate 2B (recommended, 1.1 GB) or Hy-MT2 1.8B (1.1 GB). The model then runs on this Mac through a bundled llama.cpp server: no account, no network, and captured text never leaves the Mac. It translates developer text and UI labels better than Apple Translation ("bumped" is no longer 碰撞, "push main" is no longer 按下主按钮). Downloads come from ModelScope in mainland China and Hugging Face elsewhere, continue after an interruption, and are checked against a SHA-256 before use. The model loads on the first capture (about 2 seconds), stays ready while you work and is unloaded after 5 idle minutes. Requires an Apple silicon Mac.
- F1 is the default capture shortcut. Capturing for annotation and comparing from anywhere have no shortcut until you set one. Shortcuts saved by earlier versions are not carried over.
- Press R while selecting to capture the last area again. The area is remembered across launches.
- A sentence with code in it is translated whole. The code (`docs/`, `project.yml`, a commit hash) keeps its own pixels and moves with the translation, instead of splitting the sentence into pieces translated on their own.
- File names are kept as they are, including ones the recogniser split after the dot ("project. yml").
- "I'll", "CI" and similar words that the recogniser read with a lowercase l are corrected before translation.
- A disclosure arrow at the end of a line ("Ran 2 commands ›") is no longer translated with the text.

## 0.9.0

- Dragging a capture's edges follows the pointer smoothly. The frozen screen moves as one layer while dragging and is cropped once on release; each drag step used to wait about 0.2 s for the toolbar to animate.
- Pin leaves the capture on screen as a floating picture: drag it anywhere, keep taking new captures, right-click for copy, save, original/translation and close, or press Esc while it is focused.
- Press the translate shortcut (⌃⌥2) again while a result is open to swap the languages; a screenshot that was never translated gets translated. Esc still closes the result.
- Navigation items that the recogniser read as one line ("Products Pricing Docs") are translated one by one again.
- Short table cells stacked in a column are no longer joined into one sentence ("Running" and "Failed" became "运行失败").
- A count at the start of a line is kept as text ("2 minutes ago" lost its "2").
- Chinese and Japanese translations no longer have a space after full-width punctuation.

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
