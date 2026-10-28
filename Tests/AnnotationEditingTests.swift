import AppKit

@main struct AnnotationEditingTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let store = AnnotationStore()
        let canvas = AnnotationCanvas(annotations: store)
        canvas.frame = CGRect(x: 0, y: 0, width: 500, height: 300)
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                              context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func drag(_ start: CGPoint, _ end: CGPoint) {
            canvas.mouseDown(with: mouse(.leftMouseDown, start))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, end))
            canvas.mouseUp(with: mouse(.leftMouseUp, end))
        }
        store.tool = .rectangle
        drag(CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 100))
        let rectangle = store.marks[0]
        precondition(store.selectedID == rectangle.id, "New marks must stay editable")
        store.tool = .move
        drag(CGPoint(x: 80, y: 70), CGPoint(x: 105, y: 85))
        precondition(store.marks.count == 1 && store.marks[0].bounds.origin == CGPoint(x: 65, y: 55), "Dragging the interior must move the object, not draw another one")
        store.undo(); precondition(store.marks[0] == rectangle, "A whole drag is one undo step")
        store.redo(); precondition(store.marks[0].bounds.origin == CGPoint(x: 65, y: 55))
        store.undo()
        let handle = rectangle.handles[2]
        drag(handle, CGPoint(x: handle.x + 30, y: handle.y + 20))
        precondition(store.marks[0].bounds == CGRect(x: 40, y: 40, width: 130, height: 80), "Corner drag must resize around the opposite corner")
        store.undo(); precondition(store.marks[0] == rectangle)
        store.color = .blue
        store.width = 8
        precondition(store.marks[0].color == .blue && store.marks[0].width == 8)
        store.undo(); precondition(store.marks[0].width == rectangle.width && store.marks[0].color == .blue)
        store.undo(); precondition(store.marks[0] == rectangle)
        store.beginEdit(); store.width = 2; store.width = 6; store.width = 9; store.commitEdit()
        store.undo(); precondition(store.marks[0].width == rectangle.width, "A slider gesture is one undo step")
        store.deleteSelected()
        precondition(store.marks.isEmpty && store.canUndo && store.selectedID == nil)
        store.undo(); precondition(store.marks == [rectangle] && store.selectedID == rectangle.id)
        store.redo(); precondition(store.marks.isEmpty)
        store.undo()
        let number = Annotation(tool: .number, points: [CGPoint(x: 95, y: 75)], color: .red, width: 4, number: 1)
        store.append(number)
        precondition(store.hit(at: CGPoint(x: 95, y: 75), interior: true)?.id == number.id, "Hit testing must choose the topmost overlapping object")
        precondition(store.hit(at: CGPoint(x: 42, y: 75))?.id == rectangle.id, "Covered rectangles remain selectable by their edges")
        store.setSelectedNumber(42)
        precondition(store.selected?.number == 42 && store.nextNumber == 43)
        store.undo(); precondition(store.selected?.number == 1)
        store.redo(); precondition(store.selected?.number == 42)
        store.setSelectedNumber(0); precondition(store.selected?.number == 42)
        var openedNumberEditor = false
        canvas.onEditNumber = { openedNumberEditor = true }
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 95, y: 75), clicks: 2))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 95, y: 75), clicks: 2))
        precondition(openedNumberEditor && store.selectedID == number.id)
        store.select(rectangle.id)
        precondition(store.color == rectangle.color && store.width == rectangle.width, "Selecting an object must load its own style")
        store.color = .green
        precondition(store.marks[1].number == 42 && store.marks[1].color == .red, "Style editing must affect only the selected object")
        store.undo()
        store.redo()
        store.undo()
        store.color = .orange
        precondition(!store.canRedo, "An edit after undo must invalidate redo")
        store.beginEdit()
        store.update(store.selected!.moved(by: CGPoint(x: 50, y: 50)))
        store.cancelEdit()
        precondition(store.selected!.bounds == rectangle.bounds)

        let ellipse = Annotation(tool: .ellipse, points: [CGPoint(x: 200, y: 40), CGPoint(x: 300, y: 100)], color: .red, width: 3)
        precondition(!ellipse.contains(CGPoint(x: 250, y: 70)))
        precondition(ellipse.contains(CGPoint(x: 250, y: 70), interior: true))
        precondition(!ellipse.contains(CGPoint(x: 202, y: 42), interior: true), "Ellipse bounding-box corners must not steal clicks")
        precondition(ellipse.contains(CGPoint(x: 250, y: 100)))
        let arrow = Annotation(tool: .arrow, points: [CGPoint(x: 200, y: 150), CGPoint(x: 280, y: 150)], color: .red, width: 4)
        precondition(arrow.contains(CGPoint(x: 267, y: 157)), "Arrowheads must be selectable")
        let adjustedArrow = arrow.resized(handle: 1, by: CGPoint(x: 20, y: 30))
        precondition(adjustedArrow.points == [CGPoint(x: 200, y: 150), CGPoint(x: 300, y: 180)])
        let pen = Annotation(tool: .pen, points: [CGPoint(x: 50, y: 200), CGPoint(x: 70, y: 230), CGPoint(x: 100, y: 200)], color: .red, width: 4)
        precondition(pen.contains(CGPoint(x: 70, y: 230)) && !pen.contains(CGPoint(x: 75, y: 201)), "Pen hit testing must follow its stroke")
        let resizedPen = pen.resized(handle: 2, by: CGPoint(x: 50, y: 30))
        precondition(resizedPen.points == [CGPoint(x: 50, y: 200), CGPoint(x: 90, y: 260), CGPoint(x: 150, y: 200)], "Freehand strokes must scale as one object")
        for shape in [ellipse, arrow, pen] {
            store.append(shape); store.tool = .move; store.select(nil)
            let anchor = shape.tool == .ellipse ? CGPoint(x: 250, y: 70) : shape.points.first!
            drag(anchor, CGPoint(x: anchor.x + 10, y: anchor.y + 10))
            precondition(store.selected?.id == shape.id && store.selected?.points == shape.moved(by: CGPoint(x: 10, y: 10)).points)
            store.undo(); precondition(store.selected == shape)
            let index = shape.tool == .arrow ? 1 : 2
            let handle = shape.handles[index]
            drag(handle, CGPoint(x: handle.x + 10, y: handle.y + 10))
            precondition(store.selected == shape.resized(handle: index, by: CGPoint(x: 10, y: 10)), "Canvas handles must reshape the selected object")
            store.undo(); precondition(store.selected == shape)
        }

        for scale in [1, 2] {
            let context = CGContext(data: nil, width: 500 * scale, height: 300 * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 500 * scale, height: 300 * scale))
            let image = NSImage(cgImage: context.makeImage()!, size: CGSize(width: 500, height: 300))
            let selectedExport = store.export(image)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            store.select(nil)
            let plainExport = store.export(image)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            precondition(selectedExport.width == 500 * scale && selectedExport.height == 300 * scale)
            precondition(FrameFingerprint(selectedExport) == FrameFingerprint(plainExport), "Selection handles must never appear in exported pixels")
            try NSBitmapImageRep(cgImage: selectedExport).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/tests/annotation-edited-\(scale)x.png"))
            store.select(number.id)
        }
        print("AnnotationEditingTests: picking/layer order, moving all tools, resizing shapes/freehand, arrow endpoints, styles, number editing, deletion, transactional undo/redo and clean 1x/2x export passed")
    }
}
