import AppKit
import SwiftUI
import ApplicationServices
import Carbon

@MainActor @Observable
final class ScrollingCaptureSession {
    private(set) var started = false
    private(set) var busy = false
    private(set) var automatic = false
    private(set) var height = 0
    private(set) var count = 0
    private(set) var preview: NSImage?
    private(set) var message = L("框选滚动内容，避开固定侧栏；开始后向下滚动。")
    private(set) var warning = false
    var onFinish: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?
    private let rect: CGRect
    private let display: ScreenCaptureService.Display
    private let application: NSRunningApplication?
    private let stitcher = ScrollStitcher()
    private var controls: NSPanel?
    private var outline: NSPanel?
    private var task: Task<Void, Never>?
    private var stopped = false
    private var finishing = false
    private var failureCount = 0
    private var lastScroll = Date.distantPast
    private var lastProgress = Date()
    private var didAutoScroll = false
    private var cancelKey: EventHotKeyRef?
    private var keyHandler: EventHandlerRef?

    init(rect: CGRect, screen: NSScreen, application: NSRunningApplication?) {
        self.rect = rect; display = ScreenCaptureService.Display(screen); self.application = application
    }
    func show() {
        installCancelKey()
        let outline = NSPanel(contentRect: rect.insetBy(dx: -2, dy: -2), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        outline.isOpaque = false; outline.backgroundColor = .clear; outline.hasShadow = false
        outline.ignoresMouseEvents = true
        outline.level = .screenSaver
        outline.animationBehavior = .none
        outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let border = NSView(frame: CGRect(origin: .zero, size: outline.frame.size))
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.controlAccentColor.cgColor
        border.layer?.borderWidth = 2
        outline.contentView = border
        outline.orderFrontRegardless(); self.outline = outline
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .screenSaver; panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ScrollingCaptureControls(session: self))
        panel.contentView = host
        let size = CGSize(width: 280, height: 390)
        let visible = NSScreen.screens.first { $0.frame == display.frame }?.visibleFrame ?? display.frame
        var x = rect.maxX + 12
        if x + size.width > visible.maxX { x = rect.minX - size.width - 12 }
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        let y = max(visible.minY + 8, min(rect.maxY - size.height, visible.maxY - size.height - 8))
        panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        panel.orderFrontRegardless(); controls = panel
    }
    private func installCancelKey() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x54525343 else { return OSStatus(eventNotHandledErr) }
            let session = Unmanaged<ScrollingCaptureSession>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { session.cancel() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &keyHandler)
        if status == noErr {
            _ = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x54525343, id: 1), GetApplicationEventTarget(), 0, &cancelKey)
        }
    }
    func start() {
        guard !started, !stopped else { return }
        started = true; busy = true
        message = L("正在准备，请稍候…")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await ScreenCaptureService.scrollingSource(rect: rect, display: display)
                while !Task.isCancelled && !stopped {
                    let frame = try await source.capture()
                    guard !Task.isCancelled, !stopped else { return }
                    let update = await stitcher.add(frame)
                    guard !Task.isCancelled, !stopped else { return }
                    receive(update)
                    busy = false
                    if finishing { await complete(); return }
                    if automatic, Date().timeIntervalSince(lastScroll) >= 0.55 {
                        if didAutoScroll && Date().timeIntervalSince(lastProgress) > 2.5 && update.outcome == .unchanged {
                            await complete(); return
                        }
                        scrollTarget()
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch is CancellationError { }
            catch {
                guard !stopped else { return }
                busy = false; automatic = false; warning = true
                message = L("捕获失败：%@", error.localizedDescription)
            }
        }
    }
    private func receive(_ update: ScrollStitcher.Update) {
        height = update.height; count = update.count
        if let image = update.preview { preview = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)) }
        switch update.outcome {
        case .started, .appended:
            failureCount = 0; lastProgress = Date(); warning = false
            message = automatic ? L("正在自动向下滚动…") : L("请缓慢向下滚动，完成后点击完成。")
        case .unchanged:
            if failureCount == 0 { warning = false }
        case .revisiting:
            failureCount = 0; lastProgress = Date(); warning = false
            message = L("已回到之前内容，继续向下滚动即可。")
        case .noMatch:
            failureCount += 1
            warning = true
            message = L("暂时无法对齐，请慢一点或向上滚回上一段；已拼接部分保留。")
            if failureCount >= 3 { automatic = false }
        case .limit:
            automatic = false; warning = true; finishing = true
            message = L("已达到长截图大小上限，正在打开已捕获内容。")
        }
    }
    func toggleAutomatic() {
        if automatic { automatic = false; return }
        guard AXIsProcessTrusted() else {
            let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(prompt)
            warning = true
            message = L("自动滚动需要辅助功能权限；授权后重试，也可以直接手动滚动。")
            return
        }
        automatic = true; didAutoScroll = false; lastProgress = Date()
        application?.activate()
        if !started { start() }
    }
    private func scrollTarget() {
        guard let application, !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            automatic = false
            return
        }
        // Quartz display coordinates use the primary display's top-left origin.
        let top = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY ?? display.frame.maxY
        CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: top - rect.midY))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
        lastScroll = Date(); didAutoScroll = true
    }
    func finish() {
        guard !stopped, !finishing else { return }
        automatic = false; finishing = true
        // Drain one final capture rather than losing the last visible part of the page.
        if task == nil || !started { cancel(); return }
        if warning && !busy {
            task?.cancel()
            Task { [weak self] in await self?.complete() }
        }
    }
    private func complete() async {
        guard !stopped else { return }
        let image = await stitcher.result()
        guard !stopped else { return }
        stop()
        if let image { onFinish?(image) } else { onCancel?() }
    }
    func cancel() { stop(); onCancel?() }
    func stop() {
        stopped = true; automatic = false
        task?.cancel(); task = nil
        controls?.orderOut(nil); controls = nil
        outline?.orderOut(nil); outline = nil
        if let cancelKey { UnregisterEventHotKey(cancelKey); self.cancelKey = nil }
        if let keyHandler { RemoveEventHandler(keyHandler); self.keyHandler = nil }
    }
}

private struct ScrollingCaptureControls: View {
    @Bindable var session: ScrollingCaptureSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("滚动长截图"), systemImage: "arrow.down.to.line.compact").font(.headline)
            Group {
                if let preview = session.preview { Image(nsImage: preview).resizable().scaledToFit() }
                else { Image(systemName: "rectangle.portrait.and.arrow.forward").font(.largeTitle).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity).frame(height: 185)
                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            Text(session.count == 0 ? L("准备开始") : L("已捕获 %ld 段 · %ld px", session.count, session.height))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(session.message).font(.caption).foregroundStyle(session.warning ? Color.orange : .secondary)
                .frame(height: 48, alignment: .topLeading)
            HStack {
                Button(L("取消")) { session.cancel() }
                Spacer()
                if session.started {
                    Button(L("完成")) { session.finish() }.buttonStyle(.borderedProminent).disabled(session.count == 0)
                } else {
                    Button(L("开始")) { session.start() }.buttonStyle(.borderedProminent)
                }
            }
            Button(session.automatic ? L("停止自动滚动") : L("自动向下滚动")) { session.toggleAutomatic() }
                .font(.caption).buttonStyle(.plain).foregroundStyle(.tint)
        }.padding(16).frame(width: 280, height: 390)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
