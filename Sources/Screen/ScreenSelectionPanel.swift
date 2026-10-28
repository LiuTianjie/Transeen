import AppKit

/// Full-screen, per-display overlay for choosing the area to translate.
/// Hover snaps to the region under the pointer (a card, a field, a paragraph, else the
/// window), drag selects freely, right click or Esc cancels.
final class ScreenSelectionPanel: NSPanel {
    var onDragEnded: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private let canvas: ScreenSelectionView

    init(screen: NSScreen, title: String) {
        let canvas = ScreenSelectionView(frame: screen.frame)
        canvas.title = title
        canvas.screenFrame = screen.frame
        canvas.pixelScale = screen.backingScaleFactor
        self.canvas = canvas
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        canvas.onDragEnded = { [weak self] rect in self?.onDragEnded?(rect) }
        canvas.onCancel = { [weak self] in self?.onCancel?() }
        setFrame(screen.frame, display: true)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        contentView = canvas
        canvas.frame = CGRect(origin: .zero, size: screen.frame.size)
        canvas.refreshHover(at: NSEvent.mouseLocation)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setBackdrop(_ image: NSImage) {
        canvas.backdrop = image
        canvas.needsDisplay = true
    }

    func setRegionMap(_ map: ScreenRegionMap) {
        canvas.regionMap = map
        canvas.refreshHover(at: NSEvent.mouseLocation)
    }

    func setTitle(_ title: String) {
        canvas.title = title
        canvas.needsDisplay = true
    }
}

final class ScreenSelectionView: NSView {
    var title = ""
    var screenFrame = CGRect.zero
    var pixelScale: CGFloat = 1
    var onDragEnded: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?
    private var dragging = false
    private var hoverBounds: CGRect?
    /// The screen as it was when the selection opened; nil until it has been read.
    var regionMap: ScreenRegionMap?
    var backdrop: NSImage?

    override var isFlipped: Bool { false }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard start == nil else { return }
        refreshHover(at: convertToScreen(event.locationInWindow))
    }

    override func mouseEntered(with event: NSEvent) {
        guard start == nil else { return }
        refreshHover(at: convertToScreen(event.locationInWindow))
    }

