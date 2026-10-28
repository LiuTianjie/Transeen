import AppKit

@main struct CaptureTests {
    @MainActor static func main() throws {
        let store = AnnotationStore()
        let image = NSImage(size: NSSize(width: 200, height: 100))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 200, height: 100).fill(); image.unlockFocus()
        let mark = Annotation(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 60)], color: .red, width: 4)
        store.append(mark)
        precondition(store.marks.count == 1)
        let exported = store.export(image)!
        let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let result = exported.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(result.width == original.width && result.height == original.height, "Export must preserve backing pixels")
        precondition(FrameFingerprint(result) != FrameFingerprint(original), "Annotation must be exported")
        precondition(FrameFingerprint(original) == FrameFingerprint(original), "Stable frames skip work")
        store.undo(); precondition(store.marks.isEmpty && store.undone.count == 1)
        store.redo(); precondition(store.marks.count == 1 && store.undone.isEmpty)
        store.undo(); store.append(mark); precondition(store.undone.isEmpty, "New marks invalidate redo")
        store.clear(); precondition(store.marks.isEmpty && store.undone.isEmpty)
        let unmarked = store.export(image)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(FrameFingerprint(unmarked) == FrameFingerprint(original), "No marks must preserve image pixels")
        // Number stamps commit on a click, follow a drag, and keep their sequence through history edits.
        let canvas = AnnotationCanvas(annotations: store)
        canvas.frame = CGRect(origin: .zero, size: image.size)
        store.tool = .number
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                              windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: event(.leftMouseDown, 35, 50))
        precondition(store.marks.isEmpty && canvas.draft?.number == 1)
        canvas.mouseUp(with: event(.leftMouseUp, 35, 50))
        canvas.mouseDown(with: event(.leftMouseDown, 70, 50))
        canvas.mouseDragged(with: event(.leftMouseDragged, 95, 50))
        canvas.mouseUp(with: event(.leftMouseUp, 95, 50))
        precondition(store.marks.compactMap(\.number) == [1, 2])
        precondition(store.marks[1].points == [CGPoint(x: 95, y: 50)], "Dragging a number moves its placement")
        let numbered = store.export(image)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(numbered.width == original.width && numbered.height == original.height)
        precondition(FrameFingerprint(numbered) != FrameFingerprint(original), "Numbers must appear in copied/saved images")
        try NSBitmapImageRep(cgImage: numbered).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/tests/numbered.png"))
        store.undo(); precondition(store.nextNumber == 2)
        store.redo(); precondition(store.nextNumber == 3 && store.marks.last?.number == 2)
        let redone = store.export(image)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(FrameFingerprint(redone) == FrameFingerprint(numbered), "Redo must restore the same numbered image")
        store.undo(); store.append(mark)
        precondition(store.nextNumber == 2 && store.undone.isEmpty, "Other shapes do not consume a number")
        canvas.mouseDown(with: event(.leftMouseDown, 150, 50))
        canvas.mouseUp(with: event(.leftMouseUp, 150, 50))
        precondition(store.marks.last?.number == 2, "New number after undo resumes the visible sequence")
        store.clear(); precondition(store.nextNumber == 1)
        _ = try ModelConfiguration(endpoint: "http://127.0.0.1:1234/v1/chat/completions", model: "local")
        _ = try ModelConfiguration(endpoint: "https://example.com/v1/chat/completions", model: "test")
        for endpoint in ["http://example.com/v1/chat/completions", "https://example.com/not-chat", "https://user:password@example.com/v1/chat/completions"] {
            do { _ = try ModelConfiguration(endpoint: endpoint, model: "test"); fatalError("Invalid endpoint accepted") } catch {}
        }
        for scale in [1, 2] {
            let w = 200 * scale, h = 100 * scale
            var bytes = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let i = (y * w + x) * 4
                bytes[i] = y < h / 2 ? 255 : 0
                bytes[i + 1] = 0
                bytes[i + 2] = y < h / 2 ? 0 : 255
            } }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            let frame = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let screen = CGRect(x: -100, y: 50, width: 200, height: 100)
            let top = CaptureCrop.crop(frame, rect: CGRect(x: -90, y: 120, width: 50, height: 20), screenFrame: screen)!
            precondition(top.width == 50 * scale && top.height == 20 * scale)
            precondition(NSBitmapImageRep(cgImage: top).colorAt(x: 0, y: 0)!.redComponent > 0.9, "AppKit top must map to top pixel rows")
            let bottom = CaptureCrop.crop(frame, rect: CGRect(x: -90, y: 50, width: 50, height: 20), screenFrame: screen)!
            precondition(NSBitmapImageRep(cgImage: bottom).colorAt(x: 0, y: 0)!.blueComponent > 0.9)
            let clipped = CaptureCrop.crop(frame, rect: CGRect(x: -200, y: 50, width: 150, height: 20), screenFrame: screen)!
            precondition(clipped.width == 50 * scale, "Clip to chosen display without stretching")
        }
        let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: "build/tests/annotation.png"))
        print("CaptureTests: annotation export, number click/drag and sequencing, original preservation, undo/redo, frame fingerprint, frozen crop at 1x/2x with negative screen origin, and endpoint validation passed")
    }
}
