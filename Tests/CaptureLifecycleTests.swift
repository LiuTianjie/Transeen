import AppKit
import CoreText

@MainActor private final class SlowBackend: TranslationBackend {
    var entered = false
    func cancel() {}
    func translate(_ analysis: ScreenPipeline.Analysis, direction: TranslationDirection, app: String?) async throws -> TranslationOutput {
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
        let automatic = SlowBackend()
        controller.previewSelection(picture, mode: .translate, backend: automatic)
        for _ in 0..<300 {
            if controller.state.translated || controller.state.failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(automatic.entered && controller.state.translated && controller.state.overlay, "Completing a translate selection must produce the translation without any toolbar action")
        precondition(controller.state.automaticallyTranslates && !controller.state.working)
        precondition(controller.handleShortcut(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!))
        precondition(controller.state.peeking && controller.state.overlay && !controller.state.showingTranslation, "Holding peek must temporarily display the original without changing the chosen layer")
        controller.endPeek()
        precondition(controller.state.showingTranslation && !controller.state.peeking, "Releasing peek must restore the translation")
        controller.close()
        let manual = SlowBackend()
        controller.previewSelection(picture, mode: .screenshot, backend: manual)
        try await Task.sleep(for: .milliseconds(250))
        precondition(!manual.entered && !controller.state.automaticallyTranslates && !controller.state.working, "Only explicit screenshot mode should await a manual translation")
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
        controller.action("pin")
        controller.action("copy")
        precondition(controller.isPresenting, "Pinned capture must stay open after copy")
        controller.close()
        controller.preview(picture)
        controller.state.copyCloses = false
        controller.action("copy")
        precondition(controller.isPresenting, "User preference must preserve capture")
        controller.close()
        board.releaseGlobally()
        let suite = "transeen.shortcuts.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("live", forKey: "defaultMode")
        var legacyBindings = ShortcutStore.factory
        legacyBindings["captureLive"] = KeyBinding(18, ScreenModifier.control | ScreenModifier.option)
        legacyBindings["pause"] = KeyBinding(40)
        defaults.set(try JSONEncoder().encode(legacyBindings), forKey: "keyboardShortcuts.v1")
        let settings = AppSettings(defaults: defaults)
        precondition(settings.defaultMode == .translate, "Retired live mode must fall back to screenshot translation")
        precondition(settings.shortcuts.bindings["captureLive"] == nil && settings.shortcuts.bindings["pause"] == nil, "Retired shortcuts must be ignored")
        let keys = settings.shortcuts
        let custom = KeyBinding(40, ScreenModifier.option) // Option-K
        precondition(keys.set(custom, for: .rectangle))
        precondition(!keys.set(custom, for: .ellipse), "Conflicting actions must be rejected")
        precondition(keys.binding(.ellipse) == ShortcutAction.ellipse.defaultBinding)
        precondition(!keys.set(KeyBinding(40), for: .captureDefault), "Plain global letter must not hijack typing")
        precondition(keys.set(nil, for: .save))
        precondition(keys.set(nil, for: .peek))
        let loaded = ShortcutStore(defaults: defaults)
        precondition(loaded.binding(.rectangle) == custom && loaded.binding(.save) == nil, "Changes and disabled bindings must survive relaunch")
        precondition(loaded.binding(.peek) == nil, "A disabled peek key must not be restored by migration")
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
        let uncommon = [ShortcutAction.captureDefault.rawValue: KeyBinding(80, ScreenModifier.control | ScreenModifier.option)] // F19
        precondition(registrar.register(uncommon).isEmpty, "Test hotkey must register")
        precondition(competing.register(uncommon) == [.captureDefault], "Occupied hotkey must report its action")
        registrar.stop()
        precondition(competing.register(uncommon).isEmpty, "Stopping must release the old hotkey")
        competing.stop()
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 800, y: 0), CGPoint(x: 0, y: 600), CGPoint(x: 800, y: 600)] {
            let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
            let hint = ScreenSelectionView.hintRect(at: corner, size: CGSize(width: 240, height: 51), within: bounds)
            precondition(bounds.insetBy(dx: 7, dy: 7).contains(hint), "Selection dimensions must remain visible at screen edges")
        }
        print("CaptureLifecycleTests: copy/close, pin, numbering and clipboard passed; close/reselect reject stale results; original toggle preserves annotations")
        print("ShortcutTests: persistence, disable, conflicts, registration rollback, exact modifiers, recorder suppression and remapped capture dispatch passed")
        print("GlobalShortcuts: native Carbon register, conflict detection and unregister passed")
        print("AutoSelection: no-click translation, explicit manual screenshot mode and visible empty-OCR result passed")
    }
}
