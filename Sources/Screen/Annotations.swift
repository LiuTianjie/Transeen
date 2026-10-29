import AppKit

enum AnnotationTool: String, CaseIterable, Identifiable {
    case move, rectangle, ellipse, arrow, pen, number
    var id: String { rawValue }
    var title: String { switch self { case .move: "选择 / 移动"; case .rectangle: "矩形"; case .ellipse: "椭圆"; case .arrow: "箭头"; case .pen: "画笔"; case .number: "编号" } }
    var symbol: String { switch self { case .move: "cursorarrow"; case .rectangle: "rectangle"; case .ellipse: "circle"; case .arrow: "arrow.up.right"; case .pen: "pencil"; case .number: "1.circle" } }
}

struct Annotation: Equatable, Identifiable {
    let id = UUID()
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var number: Int? = nil

    private var numberText: NSAttributedString {
        let rgb = color.usingColorSpace(.sRGB) ?? .systemRed
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return NSAttributedString(string: String(number ?? 1), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12 + width, weight: .semibold),
            .foregroundColor: luminance > 0.6 ? NSColor.black : NSColor.white
        ])
    }
    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        if tool == .number {
            let diameter = max(20 + width * 2, numberText.size().width + 12)
            return CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2, width: diameter, height: diameter)
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    var path: CGPath {
        let path = CGMutablePath()
        guard let start = points.first, let end = points.last else { return path }
        switch tool {
        case .move: break
        case .number, .ellipse: path.addEllipse(in: bounds)
        case .rectangle: path.addRect(bounds)
        case .pen:
            path.move(to: start)
            for point in points.dropFirst() { path.addLine(to: point) }
        case .arrow:
            path.move(to: start); path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(12, width * 4)
            for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: end)
                path.addLine(to: CGPoint(x: end.x - cos(angle + offset) * length, y: end.y - sin(angle + offset) * length))
            }
        }
        return path
    }
    func draw() {
        guard !points.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addPath(path)
        if tool == .number {
            context.setFillColor(color.cgColor); context.fillPath()
            let text = numberText, size = text.size()
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        } else {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width); context.setLineCap(.round); context.setLineJoin(.round)
            context.strokePath()
        }
        context.restoreGState()
    }
    func contains(_ point: CGPoint, interior: Bool = false) -> Bool {
        if tool == .number || (interior && (tool == .rectangle || tool == .ellipse)), path.contains(point) { return true }
        return path.copy(strokingWithWidth: width + 10, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
    }
    var handles: [CGPoint] {
        if tool == .number { return [] }
        if tool == .arrow { return [points.first, points.last].compactMap { $0 } }
        let rect = bounds.insetBy(dx: -4, dy: -4)
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
    func handle(at point: CGPoint) -> Int? {
        handles.indices.first { hypot(handles[$0].x - point.x, handles[$0].y - point.y) <= 7 }
    }
    func moved(by delta: CGPoint) -> Annotation {
        var result = self
        result.points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return result
    }
    func resized(handle: Int, by delta: CGPoint) -> Annotation {
        var result = self
        if tool == .arrow {
            let index = handle == 0 ? 0 : points.count - 1
            result.points[index] = CGPoint(x: points[index].x + delta.x, y: points[index].y + delta.y)
        } else if tool != .number, (0...3).contains(handle) {
            let rect = bounds
            let left = handle == 0 || handle == 3, bottom = handle == 0 || handle == 1
            let anchor = CGPoint(x: left ? rect.maxX : rect.minX, y: bottom ? rect.maxY : rect.minY)
            let corner = CGPoint(x: left ? rect.minX : rect.maxX, y: bottom ? rect.minY : rect.maxY)
            let sx = rect.width > 0.001 ? (corner.x + delta.x - anchor.x) / (corner.x - anchor.x) : 1
            let sy = rect.height > 0.001 ? (corner.y + delta.y - anchor.y) / (corner.y - anchor.y) : 1
            result.points = points.map { CGPoint(x: anchor.x + ($0.x - anchor.x) * sx, y: anchor.y + ($0.y - anchor.y) * sy) }
        }
        return result
    }
}

@MainActor @Observable
final class AnnotationStore {
    struct Snapshot {
        var marks: [Annotation]
        var selectedID: UUID?
    }
    var tool: AnnotationTool = .move
    private var drawingColor = NSColor.systemRed
    private var drawingWidth: CGFloat = 4
    var color: NSColor {
        get { selected?.color ?? drawingColor }
        set { drawingColor = newValue; modifySelected { $0.color = newValue } }
    }
    var width: CGFloat {
        get { selected?.width ?? drawingWidth }
        set { drawingWidth = min(max(newValue, 1), 10); modifySelected { $0.width = drawingWidth } }
    }
    private(set) var marks: [Annotation] = []
    private(set) var selectedID: UUID?
    private var history: [Snapshot] = []
    private(set) var undone: [Snapshot] = []
    private var transaction: Snapshot?
    var onChange: (() -> Void)?
    var selected: Annotation? { marks.first { $0.id == selectedID } }
    var canUndo: Bool { !history.isEmpty || transaction != nil }
    var canRedo: Bool { !undone.isEmpty }
    var isEditing: Bool { transaction != nil }
    var nextNumber: Int { (marks.filter { $0.tool == .number }.compactMap(\.number).max() ?? 0) + 1 }
    private var snapshot: Snapshot { Snapshot(marks: marks, selectedID: selectedID) }

    func select(_ id: UUID?) {
        commitEdit()
        selectedID = marks.contains { $0.id == id } ? id : nil
        if let selected { drawingColor = selected.color; drawingWidth = selected.width }
        onChange?()
    }
    func hit(at point: CGPoint, interior: Bool = false) -> Annotation? {
        marks.reversed().first { $0.contains(point, interior: interior) }
    }
    private func record(_ before: Snapshot) {
        guard before.marks != marks else { return }
        history.append(before); undone = []
    }
    func append(_ mark: Annotation) {
        commitEdit()
        let before = snapshot
        marks.append(mark); selectedID = mark.id
        record(before); onChange?()
    }
    func beginEdit() { if transaction == nil { transaction = snapshot } }
    func update(_ mark: Annotation) {
        guard let index = marks.firstIndex(where: { $0.id == mark.id }), marks[index] != mark else { return }
        let before = snapshot
        marks[index] = mark
        if transaction == nil { record(before) }
        onChange?()
    }
    func commitEdit() {
        guard let before = transaction else { return }
        transaction = nil; record(before)
    }
    func cancelEdit() {
        guard let before = transaction else { return }
        transaction = nil; restore(before)
    }
    func modifySelected(_ change: (inout Annotation) -> Void) {
        guard var mark = selected else { return }
        change(&mark); update(mark)
    }
    func setSelectedNumber(_ value: Int) {
        guard selected?.tool == .number, value > 0, value <= 9999 else { return }
        modifySelected { $0.number = value }
    }
    func deleteSelected() {
        commitEdit()
        guard let id = selectedID else { return }
        let before = snapshot
        marks.removeAll { $0.id == id }; selectedID = nil
        record(before); onChange?()
    }
    func undo() {
        if transaction != nil { cancelEdit(); return }
        guard let before = history.popLast() else { return }
        undone.append(snapshot); restore(before)
    }
    func redo() {
        commitEdit()
        guard let after = undone.popLast() else { return }
        history.append(snapshot); restore(after)
    }
    private func restore(_ value: Snapshot) {
        marks = value.marks; selectedID = value.selectedID
        onChange?()
    }
    func clear() {
        transaction = nil; marks = []; selectedID = nil; history = []; undone = []; onChange?()
    }
    /// The picture's origin moved under the marks. Keep them over the same pixels,
    /// in undo history too; this is not itself an undoable change.
    func offset(by delta: CGPoint) {
        guard delta != .zero else { return }
        func shifted(_ snapshot: Snapshot) -> Snapshot {
            Snapshot(marks: snapshot.marks.map { $0.moved(by: delta) }, selectedID: snapshot.selectedID)
        }
        marks = marks.map { $0.moved(by: delta) }
        history = history.map(shifted); undone = undone.map(shifted)
        transaction = transaction.map(shifted)
        onChange?()
    }

    func export(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), image.size.width > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(cg.width) / image.size.width, y: CGFloat(cg.height) / image.size.height)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        for mark in marks { mark.draw() }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = image.size
        let result = NSImage(size: image.size); result.addRepresentation(bitmap)
        return result
    }
}

