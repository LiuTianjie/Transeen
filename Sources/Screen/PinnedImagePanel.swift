import AppKit

/// A capture pinned to the screen. It floats above other windows, moves with the
/// mouse and stays while new captures are taken; the right mouse button opens its
/// menu and Esc closes the focused one.
final class PinnedImagePanel: NSPanel {
    private let picture: PinnedImageView
    private var shown: NSImage
    /// The other layer of a translated capture: the original when the translation is shown.
    private var alternate: NSImage?
    private var showsTranslation: Bool
    private let initialSize: CGSize
    private var expandedSize: CGSize?
    var isClickThrough: Bool {
        get { ignoresMouseEvents }
        set { ignoresMouseEvents = newValue }
    }
    var onClose: ((PinnedImagePanel) -> Void)?

    init(image: NSImage, alternate: NSImage?, showsTranslation: Bool, rect: CGRect) {
        shown = image
        self.alternate = alternate
        self.showsTranslation = showsTranslation
        initialSize = rect.size
        picture = PinnedImageView(frame: CGRect(origin: .zero, size: rect.size))
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = L("钉住的截图")
        level = .floating
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        picture.image = image
        picture.menuProvider = { [weak self] in self?.contextMenu() }
        picture.onScroll = { [weak self] event in
            guard let self else { return }
            if event.modifierFlags.contains(.option) {
                alphaValue = min(1, max(0.2, alphaValue - event.scrollingDeltaY * 0.008))
            } else {
                zoom(by: exp(-event.scrollingDeltaY * 0.012), anchor: NSEvent.mouseLocation)
            }
        }
        picture.onMagnify = { [weak self] value in self?.zoom(by: 1 + value, anchor: NSEvent.mouseLocation) }
        picture.onDoubleClick = { [weak self] in self?.toggleThumbnail() }
        contentView = picture
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(picture)
        // The shadow follows the rounded corners only once they have been drawn.
        display()
        invalidateShadow()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, flags.isEmpty { dismiss() }
        else if event.keyCode == 8, flags == .command { copyImage() }
        else if event.keyCode == 1, flags == .command { saveImage() }
        else if event.charactersIgnoringModifiers == "+" || event.charactersIgnoringModifiers == "=" { zoom(by: 1.2) }
        else if event.charactersIgnoringModifiers == "-" { zoom(by: 1 / 1.2) }
        else if event.charactersIgnoringModifiers == "0" { resetSize() }
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { dismiss() }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "") {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
        }
        item(L("复制图片"), #selector(copyImage), "c")
        item(L("保存图片…"), #selector(saveImage), "s")
        if alternate != nil { item(showsTranslation ? L("显示原文") : L("显示译文"), #selector(swapLayer)) }
        menu.addItem(.separator())
        item(L("放大"), #selector(zoomIn))
        item(L("缩小"), #selector(zoomOut))
        item(L("恢复大小"), #selector(resetSize))
        item(L("缩略图 / 展开"), #selector(toggleThumbnail))
        let opacity = NSMenuItem(title: L("不透明度"), action: nil, keyEquivalent: "")
        let choices = NSMenu()
        for percent in [100, 75, 50, 25] {
            let choice = NSMenuItem(title: "\(percent)%", action: #selector(changeOpacity(_:)), keyEquivalent: "")
            choice.tag = percent; choice.target = self
            choice.state = abs(alphaValue - Double(percent) / 100) < 0.01 ? .on : .off
            choices.addItem(choice)
        }
        opacity.submenu = choices; menu.addItem(opacity)
        item(L("鼠标穿透（从菜单栏解除）"), #selector(enableClickThrough))
        menu.addItem(.separator())
        item(L("关闭"), #selector(dismiss), "\u{1b}")
        menu.items.last?.keyEquivalentModifierMask = []
        return menu
    }

    func zoom(by factor: CGFloat, anchor: CGPoint? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        let minimum = min(1, 32 / max(1, min(initialSize.width, initialSize.height)))
        let scale = min(8, max(minimum, frame.width * factor / max(1, initialSize.width)))
        let size = CGSize(width: initialSize.width * scale, height: initialSize.height * scale)
        resize(to: size, anchor: anchor)
        expandedSize = nil
    }
    private func resize(to size: CGSize, anchor: CGPoint? = nil) {
        let pivot = anchor ?? CGPoint(x: frame.midX, y: frame.midY)
        let fx = min(1, max(0, (pivot.x - frame.minX) / max(1, frame.width)))
        let fy = min(1, max(0, (pivot.y - frame.minY) / max(1, frame.height)))
        var rect = CGRect(x: pivot.x - size.width * fx, y: pivot.y - size.height * fy, width: size.width, height: size.height)
        if let visible = screen?.visibleFrame {
            rect.origin.x = max(visible.minX - size.width + 40, min(rect.minX, visible.maxX - 40))
            rect.origin.y = max(visible.minY - size.height + 40, min(rect.minY, visible.maxY - 40))
        }
        setFrame(rect, display: true)
        invalidateShadow()
    }
    @objc private func zoomIn() { zoom(by: 1.2) }
    @objc private func zoomOut() { zoom(by: 1 / 1.2) }
    @objc private func resetSize() { expandedSize = nil; resize(to: initialSize) }
    @objc private func toggleThumbnail() {
        if let size = expandedSize { expandedSize = nil; resize(to: size) }
        else {
            expandedSize = frame.size
            let scale = 120 / max(frame.width, frame.height)
            resize(to: CGSize(width: frame.width * scale, height: frame.height * scale))
        }
    }
    @objc private func changeOpacity(_ sender: NSMenuItem) { alphaValue = Double(sender.tag) / 100 }
    @objc private func enableClickThrough() { isClickThrough = true }

    @objc private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([shown])
    }
    @objc private func saveImage() {
        guard let cg = shown.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        let picker = NSSavePanel()
        picker.allowedContentTypes = [.png]
        picker.nameFieldStringValue = "Transeen-\(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")).png"
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { result in
            guard result == .OK, let url = picker.url else { return }
            try? png.write(to: url, options: .atomic)
        }
    }
    @objc private func swapLayer() {
        guard let other = alternate else { return }
        alternate = shown; shown = other
        showsTranslation.toggle()
        picture.image = shown
    }
    @objc func dismiss() {
        orderOut(nil)
        onClose?(self)
    }
}

private final class PinnedImageView: NSView {
    var image = NSImage() { didSet { needsDisplay = true } }
    var menuProvider: (() -> NSMenu?)?
    var onScroll: ((NSEvent) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(ScreenTranslate.windowCornerRadius, bounds.width / 2, bounds.height / 2)
        let outline = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: false,
                   hints: [.interpolation: NSImageInterpolation.none.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.22).setStroke()
        edge.lineWidth = 1
        edge.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { onDoubleClick?() }
        else { window?.performDrag(with: event) }
    }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override func magnify(with event: NSEvent) { onMagnify?(event.magnification) }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
