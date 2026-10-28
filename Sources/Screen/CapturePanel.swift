import AppKit
import SwiftUI

struct CaptureTextBlock: Identifiable {
    let id: Int
    let original: String
    var translation: String?
}

@MainActor @Observable
final class CaptureState {
    var shortcuts = ShortcutStore()
    var overlay = true
    var translated = false
    var working = false
    var status = ""
    var direction = ""
    var source: AppLanguage = .en
    var target: AppLanguage = .zhHans
    var detectsSource = true
    var textBlocks: [CaptureTextBlock] = []
    var textCopyCompleted = false
    var warning: String?
    var annotating = false
    var requestsNumberEdit = false
    var pinned = false
    var copyCloses = true
    var failed = false
    var automaticallyTranslates = false
    var noText = false
    var peeking = false
    var hasTranslatedOnce = false
    var copyCompleted = false
    var finishing = false
    var compactProgress: Bool { working && !hasTranslatedOnce && !annotating && annotations.selectedID == nil }
    var showingTranslation: Bool { overlay && !peeking }
    let annotations = AnnotationStore()
}

final class CapturePanel: NSPanel, NSWindowDelegate {
    let canvas: AnnotationCanvas
    let state: CaptureState
    private let border = ScreenPinBorderView()
    private let chromePanel: NSPanel
    private let hosting: NSHostingView<CaptureToolbar>
    var onAction: ((String) -> Void)?

    init(state: CaptureState) {
        self.state = state
        canvas = AnnotationCanvas(annotations: state.annotations)
        canvas.onEditNumber = { [weak state] in state?.requestsNumberEdit = true }
        hosting = ClearHostingView(rootView: CaptureToolbar(state: state, action: { _ in }))
        chromePanel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for panel in [self, chromePanel] {
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        title = "截图预览"
        chromePanel.title = "截图工具栏"
        // A transparent, resizing panel gets a stale WindowServer shadow contour.
        // The opaque surface supplies its own boundary; don't shadow the window.
        chromePanel.hasShadow = false
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = root
        root.addSubview(canvas)
        root.addSubview(border)
        chromePanel.contentView = hosting
        hosting.rootView = CaptureToolbar(state: state) { [weak self] in self?.onAction?($0) }
        addChildWindow(chromePanel, ordered: .above)
        delegate = self
        chromePanel.delegate = self
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    func present(image: NSImage, rect: CGRect) {
        setFrame(rect.insetBy(dx: -4, dy: -4), display: true)
        canvas.frame = CGRect(origin: CGPoint(x: 4, y: 4), size: rect.size)
        border.frame = canvas.frame
        canvas.image = image
        orderFrontRegardless()
        chromePanel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        refreshUI()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                chromePanel.animator().alphaValue = 1
            }
        }
        makeKey()
    }
    func refreshUI() {
        border.setWorking(state.working)
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? frame
        let x = max(visible.minX + 8, min(frame.midX - size.width / 2, visible.maxX - size.width - 8))
        var y = frame.minY - size.height - 8
        if y < visible.minY + 4 { y = min(frame.maxY + 8, visible.maxY - size.height - 4) }
        let nextFrame = CGRect(x: x, y: y, width: size.width, height: size.height)
        let animate = chromePanel.isVisible && chromePanel.frame.size != size && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        chromePanel.setFrame(nextFrame, display: true, animate: animate)
        hosting.frame = CGRect(origin: .zero, size: size)
        chromePanel.orderFrontRegardless()
    }
    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === self { refreshUI() }
    }
    func windowDidResignKey(_ notification: Notification) { onAction?("peek.end") }
    func finishCopy() async {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            chromePanel.animator().alphaValue = 0
            self.animator().alphaValue = 0
        }
    }
    override func orderOut(_ sender: Any?) { chromePanel.orderOut(sender); super.orderOut(sender) }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.22 }
}
