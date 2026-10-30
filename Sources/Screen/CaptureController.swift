import AppKit
import OSLog

@MainActor
final class CaptureController {
    private static let logger = Logger(subsystem: "com.transeen.app", category: "CaptureFlow")
    private(set) var state = CaptureState()
    private(set) var selecting = false
    private var selectors: [ScreenSelectionPanel] = []
    private var selectionFrames: [CGDirectDisplayID: CGImage] = [:]
    private var panel: CapturePanel?
    /// Pictures pinned from earlier captures; `close()` leaves them alone.
    private(set) var pins: [PinnedImagePanel] = []
    private var work: Task<Void, Never>?
    private var generation = 0
    private var monitor: Any?
    private var completionTask: Task<Void, Never>?
    private var heldPeekKey: UInt16?
    private var original = NSImage()
    private var translated: NSImage?
    /// Pixels the result can be re-cropped from (the frozen display, or an opened
    /// image), with the rect in points they cover, and the current crop within it.
    private var cropSource: (image: CGImage, frame: CGRect)?
    private var crop = CGRect.zero
    private var resizeStart: (crop: CGRect, content: CGRect, changed: Bool)?
    private var mode: CaptureMode = .translate
    private var direction = TranslationDirection(source: .en, target: .zhHans)
    private var detectsSource = true
    private var sourceApplication: String?
    private var backend: (any TranslationBackend)?
    private var backendError: String?
    /// What has been translated of the frame being worked on, and how much of it is on screen.
    private var partialTranslations: [Int: String] = [:]
    private var partialDrawn = 0
    private var partialTask: Task<Void, Never>?
    var authorize: () -> Bool = { false }
    var onError: ((String) -> Void)?
    var onReselect: ((CaptureMode) -> Void)?
    /// Called once the selection and result windows are gone.
    var onFinished: (() -> Void)?
    var isActive: Bool { selecting || panel != nil || !selectors.isEmpty }
    var pasteboard = NSPasteboard.general
    var defaults = UserDefaults.standard
    /// The crop is an area of the screen (not an opened picture), worth selecting again.
    private var cropIsScreenArea = false
    /// The area of the last screen capture, in screen points, kept across launches.
    var lastArea: CGRect? {
        get {
            guard let values = defaults.array(forKey: "lastCaptureArea") as? [Double], values.count == 4 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        set {
            if let area = newValue { defaults.set([area.minX, area.minY, area.width, area.height], forKey: "lastCaptureArea") }
            else { defaults.removeObject(forKey: "lastCaptureArea") }
        }
    }
    var isPresenting: Bool { panel != nil }

    func begin(mode: CaptureMode, settings: AppSettings) {
        guard authorize() else { return }
        close()
        guard CGPreflightScreenCaptureAccess() else {
            onError?(L("请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 Transeen，随后重新打开应用。"))
            return
        }
        self.mode = mode
        Self.logger.notice("begin mode=\(mode.rawValue, privacy: .public)")
        direction = TranslationDirection(source: settings.source, target: settings.target)
        detectsSource = settings.detectsSource
        sourceApplication = NSWorkspace.shared.frontmostApplication?.localizedName
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { sourceApplication = nil }
        backendError = nil
        do { backend = try settings.makeBackend() } catch {
            backendError = error.localizedDescription
            if mode != .screenshot { onError?(error.localizedDescription); return }
        }
        state = CaptureState()
        state.shortcuts = settings.shortcuts
        state.automaticallyTranslates = mode != .screenshot
        state.copyCloses = settings.copyCloses
        state.overlay = mode != .screenshot
        updateLanguageState()
        selecting = true
        let token = generation
        for screen in NSScreen.screens {
            let again = lastArea == nil ? "" : state.shortcuts.binding(.lastArea).map { " · " + L("%@ 上次区域", $0.display) } ?? ""
            let selector = ScreenSelectionPanel(screen: screen, title: mode.title + " · " + direction.compactTitle + again)
            selector.onCancel = { [weak self] in self?.close() }
            selector.onDragEnded = { [weak self] rect in self?.selected(rect, screen: screen) }
            selectors.append(selector)
            selector.orderFrontRegardless()
            let display = ScreenCaptureService.Display(screen)
            Task { [weak self, weak selector] in
                guard let image = try? await ScreenCaptureService.captureImage(rectInScreen: display.frame, display: display) else { return }
                guard let self, token == self.generation, self.selecting else { return }
                self.selectionFrames[display.displayID] = image
                selector?.setBackdrop(NSImage(cgImage: image, size: display.frame.size))
                let map = await Task.detached { ScreenRegionMap(image: image, frame: display.frame) }.value
                guard token == self.generation, self.selecting, let map else { return }
                selector?.setRegionMap(map)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        selectors.first?.makeKey()
        installKeys()
    }

    /// Import an existing screenshot. Display points may shrink to the screen,
    /// while the backing pixels and annotation export retain the file's resolution.
    func openImage(_ input: NSImage, settings: AppSettings) {
        guard authorize() else { return }
        close()
        guard input.size.width > 0, input.size.height > 0 else { return }
        mode = .screenshot
        direction = TranslationDirection(source: settings.source, target: settings.target)
        detectsSource = settings.detectsSource
        sourceApplication = nil
        backendError = nil
        do { backend = try settings.makeBackend() } catch { backendError = error.localizedDescription }
        state = CaptureState()
        state.shortcuts = settings.shortcuts
        state.overlay = false
        state.copyCloses = settings.copyCloses
        updateLanguageState()
        let image = (input.copy() as? NSImage) ?? input
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let factor = min(1, (visible.width - 80) / image.size.width, (visible.height - 180) / image.size.height)
        image.size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        original = image
        let rect = CGRect(x: visible.midX - image.size.width / 2, y: visible.midY - image.size.height / 2,
                          width: image.size.width, height: image.size.height)
        present(image, rect: rect, source: image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { ($0, rect) })
        installKeys()
    }

    func close() {
        let wasActive = isActive
        defer { if wasActive { onFinished?() } }
        completionTask?.cancel(); completionTask = nil
        heldPeekKey = nil; state.peeking = false
        generation += 1
        work?.cancel(); work = nil; partialTask?.cancel(); partialTask = nil
        backend?.cancel(); backend = nil
        selectors.forEach { $0.orderOut(nil) }; selectors = []; selecting = false
        panel?.orderOut(nil); panel = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        translated = nil; original = NSImage(); selectionFrames = [:]
        cropSource = nil; resizeStart = nil; cropIsScreenArea = false
    }

    private func present(_ image: NSImage, rect: CGRect, source: (image: CGImage, frame: CGRect)?) {
        cropSource = source
        crop = rect
        let panel = CapturePanel(state: state)
        panel.onAction = { [weak self] in self?.action($0) }
        panel.onResize = { [weak self] phase, edges, delta in self?.resize(phase, edges: edges, by: delta) }
        panel.allowsCropResize = source != nil
        self.panel = panel
        panel.present(image: image, rect: rect)
    }

    /// Dragging the result's edges re-crops the same frozen frame. Marks stay over the
    /// same pixels; a translation of the old area is discarded and redone on release.
    private func resize(_ phase: CaptureResizeHandles.Phase, edges: ResizeEdges, by delta: CGPoint) {
        guard let source = cropSource, let panel, !state.finishing else { return }
        if phase == .began {
            resizeStart = (crop, panel.contentRect, false)
            let shift = CGPoint(x: panel.contentRect.minX - crop.minX, y: panel.contentRect.minY - crop.minY)
            panel.beginLiveCrop(source: source.image, frame: source.frame.offsetBy(dx: shift.x, dy: shift.y))
            return
        }
        guard var start = resizeStart else { return }
        let scale = CGFloat(source.image.width) / max(1, source.frame.width)
        let snapped = CGPoint(x: (delta.x * scale).rounded() / scale, y: (delta.y * scale).rounded() / scale)
        let next = CaptureCrop.resized(start.crop, edges: edges, by: snapped, within: source.frame, minimum: ScreenTranslate.minimumSelection)
        if next != crop {
            if !start.changed {
                generation += 1; work?.cancel(); backend?.cancel(); partialTask?.cancel(); partialTask = nil
                completionTask?.cancel(); completionTask = nil
                state.working = false; state.copyCompleted = false
                translated = nil
                state.translated = false; state.textBlocks = []; state.warning = nil
                state.failed = false; state.noText = false; state.peeking = false
                start.changed = true
                resizeStart = start
            }
            state.annotations.offset(by: CGPoint(x: crop.minX - next.minX, y: crop.minY - next.minY))
            crop = next
            state.cropReadout = "\(Int((next.width * scale).rounded())) × \(Int((next.height * scale).rounded())) px"
            panel.updateLiveCrop(next.offsetBy(dx: start.content.minX - start.crop.minX, dy: start.content.minY - start.crop.minY))
        }
        guard phase == .ended else { return }
        resizeStart = nil
        state.cropReadout = nil
        guard start.changed, let pixels = CaptureCrop.crop(source.image, rect: crop, screenFrame: source.frame) else {
            panel.endLiveCrop(image: nil); return
        }
        original = NSImage(cgImage: pixels, size: crop.size)
        panel.endLiveCrop(image: original)
        if cropIsScreenArea { lastArea = crop }
        if state.overlay { restart() } else { state.status = ""; panel.refreshUI() }
    }

    private func selected(_ selectedRect: CGRect, screen: NSScreen) {
        guard selecting else { return }
        let rect = selectedRect.intersection(screen.frame)
        guard !rect.isNull, rect.width >= ScreenTranslate.minimumSelection, rect.height >= ScreenTranslate.minimumSelection else { close(); return }
        lastArea = rect
        selectors.forEach { $0.orderOut(nil) }; selectors = []; selecting = false
        let display = ScreenCaptureService.Display(screen)
        let frozen = selectionFrames[display.displayID]
        selectionFrames = [:]
        let frame = display.frame
        let token = generation
        let requestedMode = mode
        Self.logger.notice("selection completed mode=\(requestedMode.rawValue, privacy: .public)")
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let image: NSImage
                let source: (image: CGImage, frame: CGRect)?
                if let frozen, let cropped = CaptureCrop.crop(frozen, rect: rect, screenFrame: frame) {
                    image = NSImage(cgImage: cropped, size: rect.size)
                    source = (frozen, frame)
                } else {
                    image = try await ScreenCaptureService.capture(rectInScreen: rect, display: display)
                    source = image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { ($0, rect) }
                }
                guard valid(token) else { return }
                original = image
                state.automaticallyTranslates = requestedMode != .screenshot
                // Commit the automatic state before the toolbar's first frame.
                state.working = state.automaticallyTranslates
                state.status = state.automaticallyTranslates ? L("正在识别与翻译…") : ""
                present(image, rect: rect, source: source)
                cropIsScreenArea = true
                // Translation owns its own task after capture completes. The preview
                // is never left waiting for a toolbar click in automatic modes.
                if state.automaticallyTranslates { restart() }
            } catch { if valid(token) { onError?(error.localizedDescription); close() } }
        }
    }
    /// While selecting: take the area of the last capture again, on whichever screen holds most of it now.
    func selectLastArea() {
        guard selecting, let area = lastArea else { NSSound.beep(); return }
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(area)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let screen = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(screen) > 0 else { NSSound.beep(); return }
        selected(area, screen: screen)
    }

    /// The translate shortcut pressed again while a result is open: translate it if it never
    /// was, otherwise swap the languages. Returns false when there is no result to act on.
    func repeatTranslateShortcut() -> Bool {
        guard panel != nil, !selecting, !state.finishing, resizeStart == nil else { return false }
        action(state.hasTranslatedOnce || state.working ? "direction" : "translate")
        return true
    }
    private func valid(_ token: Int) -> Bool { token == generation && !Task.isCancelled }
    func refreshLanguage() { updateLanguageState(); panel?.refreshUI() }
    private func updateLanguageState() {
        state.source = direction.source
        state.target = direction.target
        state.detectsSource = detectsSource
        state.direction = direction.compactTitle
    }
    private func displayCurrent() {
        panel?.canvas.transition(to: state.showingTranslation ? (translated ?? original) : original)
        state.translated = translated != nil
        panel?.refreshUI()
    }
    private func translateFrame(token: Int) async {
        let frame = original
        var pair = direction
        let automatic = detectsSource
        guard let cg = frame.cgImage(forProposedRect: nil, context: nil, hints: nil), frame.size.width > 0 else {
            state.failed = true; state.working = false; state.status = L("截图读取失败，请重新框选。"); panel?.refreshUI(); return
        }
        state.failed = false; state.noText = false; state.warning = nil
        state.working = true; state.status = L("正在识别文字…"); panel?.refreshUI()
        Self.logger.notice("translation started")
        do {
            let scale = CGFloat(cg.width) / frame.size.width
            let requestedPair = pair
            let analysis = try await Task.detached(priority: .userInitiated) {
                try ScreenPipeline.analyze(cg, scale: scale, source: requestedPair.source, target: requestedPair.target, detectsSource: automatic)
            }.value
            guard valid(token) else { return }
            guard let analysis, analysis.recognized > 0 else {
                Self.logger.notice("recognition returned no text")
                state.noText = true; state.working = false; state.status = L("没有识别到文字，可重新框选或重试。"); panel?.refreshUI(); return
            }
            if let source = analysis.detectedSource {
                pair = TranslationDirection(source: source, target: analysis.redirectedTarget ?? pair.target)
                direction = pair
                updateLanguageState()
            }
            let readingOrder = PreciseTranslation.regions(analysis.blocks.map(\.rect), fits: { _ in true }).flatMap { $0 }
            state.textBlocks = readingOrder.map { CaptureTextBlock(id: $0, original: analysis.blocks[$0].original) }
            let output: TranslationOutput
            state.status = L("正在翻译…"); panel?.refreshUI()
            if pair.source == pair.target || !analysis.blocks.contains(where: { $0.translate }) { output = TranslationOutput() }
            else {
                if let backendError { throw ModelError.message(backendError) }
                guard let backend else { throw ModelError.message(L("翻译服务尚未就绪，请重试。")) }
                let wanted = analysis.blocks.filter(\.translate).count
                partialTranslations = [:]; partialDrawn = 0
                output = try await backend.translate(analysis, direction: pair, app: sourceApplication) { [weak self] sofar in
                    self?.showPartial(sofar, of: analysis, wanted: wanted, token: token)
                }
            }
            partialTask?.cancel(); partialTask = nil
            guard valid(token) else { return }
            let translations = output.translations
            let composed = await Task.detached(priority: .userInitiated) { ScreenPipeline.compose(analysis, translations: translations) }.value
            guard valid(token) else { return }
            guard let picture = composed.pixels.cgImage() else { throw ModelError.message(L("译文画面生成失败，请重试。")) }
            translated = NSImage(cgImage: picture, size: frame.size)
            state.hasTranslatedOnce = true
            state.textBlocks = readingOrder.map { CaptureTextBlock(id: $0, original: analysis.blocks[$0].original, translation: translations[$0]) }
            state.warning = output.warning
            if composed.cut > 0 || composed.placed.count < translations.filter({ $0.value != analysis.blocks[$0.key].original }).count {
                state.warning = [output.warning, L("部分译文超出原位置，请在「文字」中查看全文。")].compactMap { $0 }.joined(separator: " ")
            }
            state.working = false
            Self.logger.notice("translation completed blocks=\(composed.blocks.count, privacy: .public) placed=\(composed.placed.count, privacy: .public) cut=\(composed.cut, privacy: .public)")
            for (reason, indices) in Dictionary(grouping: composed.blocks.indices.filter { composed.blocks[$0].kept != nil }, by: { composed.blocks[$0].kept! }) {
                Self.logger.notice("kept \(reason.rawValue, privacy: .public) blocks=\(indices.map(String.init).joined(separator: ","), privacy: .public)")
            }
            let swap = state.shortcuts.binding(.captureTranslate).map { " · " + L("再按 %@ 交换语言", $0.display) } ?? ""
            state.status = translations.isEmpty ? L("没有需要翻译的文字") + swap : L("已翻译 %ld 处", translations.count) + " · " + state.shortcuts.help(L("按住看原文"), .peek) + swap
            displayCurrent()
        } catch {
            guard valid(token) else { return }
            Self.logger.error("translation failed domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            state.failed = true; state.working = false; state.status = error.localizedDescription; panel?.refreshUI()
        }
    }
    /// Draws what is translated so far, at most every 150 ms, while the rest is on its way.
    private func showPartial(_ sofar: TranslationOutput, of analysis: ScreenPipeline.Analysis, wanted: Int, token: Int) {
        guard valid(token) else { return }
        partialTranslations = sofar.translations
        state.status = L("正在翻译…") + " \(min(wanted, sofar.translations.count + sofar.kept.count))/\(wanted)"; panel?.refreshUI()
        guard partialTask == nil else { return }
        let size = original.size
        partialTask = Task { [weak self] in
            while let self, self.valid(token), self.partialTranslations.count > self.partialDrawn {
                let translations = self.partialTranslations
                self.partialDrawn = translations.count
                let composed = await Task.detached(priority: .userInitiated) { ScreenPipeline.compose(analysis, translations: translations) }.value
                guard self.valid(token), let picture = composed.pixels.cgImage() else { return }
                self.translated = NSImage(cgImage: picture, size: size)
                self.displayCurrent()
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            self?.partialTask = nil
        }
    }
    private func restart() {
        generation += 1; work?.cancel(); backend?.cancel(); partialTask?.cancel(); partialTask = nil
        let token = generation
        state.failed = false; state.noText = false; state.working = true
        state.warning = nil; state.textCopyCompleted = false
        state.status = L("正在识别与翻译…"); panel?.refreshUI()
        work = Task { [weak self] in
            guard let self else { return }
            await translateFrame(token: token)
        }
    }
    func action(_ id: String) {
        if id == "close" { close(); return }
        guard authorize() else { close(); return }
        guard panel != nil, !state.finishing else { return }
        if id == "source.auto" || id.hasPrefix("source.") || id.hasPrefix("target.") {
            if id == "source.auto" { detectsSource = true }
            else if id.hasPrefix("source."), let source = AppLanguage(rawValue: String(id.dropFirst(7))) {
                detectsSource = false
                direction = TranslationDirection(source: source, target: direction.target)
            } else if id.hasPrefix("target."), let target = AppLanguage(rawValue: String(id.dropFirst(7))) {
                direction = TranslationDirection(source: direction.source, target: target)
            } else { return }
            updateLanguageState()
            translated = nil; state.textBlocks = []; displayCurrent(); restart()
            return
        }
        switch id {
        case "peek":
            guard state.translated, state.overlay, !state.peeking else { return }
            state.peeking = true; displayCurrent()
        case "peek.end": endPeek()
        case "tool.rectangle", "tool.ellipse", "tool.arrow", "tool.pen", "tool.move", "tool.number":
            guard let tool = AnnotationTool(rawValue: String(id.dropFirst(5))) else { return }
            panel?.canvas.cancelInteraction()
            state.annotations.select(nil)
            state.annotating = tool != .move
            state.annotations.tool = tool
            panel?.refreshUI(); panel?.makeKey()
        case "layout":
            let token = generation
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.generation == token else { return }
                self.panel?.refreshUI()
            }
        case "annotate":
            panel?.canvas.cancelInteraction()
            state.annotations.select(nil)
            state.annotating.toggle()
            if state.annotating && state.annotations.tool == .move { state.annotations.tool = .pen }
            if !state.annotating { state.annotations.tool = .move }
            panel?.refreshUI()
        case "pin": pin()
        case "reselect": onReselect?(mode)
        case "original": state.overlay = false; displayCurrent()
        case "translation":
            state.overlay = true
            if translated == nil { restart() } else { displayCurrent() }
        case "close": close()
        case "toggle": state.overlay.toggle(); displayCurrent()
        case "translate":
            guard !state.working else { return }
            state.overlay = true; restart()
        case "direction":
            detectsSource = false
            direction = direction.reversed; updateLanguageState()
            translated = nil; state.textBlocks = []; displayCurrent(); restart()
        case "undo": state.annotations.undo()
        case "redo": state.annotations.redo()
        case "delete": state.annotations.deleteSelected()
        case "copyText":
            guard !state.textBlocks.isEmpty else { return }
            let text = state.textBlocks.map { $0.translation ?? $0.original }.joined(separator: "\n\n")
            pasteboard.clearContents()
            state.textCopyCompleted = pasteboard.setString(text, forType: .string)
        case "copy":
            // Whatever is on screen right now; a running translation never blocks copying.
            guard resizeStart == nil, let image = export() else { return }
            pasteboard.clearContents()
            if pasteboard.writeObjects([image]) {
                completionTask?.cancel()
                state.copyCompleted = true
                panel?.refreshUI()
                let token = generation
                if state.copyCloses {
                    state.finishing = true
                    completionTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
                        guard let self, self.valid(token), let panel = self.panel else { return }
                        await panel.finishCopy()
                        guard self.valid(token) else { return }
                        self.close()
                    }
                } else {
                    completionTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(1100)) } catch { return }
                        guard let self, self.valid(token) else { return }
                        self.state.copyCompleted = false
                    }
                }
            } else { state.failed = true; state.status = L("未能复制图片，请重试"); panel?.refreshUI() }
        case "save": save()
        default: break
        }
    }
    private func export() -> NSImage? { state.annotations.export(state.showingTranslation ? (translated ?? original) : original) }
    /// Leave what is on screen as a pinned picture and end this capture, so the next one can start.
    private func pin() {
        guard let panel, resizeStart == nil, let shown = export() else { return }
        let translation = state.showingTranslation && translated != nil
        let other = translated.flatMap { state.annotations.export(translation ? original : $0) }
        let pinned = PinnedImagePanel(image: shown, alternate: other, showsTranslation: translation, rect: panel.contentRect)
        pinned.onClose = { [weak self] closed in self?.pins.removeAll { $0 === closed } }
        pins.append(pinned)
        pinned.show()
        close()
    }
    private func save() {
        guard let image = export(), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        let picker = NSSavePanel()
        picker.allowedContentTypes = [.png]
        picker.nameFieldStringValue = "Transeen-\(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-" )).png"
        NSApp.activate(ignoringOtherApps: true)
        let token = generation
        picker.begin { [weak self] result in
            guard result == .OK, let url = picker.url else { return }
            do {
                try png.write(to: url, options: .atomic)
                if let self, self.generation == token {
                    self.state.failed = false; self.state.status = L("已保存图片"); self.panel?.refreshUI()
                }
            }
            catch { self?.onError?(error.localizedDescription) }
        }
    }
    private func installKeys() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyUp, self.heldPeekKey == event.keyCode { self.endPeek(); return nil }
            if event.type == .flagsChanged, self.heldPeekKey != nil,
               let binding = self.state.shortcuts.binding(.peek),
               UInt64(event.modifierFlags.rawValue) & binding.flags != binding.flags { self.endPeek() }
            guard event.type == .keyDown else { return event }
            // Number/color editors keep their own typing, deletion and text undo.
            if event.window?.firstResponder is NSTextView { return event }
            // A focused pin takes its own Esc and ⌘C.
            if event.window is PinnedImagePanel { return event }
            if self.heldPeekKey == event.keyCode, event.isARepeat { return nil }
            // Do not steal editing keys from settings or save panels.
            guard self.selecting || event.window is CapturePanel || event.window?.styleMask.contains(.nonactivatingPanel) == true else { return event }
            return self.handleShortcut(event) ? nil : event
        }
    }

    @discardableResult func handleShortcut(_ event: NSEvent) -> Bool {
        if selecting, state.shortcuts.action(for: event, group: "框选") == .lastArea { selectLastArea(); return true }
        guard let action = state.shortcuts.action(for: event, group: "截图窗口"), !selecting || action == .close else {
            guard !selecting, state.shortcuts.recording == nil, let selected = state.annotations.selected else { return false }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if [51, 117].contains(event.keyCode), flags.isEmpty { state.annotations.deleteSelected(); return true }
            if (123...126).contains(event.keyCode), flags.isEmpty || flags == .shift {
                let step: CGFloat = flags == .shift ? 10 : 1
                let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
                let dy: CGFloat = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
                state.annotations.update(selected.moved(by: CGPoint(x: dx, y: dy)))
                return true
            }
            return false
        }
        if action == .peek { heldPeekKey = event.keyCode }
        self.action(action.command)
        return true
    }

    func endPeek() {
        heldPeekKey = nil
        guard state.peeking else { return }
        state.peeking = false
        displayCurrent()
    }

    #if DEBUG
    /// Exercise the same completion path as a real selection with deterministic pixels.
    func previewSelection(_ image: NSImage, mode: CaptureMode, backend: any TranslationBackend) {
        previewSelecting(image, mode: mode, backend: backend)
        guard let screen = NSScreen.main else { return }
        selected(screen.frame, screen: screen)
    }

    /// A selection waiting for the pointer or a key, over deterministic pixels.
    func previewSelecting(_ image: NSImage, mode: CaptureMode, backend: any TranslationBackend) {
        close()
        guard let screen = NSScreen.main, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        self.mode = mode
        self.backend = backend
        backendError = nil
        direction = TranslationDirection(source: .en, target: .zhHans)
        detectsSource = false
        sourceApplication = nil
        state = CaptureState()
        state.overlay = mode != .screenshot
        updateLanguageState()
        let display = ScreenCaptureService.Display(screen)
        // Treat the fixture as the full frozen screen; choose that entire screen.
        selectionFrames[display.displayID] = cg
        selecting = true
    }

    func previewTranslation(_ image: NSImage, backend: any TranslationBackend) async {
        preview(image)
        self.backend = backend
        await translateFrame(token: generation)
    }
    func preview(_ image: NSImage) {
        close(); state = CaptureState(); state.status = L("截图"); state.direction = "EN → 中文"
        direction = TranslationDirection(source: .en, target: .zhHans)
        detectsSource = false; sourceApplication = nil; updateLanguageState()
        original = image
        backend = AppleTranslationBackend()
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let rect = CGRect(x: visible.midX - image.size.width / 2, y: visible.midY - image.size.height / 2, width: image.size.width, height: image.size.height)
        present(image, rect: rect, source: image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { ($0, rect) })
        installKeys()
    }

    /// The edge drag a pointer would perform, for tests.
    func previewResize(_ edges: ResizeEdges, by delta: CGPoint) {
        resize(.began, edges: edges, by: .zero)
        resize(.changed, edges: edges, by: CGPoint(x: delta.x / 2, y: delta.y / 2))
        resize(.ended, edges: edges, by: delta)
    }
    var previewCrop: CGRect { crop }
    var previewImageSize: CGSize { original.size }
    #endif
}
