import AppKit

@main struct CaptureToolsTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        try annotationExport()
        try await scrolling()
        try await history()
        print("CaptureToolsTests: flattened redaction, text editing, incremental scroll alignment, reverse scrolling, failure preservation, resource limits and history persistence/cleanup passed")
    }
    @MainActor static func annotationExport() throws {
        let store = AnnotationStore()
        let image = NSImage(size: CGSize(width: 400, height: 200), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("secret@example.com" as NSString).draw(at: CGPoint(x: 40, y: 80), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.red])
            return true
        }
        store.append(Annotation(tool: .text, points: [CGPoint(x: 20, y: 180)], color: .blue, width: 4, text: "说明\nSecond line", fontSize: 22))
        let text = store.selected!
        store.modifySelected { $0.text = "修改说明" }
        store.undo(); precondition(store.selected == text, "Text changes participate in undo")
        store.redo(); precondition(store.selected?.text == "修改说明")
        store.append(Annotation(tool: .redact, points: [CGPoint(x: 20, y: 60), CGPoint(x: 300, y: 120)], color: .clear, width: 1))
        // Even translucent style and later annotations must not uncover the redacted pixels.
        store.append(Annotation(tool: .highlight, points: [CGPoint(x: 10, y: 50), CGPoint(x: 310, y: 130)], color: .yellow, width: 2))
        store.append(Annotation(tool: .text, points: [CGPoint(x: 40, y: 110)], color: .white, width: 2, text: "covered"))
        let exported = store.export(image)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let bitmap = NSBitmapImageRep(cgImage: exported)
        let scale = Double(exported.width) / 400
        for x in stride(from: 25, through: 290, by: 20) {
            let color = bitmap.colorAt(x: Int(Double(x) * scale), y: Int(110 * scale))!.usingColorSpace(.deviceRGB)!
            precondition(color.redComponent < 0.01 && color.greenComponent < 0.01 && color.blueComponent < 0.01 && color.alphaComponent > 0.99, "Redaction must replace all source pixels with opaque black")
        }
        let canvas = AnnotationCanvas(annotations: store)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        store.select(text.id)
        canvas.editSelectedText()
        let editor = canvas.subviews.compactMap { $0 as? NSTextView }.first!
        editor.string = "中文输入\nMultiline"
        canvas.commitText()
        precondition(store.selected?.text == "中文输入\nMultiline")
        store.undo(); precondition(store.selected?.text == "修改说明")
        canvas.editSelectedText()
        (canvas.subviews.first as! NSTextView).string = "discarded"
        canvas.commitText(cancel: true)
        precondition(store.selected?.text == "修改说明", "Escape must cancel only the text edit")
        window.contentView = nil
    }
    @MainActor static func page() -> CGImage {
        let context = CGContext(data: nil, width: 480, height: 2400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 480, height: 2400))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for row in 0..<80 {
            let y = 2400 - CGFloat(row + 1) * 29
            let color = NSColor(calibratedRed: CGFloat((row * 13) % 31) / 40, green: CGFloat((row * 7) % 29) / 40, blue: CGFloat((row * 17) % 37) / 50, alpha: 1)
            color.setFill(); CGRect(x: 16, y: y, width: 8 + CGFloat(row % 7), height: 16).fill()
            ("Row \(row): content \(row * row * 137) — document text" as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: color])
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
    @MainActor static func scrolling() async throws {
        let page = page()
        func frame(_ top: Int) -> CGImage { page.cropping(to: CGRect(x: 0, y: top, width: 480, height: 600))! }
        let stitcher = ScrollStitcher()
        let initial = await stitcher.add(frame(0)); precondition(initial.outcome == .started)
        let duplicate = await stitcher.add(frame(0)); precondition(duplicate.outcome == .unchanged && duplicate.height == 600)
        for offset in [100, 220, 380] {
            let update = await stitcher.add(frame(offset))
            print("scroll", offset, update.outcome, update.height)
            precondition(update.outcome == .appended && update.height == 600 + offset, "Each overlap must add only newly revealed rows")
        }
        let backwards = await stitcher.add(frame(280)); precondition(backwards.outcome == .revisiting)
        let revisit = await stitcher.add(frame(380)); precondition(revisit.outcome == .revisiting && revisit.height == 980)
        let more = await stitcher.add(frame(500)); precondition(more.height == 1100)
        let result = await stitcher.result()!
        precondition(FrameFingerprint(result) == FrameFingerprint(page.cropping(to: CGRect(x: 0, y: 0, width: 480, height: 1100))!), "Stitched pixels must equal the original document, without duplicates or missing rows")
        let missed = await stitcher.add(frame(1700)); precondition(missed.outcome == .noMatch && missed.height == 1100)
        let recovery = await stitcher.add(frame(580)); precondition(recovery.height == 1180, "A failed frame must not silently replace the alignment anchor")
        let limited = ScrollStitcher(maxHeight: 650)
        _ = await limited.add(frame(0))
        let cap = await limited.add(frame(100)); precondition(cap.outcome == .limit && cap.height == 600)
        // Fixed bottom toolbar stays at the bottom and appears only once.
        func footerFrame(_ top: Int) -> CGImage {
            let context = CGContext(data: nil, width: 480, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(frame(top), in: CGRect(x: 0, y: 0, width: 480, height: 600))
            context.setFillColor(NSColor.darkGray.cgColor); context.fill(CGRect(x: 0, y: 0, width: 480, height: 36))
            return context.makeImage()!
        }
        let footer = ScrollStitcher()
        _ = await footer.add(footerFrame(0))
        let foot = await footer.add(footerFrame(100)); precondition(foot.height == 700 && foot.outcome == .appended)
        let footerResult = await footer.result()!
        precondition(FrameFingerprint(footerResult.cropping(to: CGRect(x: 0, y: 0, width: 480, height: 664))!) == FrameFingerprint(page.cropping(to: CGRect(x: 0, y: 0, width: 480, height: 664))!), "Fixed footer must not be repeated inside the document")
    }
    @MainActor static func history() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transeen-history-tests-" + UUID().uuidString)
        let suite = "transeen-history-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let history = CaptureHistory(directory: directory, defaults: defaults)
        let image = page().cropping(to: CGRect(x: 0, y: 0, width: 480, height: 100))!
        let id = UUID()
        await history.record(image, id: id)
        await history.record(image, id: id)
        precondition(history.entries.count == 1, "Repeated saves of one capture update its history entry")
        let reloaded = CaptureHistory(directory: directory, defaults: defaults)
        precondition(reloaded.entries.count == 1 && reloaded.image(id) != nil, "History survives restart")
        await history.record(image, id: UUID(), date: Date().addingTimeInterval(-8 * 86400))
        precondition(history.entries.count == 1, "Expired captures are removed")
        let pending = Task { await history.record(image, id: UUID()) }
        await Task.yield()
        history.clear()
        await pending.value
        precondition(history.entries.isEmpty, "Clearing history invalidates any in-flight encoding")
        history.isEnabled = false
        await history.record(image, id: UUID())
        precondition(history.entries.isEmpty && !FileManager.default.fileExists(atPath: directory.path), "Disabled history must not write screenshots")
    }
}
