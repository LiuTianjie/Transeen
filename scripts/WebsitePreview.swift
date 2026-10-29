import AppKit
import SwiftUI
import CoreText

/// Public-safe website artwork. Chrome renders the sample shop page in scripts/site at 2 pixels
/// per point (scripts/preview-website.sh); the production OCR, eraser, fitter and compositor then
/// rewrite it with the fixed translations in scripts/site/kumo-strings.json, the production
/// annotation layer draws the marks and the production toolbar is rendered from SwiftUI.
/// The desktop is never captured.
@main struct WebsitePreview {
    static let output = URL(fileURLWithPath: "build/website-preview", isDirectory: true)

    @MainActor static func main() throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let page = try image("build/website-preview/kumo-ja.png")
        let strings = try SceneStrings(url: URL(fileURLWithPath: "scripts/site/kumo-strings.json"))
        let pageSize = CGSize(width: CGFloat(page.width) / 2, height: CGFloat(page.height) / 2)

        // The region the website captures by default: the badge to the cart button.
        let region = Scene.capture
        let pixels = CGRect(x: region.minX * 2, y: region.minY * 2, width: region.width * 2, height: region.height * 2)
        let shot = page.cropping(to: pixels)!
        try save(page, "page-ja")
        try save(shot, "stage-original")
        try writeRegions(page, size: pageSize, to: "regions-ja.json")
        var texts = PageTexts()

        for target in AppLanguage.allCases where target != .ja {
            // The whole page in every language, so any selection on the website shows the production result.
            let whole = try translate(page, to: target, strings: strings, name: "page")
            try save(whole.composition.pixels.cgImage()!, "page-\(target.rawValue.lowercased())")
            texts.add(whole, target: target)
            guard target == .en || target == .zhHans else { continue }

            // The default capture as the app translates it: the cropped picture on its own.
            let slug = target == .en ? "en" : "zh"
            let (analysis, mapped, composition) = try translate(shot, to: target, strings: strings, name: "capture")
            var lifted = analysis.pixels
            for placed in composition.placed { for line in analysis.blocks[placed.index].lines { Eraser.erase(line.ink, in: &lifted, scale: 2) } }
            try save(lifted.cgImage()!, "stage-lifted-\(slug)")
            let translated = composition.pixels.cgImage()!
            try save(translated, "stage-redrawn-\(slug)")
            try writeLines(analysis, to: "stage-lines-\(slug).json")

            let order = PreciseTranslation.regions(analysis.blocks.map(\.rect), fits: { _ in true }).flatMap { $0 }
            let blocks = order.map { CaptureTextBlock(id: $0, original: analysis.blocks[$0].original, translation: mapped[$0]) }
            let direction = "JA → \(target.shortName)"
            // The toolbar as a finished translation leaves it, its status line included (CaptureController.translateFrame).
            let configure: (CaptureState) -> Void = { state in
                state.direction = direction; state.source = .ja; state.target = target; state.textBlocks = blocks
                state.hasTranslatedOnce = true
                let swap = state.shortcuts.binding(.captureTranslate).map { " · 再按 \($0.display) 交换语言" } ?? ""
                state.status = "已翻译 \(mapped.count) 处 · " + state.shortcuts.help("按住看原文", .peek) + swap
            }
            let marked = annotate(translated, size: region.size, marks: Scene.marks)
            let read = toolbar(scale: 2, configure)
            try save(read, "toolbar-\(slug)")
            try save(capture(translated, size: region.size, toolbar: read), "capture-read-\(slug)")
            try save(capture(marked, size: region.size, toolbar: toolbar(scale: 2) { configure($0); markState($0) }), "capture-mark-\(slug)")
            let kept = capture(marked, size: region.size, toolbar: toolbar(scale: 2) { configure($0); $0.copyCompleted = true })
            try save(kept, "capture-keep-\(slug)")
            try save(readmePreview(kept), "preview-\(slug)")
            try save(selecting(page, size: pageSize, selection: region, title: "截屏翻译 · \(direction)"), "select-\(slug)")
        }

        try texts.write(to: output.appendingPathComponent("blocks-ja.json"))

