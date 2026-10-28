import AppKit
import SwiftUI

private struct PreviewBoard: View {
    let state: CaptureState
    let darkBackground: Bool
    let title: String
    var body: some View {
        ZStack {
            (darkBackground ? Color(red: 0.045, green: 0.055, blue: 0.075) : Color(red: 0.94, green: 0.95, blue: 0.97))
            VStack(alignment: .leading, spacing: 20) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(darkBackground ? Color.white.opacity(0.7) : Color.black.opacity(0.65))
                VStack(alignment: .leading, spacing: 10) {
                    Text("A clear view, in every light.").font(.system(size: 24, weight: .semibold))
                    Text("Settings     Appearance     Keyboard shortcuts").font(.system(size: 13))
                }.foregroundStyle(darkBackground ? Color.white : Color.black).padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(darkBackground ? Color.white.opacity(0.04) : Color.white, in: RoundedRectangle(cornerRadius: 13))
                CaptureToolbar(state: state, action: { _ in }).frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }.padding(26)
        }.frame(width: 680, height: 470)
    }
}

@main struct CaptureVisualPreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: "build/previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            for kind in ["ready", "annotating", "editing-number", "editing-rectangle", "working", "failed", "empty"] {
                let state = CaptureState()
                state.direction = "EN → 中文"
                switch kind {
                case "ready": state.translated = true
                case "annotating": state.translated = true; state.annotating = true; state.annotations.tool = .number
                case "editing-number":
                    state.translated = true
                    state.annotations.append(Annotation(tool: .number, points: [CGPoint(x: 40, y: 40)], color: .systemRed, width: 4, number: 5))
                case "editing-rectangle":
                    state.translated = true
                    state.annotations.append(Annotation(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 60)], color: .systemBlue, width: 8))
                case "working": state.working = true; state.automaticallyTranslates = true; state.status = "正在识别与翻译…"
                case "failed": state.failed = true; state.automaticallyTranslates = true; state.status = "连接失败，请重试。"
                default: state.noText = true; state.automaticallyTranslates = true; state.status = "没有识别到文字，可重新框选或重试。"
                }
                let host = NSHostingView(rootView: PreviewBoard(state: state, darkBackground: dark, title: "\(dark ? "Dark" : "Light") background · \(kind) · inactive window").environment(\.controlActiveState, .inactive))
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 680, height: 470), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Missing preview bitmap") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let path = directory.appendingPathComponent("\(dark ? "dark" : "light")-\(kind).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: path)
                let toolbar = NSHostingView(rootView: CaptureToolbar(state: state, action: { _ in }))
                window.contentView = toolbar
                let toolbarSize = toolbar.fittingSize
                window.setContentSize(toolbarSize)
                toolbar.frame = CGRect(origin: .zero, size: toolbarSize)
                toolbar.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                let toolbarBitmap = toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds)!
                toolbar.cacheDisplay(in: toolbar.bounds, to: toolbarBitmap)
                try toolbarBitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(dark ? "dark" : "light")-\(kind)-toolbar.png"))
                window.orderOut(nil)
                print(path.path)
            }
            let selection = ScreenSelectionView(frame: CGRect(x: 0, y: 0, width: 680, height: 470))
            selection.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            selection.title = "截屏翻译 · EN → 中文"
            selection.screenFrame = selection.bounds
            selection.pixelScale = 2
            let backdrop = NSImage(size: selection.bounds.size, flipped: false) { rect in
                (dark ? NSColor(calibratedWhite: 0.08, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)).setFill()
                rect.fill()
                let line = NSAttributedString(string: "Select a region to translate", attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: dark ? NSColor.white : NSColor.black])
                line.draw(at: CGPoint(x: 110, y: 200))
                return true
            }
            selection.backdrop = backdrop
            selection.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 90, y: 160), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            selection.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: 570, y: 260), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 680, pixelsHigh: 470, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            selection.appearance?.performAsCurrentDrawingAppearance { selection.draw(selection.bounds) }
            NSGraphicsContext.restoreGraphicsState()
            let path = directory.appendingPathComponent("\(dark ? "dark" : "light")-selection.png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: path)
            print(path.path)
        }
    }
}
