import AppKit
import CoreText

@MainActor private final class SlowBackend: TranslationBackend {
    var entered = false
    func cancel() {}
    func translate(_ analysis: ScreenPipeline.Analysis, direction: TranslationDirection, app: String?,
                   progress: @escaping TranslationProgress) async throws -> TranslationOutput {
        entered = true
        // Deliberately ignore cancellation: the controller still must reject the stale response.
        try? await Task.sleep(for: .milliseconds(300))
        return TranslationOutput(translations: Dictionary(uniqueKeysWithValues: analysis.blocks.indices.map { ($0, "测试译文") }))
    }
}

@main struct CaptureLifecycleTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let ctx = CGContext(data: nil, width: 600, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 200))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Privacy and security settings", attributes: [.font: NSFont.systemFont(ofSize: 25), .foregroundColor: NSColor.black]))
        ctx.textPosition = CGPoint(x: 30, y: 100); CTLineDraw(line, ctx)
        let picture = NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: 600, height: 200))
        let controller = CaptureController()
        controller.authorize = { true }
        let areaSuite = "transeen.area.tests.\(UUID().uuidString)"
        controller.defaults = UserDefaults(suiteName: areaSuite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: areaSuite) }
        let automatic = SlowBackend()
        controller.previewSelection(picture, mode: .translate, backend: automatic)
        for _ in 0..<300 {
            if controller.state.translated || controller.state.failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(automatic.entered && controller.state.translated && controller.state.overlay, "Completing a translate selection must produce the translation without any toolbar action")
        precondition(controller.state.automaticallyTranslates && !controller.state.working)
        let markedPoint = CGPoint(x: 100, y: 50)
        controller.state.annotations.append(Annotation(tool: .number, points: [markedPoint], color: .red, width: 3, number: 1))
        controller.action("undo")
        let before = controller.previewCrop
        // The fixture stands in for the whole screen; edges snap to its pixel grid.
        let pixelsPerPoint = CGFloat(picture.cgImage(forProposedRect: nil, context: nil, hints: nil)!.width) / before.width
        let dx = (40 * pixelsPerPoint).rounded() / pixelsPerPoint, dy = (30 * pixelsPerPoint).rounded() / pixelsPerPoint
        controller.previewResize([.left, .bottom], by: CGPoint(x: 40, y: 30))
        precondition(controller.previewCrop == CGRect(x: before.minX + dx, y: before.minY + dy, width: before.width - dx, height: before.height - dy),
                     "Dragging a corner must move only its two edges: \(controller.previewCrop)")
        precondition(controller.previewImageSize == controller.previewCrop.size, "The picture must be re-cropped to the new area")
        // The mark was undone before the resize; redoing it must land on the same pixels.
        precondition(controller.state.annotations.marks.isEmpty)
        controller.action("redo")
        let moved = CGPoint(x: markedPoint.x - dx, y: markedPoint.y - dy)
        // Pixel snapping divides by the screen's scale; compare positions, not floating-point bits.
        func near(_ a: CGPoint?, _ b: CGPoint) -> Bool { a.map { abs($0.x - b.x) < 1e-6 && abs($0.y - b.y) < 1e-6 } ?? false }
        precondition(near(controller.state.annotations.marks.first?.points.first, moved), "Undo history must follow the moved origin")
        controller.previewResize([.left], by: CGPoint(x: -dx, y: 0))
        precondition(near(controller.state.annotations.marks.first?.points.first, CGPoint(x: markedPoint.x, y: moved.y)), "Marks must stay over the same pixels when the origin moves")
        precondition(controller.state.working && !controller.state.translated, "A resized translation must be redone, not kept")
        for _ in 0..<300 {
            if controller.state.translated || controller.state.failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(controller.state.translated, "The re-crop must be translated again on release")
        controller.previewResize([.right], by: CGPoint(x: 10_000, y: 0))
        precondition(controller.previewCrop.maxX == before.maxX, "Growing must stop at the frozen frame: \(controller.previewCrop)")
        for _ in 0..<300 {
            if controller.state.translated || controller.state.failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        controller.state.annotations.select(nil)
        precondition(controller.handleShortcut(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!))
        precondition(controller.state.peeking && controller.state.overlay && !controller.state.showingTranslation, "Holding peek must temporarily display the original without changing the chosen layer")
        controller.endPeek()
        precondition(controller.state.showingTranslation && !controller.state.peeking, "Releasing peek must restore the translation")
        precondition(controller.repeatTranslateShortcut(), "The translate shortcut must act on an open result")
        precondition(controller.state.source == .zhHans && controller.state.target == .en && controller.state.working,
                     "Pressing the translate shortcut on a translated result must swap the languages and translate again")
        controller.close()
        precondition(!controller.repeatTranslateShortcut(), "Without a result the translate shortcut starts a new capture")
        let manual = SlowBackend()
        controller.previewSelection(picture, mode: .screenshot, backend: manual)
        try await Task.sleep(for: .milliseconds(250))
        precondition(!manual.entered && !controller.state.automaticallyTranslates && !controller.state.working, "Only explicit screenshot mode should await a manual translation")
        precondition(controller.repeatTranslateShortcut() && controller.state.working && controller.state.source == .en,
                     "The translate shortcut must translate a screenshot that was never translated, in the chosen direction")
        controller.close()
        let screenFrame = NSScreen.main!.frame
        precondition(controller.lastArea == screenFrame, "A capture must remember its area")
        let remembered = CGRect(x: screenFrame.minX + 40, y: screenFrame.minY + 30, width: 240, height: 120)
        controller.lastArea = remembered
        controller.previewSelecting(picture, mode: .screenshot, backend: SlowBackend())
        let r = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                 characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!
        precondition(controller.handleShortcut(r), "R must be handled while selecting")
        for _ in 0..<100 where !controller.isPresenting { try await Task.sleep(for: .milliseconds(20)) }
        precondition(controller.isPresenting && controller.previewCrop == remembered, "R must select the last area: \(controller.previewCrop)")
        precondition(controller.state.shortcuts.binding(.lastArea) == controller.state.shortcuts.binding(.rectangle),
                     "R picks the last area while selecting and the rectangle in a capture")
        precondition(!controller.state.shortcuts.set(KeyBinding(53), for: .lastArea), "Esc closes a selection, so it cannot also pick the last area")
        controller.close()
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 200))
        let blank = NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: 600, height: 200))
        controller.previewSelection(blank, mode: .translate, backend: SlowBackend())
        for _ in 0..<300 {
            if controller.state.noText || controller.state.failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(controller.state.noText && !controller.state.status.isEmpty && !controller.state.working, "Empty OCR must retain its retry state and explanation")
        controller.close()
        if ProcessInfo.processInfo.environment["TRANSEEN_TEST_APPLE"] == "1" {
            // Exercise the original crash: .translationTask finishes and its
            // window disappears before the actual batch starts.
            let provider = TranslationProvider()
            provider.requestDownload(source: AppLanguage.en.translationLanguage, target: AppLanguage.zhHans.translationLanguage)
            for _ in 0..<1500 {
                if provider.isReady { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            precondition(provider.isReady && provider.configuration == nil, "Download host must retire before using an independent session")
            let answers = try await provider.translateBatch(["Privacy and security settings", "Allow access"])
            precondition(answers.count == 2 && answers.allSatisfy { !$0.isEmpty }, "Translation must survive the download host disappearing")
            let again = try await provider.translateBatch(["Choose which applications may read the screen."])
            precondition(!again.isEmpty, "A subsequent batch must not reuse a cancelled session")
            provider.reset()
            controller.previewSelection(picture, mode: .translate, backend: AppleTranslationBackend())
            for _ in 0..<1500 {
                if controller.state.translated || controller.state.failed { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            precondition(controller.state.translated && !controller.state.failed, "Apple automatic selection failed: \(controller.state.status)")
            print("Apple auto-selection: translated without manual action")
            controller.close()
        }
        let backend = SlowBackend()
        let task = Task { await controller.previewTranslation(picture, backend: backend) }
        for _ in 0..<200 {
            if backend.entered { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(backend.entered, "Must actually reach the asynchronous translation")
        controller.close()
        await task.value
        precondition(!controller.state.translated, "Closed capture must reject late translation")
        let next = SlowBackend()
        let task2 = Task { await controller.previewTranslation(picture, backend: next) }
        for _ in 0..<200 {
            if next.entered { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(next.entered)
        controller.preview(picture)
        await task2.value
        precondition(!controller.state.translated, "New capture must reject previous capture's translation")
        controller.action("tool.number")
        precondition(controller.state.annotating && controller.state.annotations.tool == .number, "Number toolbar action must activate stamping")
        controller.action("tool.move")
        precondition(!controller.state.annotating && controller.state.annotations.tool == .move, "Pointer mode must collapse tool styling")
        controller.action("tool.number")
        controller.state.annotations.append(Annotation(tool: .arrow, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 60)], color: .red, width: 3))
        controller.action("toggle")
        precondition(controller.state.annotations.marks.count == 1, "Original toggle must preserve annotations")
        let beforeNudge = controller.state.annotations.selected!
        let leftKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123)!
        precondition(controller.handleShortcut(leftKey))
        precondition(controller.state.annotations.selected?.points.first?.x == beforeNudge.points.first!.x - 1)
        controller.action("undo")
        precondition(controller.state.annotations.selected == beforeNudge)
        let deleteKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 51)!
        precondition(controller.handleShortcut(deleteKey) && controller.state.annotations.marks.isEmpty)
        controller.action("undo")
        precondition(controller.state.annotations.selected == beforeNudge, "Deleting a selected annotation must be undoable")
        controller.close()
        let board = NSPasteboard(name: NSPasteboard.Name("transeen.tests.\(UUID().uuidString)"))
        controller.pasteboard = board
        let busy = SlowBackend()
        let busyTask = Task { await controller.previewTranslation(picture, backend: busy) }
        for _ in 0..<200 {
            if busy.entered { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(controller.state.working)
        controller.action("copy")
        precondition(board.readObjects(forClasses: [NSImage.self])?.count == 1 && controller.state.copyCompleted, "Copy must work while a translation is still running")
        controller.close()
        await busyTask.value
        board.clearContents()
        controller.preview(picture)
        controller.action("copy")
        precondition(board.readObjects(forClasses: [NSImage.self])?.count == 1, "Copy must export an image")
        precondition(controller.state.copyCompleted && controller.state.finishing, "Copy must immediately acknowledge success before closing")
        for _ in 0..<50 {
            if !controller.isPresenting { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        precondition(!controller.isPresenting, "Normal copy should finish after its acknowledgement")
        controller.preview(picture)
        controller.action("copy")
        controller.preview(picture)
        try await Task.sleep(for: .milliseconds(650))
        precondition(controller.isPresenting, "An old copy dismissal must not close a new screenshot")
        controller.close()
        controller.preview(picture)
        let pinnedFrame = controller.previewCrop
        controller.action("pin")
        precondition(!controller.isPresenting && controller.pins.count == 1, "Pinning must end the capture and leave a pinned picture")
        let pinFrame = controller.pins[0].frame
        // Window frames land on the display's pixel grid.
        precondition(abs(pinFrame.minX - pinnedFrame.minX) <= 1 && abs(pinFrame.minY - pinnedFrame.minY) <= 1
                     && abs(pinFrame.width - pinnedFrame.width) <= 1 && abs(pinFrame.height - pinnedFrame.height) <= 1
                     && controller.pins[0].isVisible, "The pin must stay where the capture was")
        controller.preview(picture)
        precondition(controller.isPresenting && controller.pins.count == 1, "A new capture must not close a pin")
        controller.close()
        precondition(controller.pins.count == 1 && controller.pins[0].isVisible, "Closing a capture must not close a pin")
        controller.pins[0].dismiss()
        precondition(controller.pins.isEmpty, "A dismissed pin must be released")
        controller.preview(picture)
        controller.state.copyCloses = false
        controller.action("copy")
        precondition(controller.isPresenting, "User preference must preserve capture")
        controller.close()
        board.releaseGlobally()
        let chinese = Locale(identifier: "zh-Hans-CN")
        precondition(TranslationText.normalize("同步数据。 如果失败， 请重试", locale: chinese) == "同步数据。如果失败，请重试", "No space follows full-width punctuation")
        precondition(TranslationText.normalize("版本 2.0 已发布", locale: chinese) == "版本 2.0 已发布", "Other spaces stay")
        let suite = "transeen.shortcuts.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Shortcuts saved by earlier versions are not carried over: everyone starts from F1.
        defaults.set(try JSONEncoder().encode([ShortcutAction.captureTranslate.rawValue: KeyBinding(19, ScreenModifier.control | ScreenModifier.option)]),
                     forKey: "keyboardShortcuts.v1")
        let settings = AppSettings(defaults: defaults)
        precondition(settings.shortcuts.binding(.captureTranslate) == KeyBinding(122) && settings.shortcuts.binding(.captureScreenshot) == nil
                     && settings.shortcuts.binding(.globalCompare) == nil, "F1 is the only default capture shortcut")
        let keys = settings.shortcuts
        let custom = KeyBinding(40, ScreenModifier.option) // Option-K
        precondition(keys.set(custom, for: .rectangle))
        precondition(!keys.set(custom, for: .ellipse), "Conflicting actions must be rejected")
        precondition(keys.binding(.ellipse) == ShortcutAction.ellipse.defaultBinding)
        precondition(!keys.set(KeyBinding(40), for: .captureTranslate), "Plain global letter must not hijack typing")
        precondition(keys.set(nil, for: .save))
        precondition(keys.set(nil, for: .peek))
        let loaded = ShortcutStore(defaults: defaults)
        precondition(loaded.binding(.rectangle) == custom && loaded.binding(.save) == nil, "Changes and disabled bindings must survive relaunch")
        precondition(loaded.binding(.peek) == nil, "A disabled peek key stays disabled")
        keys.validateGlobals = { _ in "Simulated occupied system shortcut" }
        precondition(!keys.set(KeyBinding(38), for: .rectangle))
        precondition(keys.binding(.rectangle) == custom, "Failed registration must preserve the old setting")
        keys.validateGlobals = nil
        controller.openImage(picture, settings: settings)
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        precondition(!controller.handleShortcut(key(15)), "Old rectangle key must no longer dispatch")
        precondition(!controller.handleShortcut(key(40, [.option, .shift])), "Extra modifiers must not accidentally dispatch")
        precondition(controller.handleShortcut(key(40, .option)))
        precondition(controller.state.annotations.tool == .rectangle && controller.state.annotating)
        keys.recording = .ellipse
        precondition(!controller.handleShortcut(key(40, .option)), "Recording must not trigger a capture command")
        keys.recording = nil
        precondition(keys.set(KeyBinding(38), for: .close))
        precondition(!controller.handleShortcut(key(53)) && controller.isPresenting, "Old Escape binding must be removed")
        precondition(controller.handleShortcut(key(38)) && !controller.isPresenting, "Custom close must close the active session")
        keys.restoreDefaults()
        precondition(keys.bindings == ShortcutStore.factory)
        let registrar = GlobalShortcuts()
        let competing = GlobalShortcuts()
        let uncommon = [ShortcutAction.captureTranslate.rawValue: KeyBinding(80, ScreenModifier.control | ScreenModifier.option)] // F19
        precondition(registrar.register(uncommon).isEmpty, "Test hotkey must register")
        precondition(competing.register(uncommon) == [.captureTranslate], "Occupied hotkey must report its action")
        registrar.stop()
        precondition(competing.register(uncommon).isEmpty, "Stopping must release the old hotkey")
        competing.stop()
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 800, y: 0), CGPoint(x: 0, y: 600), CGPoint(x: 800, y: 600)] {
            let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
            let hint = ScreenSelectionView.hintRect(at: corner, size: CGSize(width: 240, height: 51), within: bounds)
            precondition(bounds.insetBy(dx: 7, dy: 7).contains(hint), "Selection dimensions must remain visible at screen edges")
        }
        for size in [CGSize(width: 34, height: 34), CGSize(width: 300, height: 120), CGSize(width: 40, height: 400)] {
            let rect = CGRect(origin: CGPoint(x: 20, y: 30), size: size)
            let radius = min(ScreenTranslate.windowCornerRadius, min(size.width, size.height) / 6)
            let marks = ScreenSelectionView.cornerMarks(in: rect, radius: radius, length: 12)
            let outline = CGPath(roundedRect: rect.insetBy(dx: -0.01, dy: -0.01), cornerWidth: radius, cornerHeight: radius, transform: nil)
            let points = marks.flattened.cgPath.flattenedPoints
            precondition(!points.isEmpty && points.allSatisfy { outline.contains($0) }, "Corner marks must follow the rounded outline (\(size))")
        }
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let area = CGRect(x: 100, y: 100, width: 100, height: 50)
        precondition(CaptureCrop.resized(area, edges: [.left], by: CGPoint(x: -500, y: 0), within: frame, minimum: 12) == CGRect(x: 0, y: 100, width: 200, height: 50))
        precondition(CaptureCrop.resized(area, edges: [.right, .top], by: CGPoint(x: -500, y: 30), within: frame, minimum: 12) == CGRect(x: 100, y: 100, width: 12, height: 80))
        precondition(CaptureCrop.resized(area, edges: [.bottom], by: CGPoint(x: 0, y: 90), within: frame, minimum: 12) == CGRect(x: 100, y: 138, width: 100, height: 12))
        print("CaptureLifecycleTests: copy/close, copy during translation, pin, numbering and clipboard passed; close/reselect reject stale results; original toggle preserves annotations")
        print("ResizeTests: edge re-crop, clamping, marks and history follow the origin, re-translation on release, rounded corner marks passed")
        print("ShortcutTests: F1 default, earlier settings not carried over, persistence, disable, conflicts, registration rollback, exact modifiers, recorder suppression and remapped capture dispatch passed")
        print("GlobalShortcuts: native Carbon register, conflict detection and unregister passed")
        print("AutoSelection: no-click translation, explicit manual screenshot mode and visible empty-OCR result passed")
    }
}

private extension CGPath {
    var flattenedPoints: [CGPoint] {
        var points: [CGPoint] = []
        applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: points.append(e.points[0])
            case .addQuadCurveToPoint: points.append(e.points[1])
            case .addCurveToPoint: points.append(e.points[2])
            default: break
            }
        }
        return points
    }
}