        // The first-run permission window, as a Mac without Screen Recording access shows it.
        NSImage(contentsOfFile: "Sources/Resources/AppIcon.png")?.setName("AppIcon")
        try save(render(PermissionGuide(permission: ScreenPermission(), continueCapture: {}, later: {}).background(Color(nsColor: .windowBackgroundColor)), scale: 2), "permission")
    }

    /// The production pipeline on `picture`, with the fixed translations in place of a translation service.
    static func translate(_ picture: CGImage, to target: AppLanguage, strings: SceneStrings, name: String) throws
        -> (analysis: ScreenPipeline.Analysis, mapped: [Int: String], composition: ScreenPipeline.Composition) {
        let analysis = try ScreenPipeline.analyze(picture, scale: 2, source: .ja, target: target)!
        let mapped = strings.translations(for: analysis.blocks, to: target)
        let composition = ScreenPipeline.compose(analysis, translations: mapped)
        for index in mapped.keys.sorted() where !composition.blocks[index].translate {
            print("\(name) \(target.rawValue) kept, the translation does not fit: \(analysis.blocks[index].original) → \(mapped[index]!)")
        }
        return (analysis, mapped, composition)
    }

    static func image(_ path: String) throws -> CGImage {
        guard let source = NSImage(contentsOfFile: path) else { throw CocoaError(.fileNoSuchFile) }
        var rect = CGRect(origin: .zero, size: source.size)
        return source.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    }

    static func save(_ image: CGImage, _ name: String) throws {
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent(name + ".png"))
    }

    /// Every recognised line, in points from the picture's top left, for the website's "recognize" stage.
    static func writeLines(_ analysis: ScreenPipeline.Analysis, to name: String) throws {
        let points = { (value: CGFloat) in Double((value / 2 * 10).rounded() / 10) }
        let lines = analysis.lines.map { line -> [String: Any] in
            let box = line.ink.rect
            return ["text": line.text, "x": points(box.minX), "y": points(box.minY), "w": points(box.width), "h": points(box.height)]
        }.sorted { ($0["y"] as! Double, $0["x"] as! Double) < ($1["y"] as! Double, $1["x"] as! Double) }
        try JSONSerialization.data(withJSONObject: lines, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name))
    }

    /// Where the selection snaps as the pointer moves over the page, as the production region finder
    /// reads it: the region under the centre of every 8-point cell, the whole page where there is none.
    /// `grid` holds `width` characters per cell, row by row: an index into `rects` in base 62, or dots for none.
    static func writeRegions(_ image: CGImage, size: CGSize, to name: String) throws {
        let finder = ScreenRegionFinder(PixelImage(image)!, scale: 2)
        let cell = 8, columns = Int(size.width) / cell, rows = Int((size.height / CGFloat(cell)).rounded(.up))
        let limit = PixelRect(minX: 0, minY: 0, maxX: image.width, maxY: image.height)
        var rects: [[Double]] = [], seen: [[Int]: Int] = [:], cells: [Int] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let point = (x: (column * cell + cell / 2) * 2, y: min(row * cell + cell / 2, Int(size.height) - 1) * 2)
                guard let found = finder.region(around: point, within: limit), found.width > 16 else { cells.append(-1); continue }
                let key = [found.minX, found.minY, found.maxX, found.maxY]
                if seen[key] == nil {
                    seen[key] = rects.count
                    rects.append([Double(found.minX) / 2, Double(found.minY) / 2, Double(found.width) / 2, Double(found.height) / 2])
                }
                cells.append(seen[key]!)
            }
        }
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let width = rects.count <= digits.count ? 1 : 2
        let grid = cells.map { index -> String in
            guard index >= 0 else { return String(repeating: ".", count: width) }
            return width == 1 ? String(digits[index]) : String([digits[index / digits.count], digits[index % digits.count]])
        }.joined()
        let map: [String: Any] = ["cell": cell, "columns": columns, "rows": rows, "width": width, "rects": rects, "grid": grid]
        try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]).write(to: output.appendingPathComponent(name))
        FileHandle.standardError.write(Data("regions: \(rects.count) for \(columns) × \(rows) cells\n".utf8))
    }

    /// Marking with the arrow: one mark kept and selected, one undone, so undo, redo and delete are live.
    @MainActor static func markState(_ state: CaptureState) {
        state.annotating = true
        state.annotations.tool = .arrow
        state.annotations.color = .systemGreen
        let kept = Annotation(tool: .arrow, points: [CGPoint(x: 40, y: 40), CGPoint(x: 90, y: 80)], color: .systemGreen, width: 4)
        state.annotations.append(kept)
        state.annotations.append(Annotation(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 50)], color: .systemRed, width: 4))
        state.annotations.undo()
        state.annotations.select(kept.id)
    }

    /// The README's preview: a capture with its toolbar on the website's dark ground.
    @MainActor static func readmePreview(_ composite: CGImage) -> CGImage {
        let sheet = Sheet(1200, 720, background: Sample.color(0x0b0e0d))
        let size = CGSize(width: CGFloat(composite.width) / 2, height: CGFloat(composite.height) / 2)
        sheet.context.draw(composite, in: sheet.flip(CGRect(x: (1200 - size.width) / 2, y: (720 - size.height) / 2, width: size.width, height: size.height)))
        return sheet.image
    }

    /// The marks drawn by the production annotation layer, on top of a picture. Marks are authored
    /// from the top left; the capture canvas, like `AnnotationStore.export`, counts from the bottom left.
    @MainActor static func annotate(_ image: CGImage, size: CGSize, marks: [Annotation]) -> CGImage {
        let sheet = Sheet(size.width, size.height, background: .white)
        sheet.context.draw(image, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: sheet.context, flipped: false)
        for var mark in marks {
            mark.points = mark.points.map { CGPoint(x: $0.x, y: size.height - $0.y) }
            mark.draw()
        }
        NSGraphicsContext.restoreGraphicsState()
        return sheet.image
    }

    /// The selection overlay as `ScreenSelectionView.draw` paints it mid-drag, with its own corner
    /// marks and hint placement, the pointer resting on the frame's lower right corner.
    @MainActor static func selecting(_ image: CGImage, size: CGSize, selection: CGRect, title: String) -> CGImage {
        let sheet = Sheet(size.width, size.height, background: .white)
        let context = sheet.context
        context.draw(image, in: CGRect(origin: .zero, size: size))
        let highlight = sheet.flip(selection)
        let radius = min(ScreenTranslate.windowCornerRadius, min(highlight.width, highlight.height) / 6)
        let dim = CGMutablePath()
        dim.addRect(CGRect(origin: .zero, size: size))
        dim.addPath(CGPath(roundedRect: highlight, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.addPath(dim)
        context.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        context.fillPath(using: .evenOdd)
        context.addPath(CGPath(roundedRect: highlight.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(3)
        context.strokePath()
        context.addPath(CGPath(roundedRect: highlight.insetBy(dx: 1.5, dy: 1.5), cornerWidth: radius - 1, cornerHeight: radius - 1, transform: nil))
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        context.setLineWidth(1.5)
        context.strokePath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let corners = ScreenSelectionView.cornerMarks(in: highlight.insetBy(dx: 1.5, dy: 1.5), radius: max(0, radius - 1), length: 12)
        corners.lineWidth = 2.5; corners.lineJoinStyle = .round; corners.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke(); corners.stroke()
        let prompt = NSAttributedString(string: "\(Int(selection.width * 2)) × \(Int(selection.height * 2)) px  ·  松开完成", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor
        ])
        let heading = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let chipSize = NSSize(width: max(prompt.size().width, heading.size().width) + 24, height: 51)
        let mouse = CGPoint(x: highlight.maxX, y: highlight.minY)
        let chip = ScreenSelectionView.hintRect(at: mouse, size: chipSize, within: CGRect(origin: .zero, size: size))
        let chipPath = NSBezierPath(roundedRect: chip, xRadius: 11, yRadius: 11)
        NSColor.windowBackgroundColor.setFill(); chipPath.fill()
        NSColor.separatorColor.setStroke(); chipPath.lineWidth = 0.75; chipPath.stroke()
        prompt.draw(at: NSPoint(x: chip.minX + 12, y: chip.minY + 9))
        heading.draw(at: NSPoint(x: chip.minX + 12, y: chip.maxY - 21))
        NSGraphicsContext.restoreGraphicsState()
        return sheet.image
    }

    /// A capture as the panel shows it in place: the picture under `ScreenPinBorderView`'s idle
    /// border, the toolbar panel 12 points below it (its image carries the 8-point margin).
    @MainActor static func capture(_ image: CGImage, size: CGSize, toolbar: CGImage) -> CGImage {
        let barSize = CGSize(width: CGFloat(toolbar.width) / 2, height: CGFloat(toolbar.height) / 2)
        let margin: CGFloat = 4
        let width = max(size.width + margin * 2, barSize.width), height = margin + size.height + 12 + barSize.height
        let sheet = Sheet(width, height, background: .clear)
        let frame = CGRect(x: (width - size.width) / 2, y: margin, width: size.width, height: size.height)
        sheet.context.draw(image, in: sheet.flip(frame))
        let border = CGPath(roundedRect: sheet.flip(frame).insetBy(dx: 1.2, dy: 1.2), cornerWidth: ScreenTranslate.windowCornerRadius,
                            cornerHeight: ScreenTranslate.windowCornerRadius, transform: nil)
        for (color, width) in [(NSColor.black.withAlphaComponent(0.38), 3.0), (NSColor.white.withAlphaComponent(0.95), 1.6)] {
            sheet.context.addPath(border)
            sheet.context.setStrokeColor(color.cgColor)
            sheet.context.setLineWidth(width)
            sheet.context.strokePath()
        }
        sheet.context.draw(toolbar, in: sheet.flip(CGRect(x: (width - barSize.width) / 2, y: frame.maxY + 12, width: barSize.width, height: barSize.height)))
        return sheet.image
    }

    @MainActor static func toolbar(scale: CGFloat, dark: Bool = false, _ configure: (CaptureState) -> Void) -> CGImage {
        let state = CaptureState()
        state.translated = true
        state.direction = "JA → EN"
        state.detectsSource = false
        state.textBlocks = [CaptureTextBlock(id: 0, original: "新入荷", translation: "New")]
        configure(state)
        return render(CaptureToolbar(state: state, action: { _ in }), scale: scale, dark: dark)
    }

    /// Any of the app's SwiftUI views, laid out at its fitting size and drawn at `scale` pixels per point.
    @MainActor static func render<Content: View>(_ view: Content, scale: CGFloat, dark: Bool = false) -> CGImage {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 552, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * scale), pixelsHigh: Int(host.bounds.height * scale),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.orderOut(nil)
        return bitmap.cgImage!
    }
}

/// The sample page's geometry, in points from its top left (scripts/site/kumo.css, `.kumo`).
enum Scene {
    static let capture = CGRect(x: 432, y: 93, width: 348, height: 294)

    /// In the capture's points: a box round the price, two numbered notes and an arrow at the stock line.
    @MainActor static var marks: [Annotation] {
        [
            Annotation(tool: .rectangle, points: [CGPoint(x: 6, y: 100), CGPoint(x: 210, y: 158)], color: .systemRed, width: 4),
            Annotation(tool: .number, points: [CGPoint(x: 318, y: 175)], color: .systemRed, width: 4, number: 1),
            Annotation(tool: .number, points: [CGPoint(x: 318, y: 222)], color: .systemOrange, width: 4, number: 2),
            Annotation(tool: .arrow, points: [CGPoint(x: 296, y: 236), CGPoint(x: 232, y: 222)], color: .systemOrange, width: 4)
        ]
    }
}

/// Every text block on the page, in points, with its translation in each language: the website's
/// full-text popover and translation count for any selection.
struct PageTexts {
    private var blocks: [String: (rect: CGRect, original: String, translations: [String: String])] = [:]

    mutating func add(_ result: (analysis: ScreenPipeline.Analysis, mapped: [Int: String], composition: ScreenPipeline.Composition), target: AppLanguage) {
        for (index, block) in result.analysis.blocks.enumerated() {
            let rect = CGRect(x: block.rect.minX / 2, y: block.rect.minY / 2, width: block.rect.width / 2, height: block.rect.height / 2).integral
            let key = "\(block.original)|\(Int(rect.midX / 8))|\(Int(rect.midY / 8))"
            var entry = blocks[key] ?? (rect, block.original, [:])
            // Like the app's count and full text: every translation returned, placed in the picture or not.
            if let translation = result.mapped[index] { entry.translations[target.rawValue] = translation }
            blocks[key] = entry
        }
    }

    func write(to url: URL) throws {
        let list = blocks.values.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }.map { entry -> [String: Any] in
            ["r": [entry.rect.minX, entry.rect.minY, entry.rect.width, entry.rect.height].map { Double($0) }, "o": entry.original, "t": entry.translations]
        }
        try JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]).write(to: url)
    }
}