final class AnnotationCanvas: NSView {
    let annotations: AnnotationStore
    var image = NSImage() { didSet { needsDisplay = true } }
    /// Off while a layer behind the canvas shows the picture; the marks are still drawn.
    var showsImage = true { didSet { needsDisplay = true } }
    var draft: Annotation?
    var onEditNumber: (() -> Void)?
    private struct EditGesture {
        var original: Annotation
        var start: CGPoint
        var handle: Int?
    }
    private var editing: EditGesture?
    private var previousImage: NSImage?
    private var transitionFraction: CGFloat = 1
    private var transitionTask: Task<Void, Never>?
    init(annotations: AnnotationStore) {
        self.annotations = annotations
        super.init(frame: .zero)
        wantsLayer = true
        annotations.onChange = { [weak self] in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if showsImage, let previousImage {
            previousImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.none.rawValue])
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: transitionFraction, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        } else if showsImage {
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        }
        for mark in annotations.marks { mark.draw() }
        draft?.draw()
        if let selected = annotations.selected, draft == nil { drawSelection(selected) }
    }
    private func drawSelection(_ mark: Annotation) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1)
        if mark.tool != .arrow {
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.stroke(mark.bounds.insetBy(dx: -4, dy: -4))
            context.setLineDash(phase: 0, lengths: [])
        }
        context.setFillColor(NSColor.white.cgColor)
        for point in mark.handles {
            let rect = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            context.fill(rect); context.stroke(rect)
        }
        context.restoreGState()
    }
    /// A different crop: no crossfade, which would stretch the old picture to the new frame.
    func replace(_ next: NSImage) {
        transitionTask?.cancel(); transitionTask = nil
        previousImage = nil; image = next
    }
    /// Only crossfade image pixels. The frame and annotation geometry stay fixed.
    func transition(to next: NSImage) {
        guard image !== next else { return }
        transitionTask?.cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, image.size.width > 0 else {
            previousImage = nil; image = next; return
        }
        previousImage = image; transitionFraction = 0; image = next
        transitionTask = Task { [weak self] in
            for step in 1...12 {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let self else { return }
                let t = CGFloat(step) / 12
                self.transitionFraction = 1 - pow(1 - t, 3)
                self.needsDisplay = true
            }
            self?.previousImage = nil
            self?.needsDisplay = true
        }
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        let location = point(event)
        if let selected = annotations.selected, let handle = selected.handle(at: location) {
            beginEditing(selected, at: location, handle: handle)
            return
        }
        if let mark = annotations.hit(at: location, interior: annotations.tool == .move) {
            annotations.tool = .move
            annotations.select(mark.id)
            if event.clickCount == 2, mark.tool == .number { onEditNumber?(); return }
            beginEditing(mark, at: location)
            return
        }
        annotations.select(nil)
        if annotations.tool == .move { window?.performDrag(with: event); return }
        draft = Annotation(tool: annotations.tool, points: [location], color: annotations.color, width: annotations.width,
                           number: annotations.tool == .number ? annotations.nextNumber : nil)
        needsDisplay = true
    }
    private func beginEditing(_ mark: Annotation, at point: CGPoint, handle: Int? = nil) {
        annotations.beginEdit()
        editing = EditGesture(original: mark, start: point, handle: handle)
    }
    override func mouseDragged(with event: NSEvent) {
        let location = point(event)
        if let editing {
            guard annotations.isEditing, annotations.selectedID == editing.original.id else { self.editing = nil; return }
            var delta = CGPoint(x: location.x - editing.start.x, y: location.y - editing.start.y)
            if let handle = editing.handle {
                annotations.update(editing.original.resized(handle: handle, by: delta))
            } else {
                let rect = editing.original.bounds
                delta.x = min(max(delta.x, -rect.minX), bounds.width - rect.maxX)
                delta.y = min(max(delta.y, -rect.minY), bounds.height - rect.maxY)
                annotations.update(editing.original.moved(by: delta))
            }
            return
        }
        guard var mark = draft else { return }
        if mark.tool == .number { mark.points = [location] }
        else if mark.tool == .pen || mark.points.count == 1 { mark.points.append(location) }
        else { mark.points[1] = location }
        draft = mark; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if editing != nil {
            annotations.commitEdit(); editing = nil
        } else if let mark = draft, mark.tool == .number || mark.points.count > 1 {
            annotations.append(mark)
        }
        draft = nil; needsDisplay = true
    }
    func cancelInteraction() {
        annotations.cancelEdit(); editing = nil; draft = nil; needsDisplay = true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let mark = annotations.hit(at: point(event), interior: true) else { return nil }
        annotations.tool = .move; annotations.select(mark.id)
        let menu = NSMenu()
        if mark.tool == .number {
            let edit = NSMenuItem(title: "修改编号…", action: #selector(editNumber), keyEquivalent: "")
            edit.target = self; menu.addItem(edit)
        }
        let delete = NSMenuItem(title: "删除标注", action: #selector(deleteMark), keyEquivalent: "")
        delete.target = self; menu.addItem(delete)
        return menu
    }
    @objc private func editNumber() { onEditNumber?() }
    @objc private func deleteMark() { annotations.deleteSelected() }
}
