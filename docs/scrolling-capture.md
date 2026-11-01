# Scrolling capture implementation

Product references reviewed on 2026-11-01:

- [Snagit scrolling capture](https://www.techsmith.com/snagit/features/screenshot-website/): select a region, start capture, scroll with a preview, stop, then edit the result. Manual capture is an established mode, not a new interaction invented here.
- [Shottr's official guide](https://shottr.cc/kb/scrollingcapture): manual and automatic scrolling, slow-down feedback, native-resolution output, image-height limits, and explicit limitations for animated/sticky content.
- [ShareX scrolling screenshot](https://getsharex.com/docs/scrolling-screenshot) and its [capture manager](https://github.com/ShareX/ShareX/blob/master/ShareX.ScreenCaptureLib/ScrollingCaptureManager.cs): incremental overlap matching, duplicate-frame detection, ignoring fixed edges, and surfaced success/failure states.
- [Apple Vision translation registration](https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest): system-provided image translation alignment.

The implementation uses Apple's registration API and verifies actual overlapping pixels before adding new rows. It does not copy GPL implementation code from ShareX or macshot. Fixed footer rows are held at the end; already-visited content is tracked when the user scrolls back. An unverified frame is never silently used as a new anchor or joined with a gap.

Interaction: select the scrolling content, click Start, scroll down while watching the preview, then Finish. Automatic scrolling is optional and requires macOS Accessibility authorization to send scroll events. The capture controls and outline are excluded from captured pixels. Capture stops at 30,000 pixels or 60 million pixels. Ambiguous alignment pauses automatic scrolling; the user can move back to the overlap, retry, or finish with the portion already captured.

Scope: vertical capture on one display, including Retina resolution. Select the scrolling body rather than stationary sidebars; animated video, parallax, horizontally scrolling content and changing layouts can fail registration. Failure is shown to the user. Tall results retain full-resolution pixels for copy/export; viewing zoom does not resample the export.

Validation completed locally: deterministic full-document pixel comparison, duplicate/reverse scrolling, fixed-footer placement, failed-overlap preservation and size caps; plus a separate native scroll window captured through ScreenCaptureKit at 2x resolution. The live run appended 100/220/380/500-point scroll positions, revisited earlier content without duplication, and excluded an overlapping control panel belonging to the capture process. This does not establish compatibility with every browser, chat app, sticky sidebar or animated page.