/// The page's strings in every language, matched to recognised blocks by their letters and digits.
struct SceneStrings {
    let byKey: [String: [String: String]]

    init(url: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        byKey = json["strings"] as! [String: [String: String]]
    }

    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    func translations(for blocks: [TextBlock], to target: AppLanguage) -> [Int: String] {
        let table = Dictionary(byKey.values.compactMap { entry -> (String, String)? in
            guard let source = entry["ja"], let translation = entry[target.rawValue] else { return nil }
            return (Self.key(source), translation)
        }, uniquingKeysWith: { first, _ in first })
        var mapped: [Int: String] = [:]
        for (index, block) in blocks.enumerated() where block.translate {
            let key = Self.key(block.original)
            // An icon read as one more letter at either end of the line still names the same string.
            let match = table[key] ?? table.keys.filter { key.count - $0.count == 1 && (key.hasSuffix($0) || key.hasPrefix($0)) }
                .max { $0.count < $1.count }.flatMap { table[$0] }
            if let match { mapped[index] = match } else { print("\(target.rawValue) kept: \(block.original)") }
        }
        return mapped
    }
}

/// A drawing surface in points with the origin at the top left.
@MainActor final class Sheet {
    let size: CGSize
    let scale: CGFloat = 2
    let context: CGContext

    init(_ width: CGFloat, _ height: CGFloat, background: NSColor) {
        size = CGSize(width: width, height: height)
        context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.addRect(CGRect(origin: .zero, size: size))
        context.setFillColor(background.cgColor)
        context.fillPath()
    }

    var image: CGImage { context.makeImage()! }

    func flip(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height) }
}

enum Sample {
    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}