    func refreshHover(at point: CGPoint) {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Over the bare desktop the wallpaper's shapes are not regions; offer the screen.
        let window = ScreenTranslate.topmostBounds(at: point, candidates: ScreenWindowProbe.onscreenCandidates(excludingPID: pid))
        let bounds = window.flatMap { regionMap?.region(at: point, within: $0) ?? $0 }
            ?? ScreenWindowProbe.hoverBounds(at: point, excludingPID: pid)
        let clipped = bounds.flatMap { $0.intersection(screenFrame) }
        hoverBounds = (clipped?.isNull == false && (clipped?.width ?? 0) > 8) ? clipped : nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        start = convertToScreen(event.locationInWindow)
        current = start
        dragging = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convertToScreen(event.locationInWindow)
        if let start, let current, hypot(current.x - start.x, current.y - start.y) >= ScreenTranslate.dragThreshold {
            dragging = true
            hoverBounds = nil
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convertToScreen(event.locationInWindow)
        let dragRect = selectionRect
        let snap = hoverBounds
        start = nil
        current = nil
        dragging = false
        needsDisplay = true
        if dragRect.width >= ScreenTranslate.minimumSelection, dragRect.height >= ScreenTranslate.minimumSelection {
            onDragEnded?(dragRect)
            return
        }
        if let snap, snap.width >= ScreenTranslate.minimumSelection, snap.height >= ScreenTranslate.minimumSelection {
            onDragEnded?(snap)
            return
        }
        onCancel?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func draw(_ dirtyRect: NSRect) {
        backdrop?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        let highlight = highlightRect
        let dim = NSBezierPath(rect: bounds)
        // Regions inside a window are often small and square-cornered; only windows get the full radius.
        let radius = min(ScreenTranslate.windowCornerRadius, min(highlight.width, highlight.height) / 6)
        if highlight.width >= 2, highlight.height >= 2 {
            dim.append(NSBezierPath(roundedRect: highlight, xRadius: radius, yRadius: radius))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.28).setFill()
        dim.fill()
        if highlight.width >= 2, highlight.height >= 2 {
            let outer = NSBezierPath(roundedRect: highlight.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            outer.lineWidth = 3
            NSColor.black.withAlphaComponent(0.35).setStroke()
            outer.stroke()
            let inner = NSBezierPath(roundedRect: highlight.insetBy(dx: 1.5, dy: 1.5), xRadius: max(0, radius - 1), yRadius: max(0, radius - 1))
            inner.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.92).setStroke()
            inner.stroke()
            if dragging, highlight.width > 32, highlight.height > 32 {
                let corners = NSBezierPath()
                let r = highlight.insetBy(dx: 2, dy: 2)
                for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
                    corners.move(to: CGPoint(x: x, y: y + 12 * dy))
                    corners.line(to: CGPoint(x: x, y: y))
                    corners.line(to: CGPoint(x: x + 12 * dx, y: y))
                }
                corners.lineWidth = 2.5; corners.lineJoinStyle = .round; corners.lineCapStyle = .round
                NSColor.controlAccentColor.setStroke(); corners.stroke()
            }
        }
        let prompt: String
        if dragging {
            prompt = "\(Int((highlight.width * pixelScale).rounded())) × \(Int((highlight.height * pixelScale).rounded())) px  ·  松开完成"
        } else if hoverBounds != nil {
            prompt = "点击选中 · 拖动自选"
        } else {
            prompt = "移动鼠标选择 · 拖动框选"
        }
        let chip = NSAttributedString(
            string: prompt,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
        let heading = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let size = NSSize(width: max(chip.size().width, heading.size().width) + 24, height: title.isEmpty ? 34 : 51)
        let mousePoint = current ?? NSEvent.mouseLocation
        let mouse = convertFromScreen(CGRect(origin: mousePoint, size: .zero)).origin
        let chipRect = Self.hintRect(at: mouse, size: size, within: bounds)
        let chipPath = NSBezierPath(roundedRect: chipRect, xRadius: 11, yRadius: 11)
        NSColor.windowBackgroundColor.setFill(); chipPath.fill()
        NSColor.separatorColor.setStroke(); chipPath.lineWidth = 0.75; chipPath.stroke()
        chip.draw(at: NSPoint(x: chipRect.minX + 12, y: chipRect.minY + 9))
        if !title.isEmpty { heading.draw(at: NSPoint(x: chipRect.minX + 12, y: chipRect.maxY - 21)) }
    }

    static func hintRect(at point: CGPoint, size: CGSize, within bounds: CGRect) -> CGRect {
        let size = CGSize(width: min(size.width, bounds.width - 16), height: min(size.height, bounds.height - 16))
        var x = point.x + 18
        if x + size.width > bounds.maxX - 8 { x = point.x - size.width - 18 }
        var y = point.y - size.height - 16
        if y < bounds.minY + 8 { y = point.y + 18 }
        return CGRect(x: max(bounds.minX + 8, min(x, bounds.maxX - size.width - 8)), y: max(bounds.minY + 8, min(y, bounds.maxY - size.height - 8)), width: size.width, height: size.height)
    }

    private var highlightRect: CGRect {
        if dragging { return convertFromScreen(selectionRect) }
        if let hoverBounds { return convertFromScreen(hoverBounds) }
        return .zero
    }

    private var selectionRect: CGRect {
        guard let start, let current else { return .zero }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func convertToScreen(_ windowPoint: CGPoint) -> CGPoint {
        window?.convertToScreen(CGRect(origin: windowPoint, size: .zero)).origin ?? windowPoint
    }

    private func convertFromScreen(_ screenRect: CGRect) -> CGRect {
        window?.convertFromScreen(screenRect) ?? screenRect
    }
}
