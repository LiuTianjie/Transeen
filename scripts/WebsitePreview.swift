import AppKit
import SwiftUI
import CoreText

/// Public-safe website artwork. Uses the production OCR/compositor and toolbar
/// with authored sample text and fixed translations; never captures the desktop.
@main struct WebsitePreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: "build/website-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let width: CGFloat = 1040, height: CGFloat = 530, scale: CGFloat = 2
        let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        let ink = color(0.12, 0.23, 0.20), muted = color(0.39, 0.47, 0.43), green = color(0.20, 0.43, 0.34)
        ctx.setFillColor(color(0.96, 0.97, 0.94).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ tint: NSColor? = nil) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: tint ?? ink]))
            ctx.textPosition = CGPoint(x: x, y: height - y)
            CTLineDraw(line, ctx)
        }
        text("FIELD NOTES", 52, 51, 13, .semibold, green)
        text("Design & attention", 817, 51, 13, .medium, muted)
        ctx.setStrokeColor(color(0.82, 0.86, 0.81).cgColor); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 52, y: height - 77)); ctx.addLine(to: CGPoint(x: 988, y: height - 77)); ctx.strokePath()
        text("Good tools stay", 52, 151, 43, .semibold)
        text("out of the way.", 52, 204, 43, .semibold)
        text("Keep your attention on what matters.", 54, 258, 19, .medium, green)
        text("Reading is easier when everything stays in context.", 54, 305, 17, .regular, muted)
        text("Translate the words. Keep the picture.", 54, 335, 17, .regular, muted)
        // An abstract focus diagram. Its geometry is preserved by translation.
        let center = CGPoint(x: 818, y: 267)
        for radius: CGFloat in [132, 99, 66] {
            ctx.setStrokeColor(green.withAlphaComponent(0.18).cgColor)
            ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        ctx.setFillColor(color(0.75, 0.87, 0.68).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 33, y: center.y - 33, width: 66, height: 66))
        ctx.setFillColor(green.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
        ctx.setStrokeColor(green.withAlphaComponent(0.40).cgColor)
        ctx.move(to: CGPoint(x: 818, y: 111)); ctx.addLine(to: CGPoint(x: 818, y: 423)); ctx.strokePath()
        ctx.move(to: CGPoint(x: 662, y: 267)); ctx.addLine(to: CGPoint(x: 974, y: 267)); ctx.strokePath()
        text("A little less noise.", 750, 448, 15, .medium, green)
        ctx.setFillColor(color(0.90, 0.93, 0.87).cgColor)
        ctx.fill(CGRect(x: 52, y: 44, width: 547, height: 78))
        text("Less switching. More understanding.", 74, 452, 18, .medium)
        let original = ctx.makeImage()!
        let analysis = try ScreenPipeline.analyze(original, scale: scale, source: .en, target: .zhHans)!
        let translations = [
            ("FIELD NOTES", "阅读札记"), ("Design & attention", "设计与专注"),
            ("Good tools", "好工具，让你\n专注眼前。"),
            ("out of the way", "专注眼前。"),
            ("Keep your attention", "把注意力，留给重要的事。"),
            ("Reading is easier", "一切都在熟悉的位置，阅读自然更轻松。"),
            ("Translate the words", "翻译文字，保留画面。"),
            ("A little less", "少一点干扰。"),
            ("Less switching", "少一点切换，多一点理解。")
        ]
        let mapped = Dictionary(uniqueKeysWithValues: analysis.blocks.enumerated().compactMap { index, block -> (Int, String)? in
            print("\(index): \(block.original)")
            return translations.first(where: { block.original.localizedCaseInsensitiveContains($0.0) }).map { (index, $0.1) }
        })
        let translated = ScreenPipeline.compose(analysis, translations: mapped).pixels.cgImage()!
        for (name, cg) in [("original", original), ("translated", translated)] {
            try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
        }
        for annotate in [false, true] {
            let state = CaptureState()
            state.translated = true; state.direction = "EN → 中文"; state.detectsSource = false
            state.annotating = annotate
            if annotate { state.annotations.tool = .arrow; state.annotations.color = .systemGreen }
            let host = NSHostingView(rootView: CaptureToolbar(state: state, action: { _ in }))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 552, height: 140), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(annotate ? "toolbar-annotate.png" : "toolbar.png"))
            window.orderOut(nil)
        }
        let card = CGContext(data: nil, width: 2400, height: 1480, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        card.scaleBy(x: 2, y: 2)
        card.setFillColor(color(0.055, 0.105, 0.073).cgColor)
        card.fill(CGRect(x: 0, y: 0, width: 1200, height: 740))
        card.setStrokeColor(color(0.52, 0.71, 0.48).cgColor)
        card.setLineWidth(1)
        card.stroke(CGRect(x: 75, y: 143, width: 1050, height: 540))
        card.draw(translated, in: CGRect(x: 80, y: 148, width: 1040, height: 530))
        let toolbar = NSImage(contentsOf: output.appendingPathComponent("toolbar.png"))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        card.draw(toolbar, in: CGRect(x: 324, y: 29, width: 552, height: 93))
        let label = CTLineCreateWithAttributedString(NSAttributedString(string: "Transeen  /  Translation, right where it belongs.", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: color(0.75, 0.87, 0.73)]))
        card.textPosition = CGPoint(x: 80, y: 705)
        CTLineDraw(label, card)
        try NSBitmapImageRep(cgImage: card.makeImage()!).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("preview.png"))
    }
}
