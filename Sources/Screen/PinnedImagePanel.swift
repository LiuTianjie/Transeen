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
    var onClose: ((PinnedImagePanel) -> Void)?

    init(image: NSImage, alternate: NSImage?, showsTranslation: Bool, rect: CGRect) {
        shown = image
        self.alternate = alternate
        self.showsTranslation = showsTranslation
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
        contentView = picture
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
        item(L("关闭"), #selector(dismiss), "\u{1b}")
        menu.items.last?.keyEquivalentModifierMask = []
        return menu
    }

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
        window?.performDrag(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
