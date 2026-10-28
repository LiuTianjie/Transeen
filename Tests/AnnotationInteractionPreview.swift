import AppKit

/// Run with scripts/preview-annotation-editing.sh for native mouse/keyboard verification.
@MainActor private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let controller = CaptureController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.authorize = { true }
        let app = NSApplication.shared
        let picture = NSImage(size: CGSize(width: 680, height: 330), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            NSAttributedString(string: "Select, move, and edit each annotation", attributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.darkGray]).draw(at: CGPoint(x: 30, y: 280))
            return true
        }
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("transeen.annotation-preview"))
        controller.preview(picture)
        controller.state.pinned = true
        let store = controller.state.annotations
        store.append(Annotation(tool: .rectangle, points: [CGPoint(x: 50, y: 150), CGPoint(x: 220, y: 230)], color: .systemRed, width: 4))
        store.append(Annotation(tool: .ellipse, points: [CGPoint(x: 280, y: 150), CGPoint(x: 440, y: 230)], color: .systemRed, width: 4))
        store.append(Annotation(tool: .arrow, points: [CGPoint(x: 80, y: 60), CGPoint(x: 240, y: 100)], color: .systemRed, width: 4))
        store.append(Annotation(tool: .pen, points: [CGPoint(x: 300, y: 60), CGPoint(x: 330, y: 100), CGPoint(x: 370, y: 65), CGPoint(x: 420, y: 90)], color: .systemRed, width: 4))
        store.append(Annotation(tool: .number, points: [CGPoint(x: 540, y: 190)], color: .systemRed, width: 4, number: 1))
        store.select(nil)
        let repaint = store.onChange
        store.onChange = {
            repaint?()
            let records: [[String: Any]] = store.marks.map { mark in
                ["tool": mark.tool.rawValue, "points": mark.points.map { [Double($0.x), Double($0.y)] }, "width": Double(mark.width), "number": mark.number ?? 0,
                 "selected": mark.id == store.selectedID, "color": mark.color.description]
            }
            if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "build/tests/annotation-interaction-state.json"))
            }
        }
        store.onChange?()
        app.activate(ignoringOtherApps: true)
    }
}

@main struct AnnotationInteractionPreview {
    @MainActor static func main() {
        controller.authorize = { true }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = PreviewDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
