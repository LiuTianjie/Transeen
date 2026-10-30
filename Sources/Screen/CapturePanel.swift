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
    var copyCloses = true
    var failed = false
    var automaticallyTranslates = false
    var noText = false
    var peeking = false
    var hasTranslatedOnce = false
    var copyCompleted = false
    var finishing = false
    /// The crop's pixel size while an edge is dragged. Not `status`, which re-measures the toolbar.
    var cropReadout: String?
    var compactProgress: Bool { working && !hasTranslatedOnce && !annotating && annotations.selectedID == nil }
    var showingTranslation: Bool { overlay && !peeking }
    let annotations = AnnotationStore()
}

final class CapturePanel: NSPanel, NSWindowDelegate {
    /// Transparent room around the picture where the resize handles sit.
    static let margin: CGFloat = 8
    let canvas: AnnotationCanvas
    let state: CaptureState
    private let border = ScreenPinBorderView()
    private let handles = CaptureResizeHandles()
    /// The whole frozen frame as one layer while an edge is dragged; the crop is
    /// only where it is clipped, so the pointer never waits for pixels to be copied.
    private let liveView = NSView()
    private let liveImage = CALayer()
    private var liveFrame: CGRect?
    private let chromePanel: NSPanel
    private let hosting: NSHostingView<CaptureToolbar>
    var onAction: ((String) -> Void)?
    var onResize: ((CaptureResizeHandles.Phase, ResizeEdges, CGPoint) -> Void)? {
        get { handles.onResize }
        set { handles.onResize = newValue }
    }
    var allowsCropResize: Bool {
        get { handles.isEnabled }
        set { handles.isEnabled = newValue }
    }
    /// The picture's frame on screen.
    private(set) var contentRect = CGRect.zero

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
        title = L("截图预览")
        chromePanel.title = L("截图工具栏")
        // A transparent, resizing panel gets a stale WindowServer shadow contour.
        // The opaque surface supplies its own boundary; don't shadow the window.
        chromePanel.hasShadow = false
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = root
        liveView.wantsLayer = true
        liveView.clipsToBounds = true
        liveView.layer?.addSublayer(liveImage)
        liveImage.contentsGravity = .resize
        liveImage.magnificationFilter = .nearest
        liveView.isHidden = true
        root.addSubview(liveView)
        root.addSubview(canvas)
        root.addSubview(border)
        handles.margin = Self.margin
        handles.isBusy = { [weak state] in state?.finishing ?? true }
        root.addSubview(handles)
        chromePanel.contentView = hosting
        hosting.rootView = CaptureToolbar(state: state) { [weak self] in self?.onAction?($0) }
        addChildWindow(chromePanel, ordered: .above)
        delegate = self
        chromePanel.delegate = self
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    func present(image: NSImage, rect: CGRect) {
        place(rect)
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
    /// Start dragging an edge: the window grows to the whole frozen frame (`frame`,
    /// in screen points) and stays put, so only layers move until `endLiveCrop`.
    func beginLiveCrop(source: CGImage, frame sourceFrame: CGRect) {
        let content = contentRect
        liveFrame = sourceFrame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        liveImage.contents = source
        CATransaction.commit()
        liveView.isHidden = false
        canvas.showsImage = false
        setFrame(sourceFrame.union(content).insetBy(dx: -Self.margin, dy: -Self.margin), display: false)
        place(content)
        positionChrome()
    }
    /// A new crop while the edge is dragged.
    func updateLiveCrop(_ rect: CGRect) {
        place(rect)
        positionChrome()
    }
    /// The drag is over: show `image`, the pixels of the final crop, in a window its own size again.
    func endLiveCrop(image: NSImage?) {
        guard liveFrame != nil else { return }
        liveFrame = nil
        if let image { canvas.replace(image) }
        canvas.showsImage = true
        liveView.isHidden = true
        place(contentRect)
        liveImage.contents = nil
        refreshUI()
    }
    private func place(_ rect: CGRect) {
        contentRect = rect
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if liveFrame == nil { setFrame(rect.insetBy(dx: -Self.margin, dy: -Self.margin), display: false) }
        let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        canvas.frame = local
        border.frame = local
        border.needsLayout = true
        liveView.frame = local
        if let liveFrame {
            liveImage.frame = CGRect(origin: CGPoint(x: liveFrame.minX - rect.minX, y: liveFrame.minY - rect.minY), size: liveFrame.size)
        }
        handles.frame = local.insetBy(dx: -Self.margin, dy: -Self.margin)
        handles.needsDisplay = true
        displayIfNeeded()
        CATransaction.commit()
    }
    func refreshUI() {
        border.setWorking(state.working)
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        // An animated frame change blocks until it finishes; never while the pointer drags.
        let animate = liveFrame == nil && chromePanel.isVisible && chromePanel.frame.size != size && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        chromePanel.setFrame(chromeFrame(size: size), display: true, animate: animate)
        hosting.frame = CGRect(origin: .zero, size: size)
        chromePanel.orderFrontRegardless()
    }
    /// Follow the picture without measuring the toolbar again.
    private func positionChrome() {
        guard chromePanel.isVisible else { return }
        chromePanel.setFrameOrigin(chromeFrame(size: chromePanel.frame.size).origin)
    }
    private func chromeFrame(size: CGSize) -> CGRect {
        let content = contentRect
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: content.midX, y: content.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? content
        let x = max(visible.minX + 8, min(content.midX - size.width / 2, visible.maxX - size.width - 8))
        var y = content.minY - size.height - 12
        if y < visible.minY + 4 { y = min(content.maxY + 12, visible.maxY - size.height - 4) }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self else { return }
        // Dragged by the picture; while an edge is dragged the window spans the frozen frame instead.
        if liveFrame == nil { contentRect = frame.insetBy(dx: Self.margin, dy: Self.margin) }
        refreshUI()
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

/// Edges and corners of the result that re-crop it from the frozen screen. Only the
/// band along the border takes the mouse; the picture keeps every other click.
final class CaptureResizeHandles: NSView {
    enum Phase { case began, changed, ended }
    var onResize: ((Phase, ResizeEdges, CGPoint) -> Void)?
    var isBusy: () -> Bool = { false }
    var isEnabled = false { didSet { needsDisplay = true } }
    var margin: CGFloat = 8
    private var hovering = false
    private var cursorEdges: ResizeEdges = []
    private var drag: (edges: ResizeEdges, start: CGPoint)?
    /// How far inside the picture an edge can be grabbed, and how far along it a corner reaches.
    private static let inside: CGFloat = 4
    private static let corner: CGFloat = 16

    private var content: CGRect { bounds.insetBy(dx: margin, dy: margin) }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, !isBusy() else { return nil }
        return edges(at: convert(point, from: superview)).isEmpty ? nil : self
    }

    func edges(at p: CGPoint) -> ResizeEdges {
        let c = content
        guard bounds.contains(p), !c.insetBy(dx: Self.inside, dy: Self.inside).contains(p) else { return [] }
        let nearLeft = p.x <= c.minX + Self.inside, nearRight = p.x >= c.maxX - Self.inside
        let nearBottom = p.y <= c.minY + Self.inside, nearTop = p.y >= c.maxY - Self.inside
        var edges: ResizeEdges = []
        if nearLeft || ((nearBottom || nearTop) && p.x <= c.minX + Self.corner && p.x < c.midX) { edges.insert(.left) }
        else if nearRight || ((nearBottom || nearTop) && p.x >= c.maxX - Self.corner) { edges.insert(.right) }
        if nearBottom || ((nearLeft || nearRight) && p.y <= c.minY + Self.corner && p.y < c.midY) { edges.insert(.bottom) }
        else if nearTop || ((nearLeft || nearRight) && p.y >= c.maxY - Self.corner) { edges.insert(.top) }
        return edges
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) {
        hovering = false; needsDisplay = true
        if drag == nil { setCursor([]) }
    }
    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        let available = isEnabled && !isBusy()
        if !hovering { hovering = true; needsDisplay = true }
        setCursor(available ? edges(at: convert(event.locationInWindow, from: nil)) : [])
    }
    override func mouseDown(with event: NSEvent) {
        let edges = edges(at: convert(event.locationInWindow, from: nil))
        guard !edges.isEmpty else { return }
        window?.makeKey()
        drag = (edges, NSEvent.mouseLocation)
        setCursor(edges)
        onResize?(.began, edges, .zero)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = NSEvent.mouseLocation
        onResize?(.changed, drag.edges, CGPoint(x: point.x - drag.start.x, y: point.y - drag.start.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        let point = NSEvent.mouseLocation
        onResize?(.ended, drag.edges, CGPoint(x: point.x - drag.start.x, y: point.y - drag.start.y))
        needsDisplay = true
        setCursor(edges(at: convert(event.locationInWindow, from: nil)))
    }

    private func setCursor(_ edges: ResizeEdges) {
        guard edges != cursorEdges else { return }
        cursorEdges = edges
        let position: NSCursor.FrameResizePosition? = switch edges {
        case [.left]: .left
        case [.right]: .right
        case [.top]: .top
        case [.bottom]: .bottom
        case [.left, .top]: .topLeft
        case [.right, .top]: .topRight
        case [.left, .bottom]: .bottomLeft
        case [.right, .bottom]: .bottomRight
        default: nil
        }
        (position.map { NSCursor.frameResize(position: $0, directions: .all) } ?? .arrow).set()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isEnabled else { return }
        // Fully transparent window pixels pass clicks to the app beneath. Two units of
        // alpha keep the outer band grabbable without being visible.
        let band = NSBezierPath(rect: bounds)
        band.append(NSBezierPath(rect: content))
        band.windingRule = .evenOdd
        NSColor(white: 0.5, alpha: 2.0 / 255).setFill(); band.fill()
        guard hovering || drag != nil, !isBusy() else { return }
        // Corner handles sit on the rounded border at 45°, matching ScreenPinBorderView.
        let c = content.insetBy(dx: 1.2, dy: 1.2)
        let r = min(ScreenTranslate.windowCornerRadius, c.width / 2, c.height / 2)
        let inset = r * (1 - 1 / 2.squareRoot())
        var points = [CGPoint(x: c.minX + inset, y: c.minY + inset), CGPoint(x: c.maxX - inset, y: c.minY + inset),
                      CGPoint(x: c.maxX - inset, y: c.maxY - inset), CGPoint(x: c.minX + inset, y: c.maxY - inset)]
        if c.width >= 64 { points += [CGPoint(x: c.midX, y: c.minY), CGPoint(x: c.midX, y: c.maxY)] }
        if c.height >= 64 { points += [CGPoint(x: c.minX, y: c.midY), CGPoint(x: c.maxX, y: c.midY)] }
        for point in points {
            let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            NSColor.white.setFill(); dot.fill()
            NSColor.black.withAlphaComponent(0.38).setStroke(); dot.lineWidth = 1; dot.stroke()
        }
    }
}
