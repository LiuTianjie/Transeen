import AppKit
import CoreText

/// The pipeline on pictures drawn here, so the truth is known: what size,
/// weight and colour each line has, and what the paper under it looks like.
@main struct ScreenPipelineTests {
    struct Sample { var text: String; var size: CGFloat; var weight: NSFont.Weight; var color: NSColor; var origin: CGPoint }

    static func picture(scale: CGFloat) -> CGImage {
        let width = 760.0, height = 300.0
        let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A button: its own paper.
        context.setFillColor(NSColor(srgbRed: 0.04, green: 0.48, blue: 1, alpha: 1).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 40, y: 40, width: 150, height: 36), cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        for sample in samples {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: sample.text, attributes: [
                .font: NSFont.systemFont(ofSize: sample.size, weight: sample.weight), .foregroundColor: sample.color]))
            context.textPosition = CGPoint(x: sample.origin.x, y: (sample.origin.y * scale).rounded() / scale)
            CTLineDraw(line, context)
        }
        return context.makeImage()!
    }

    static let samples = [
        Sample(text: "Privacy and security settings", size: 26, weight: .bold, color: NSColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1), origin: CGPoint(x: 40, y: 230)),
        Sample(text: "Choose which applications may read the screen while you work.", size: 14, weight: .regular,
               color: NSColor(srgbRed: 0.35, green: 0.35, blue: 0.38, alpha: 1), origin: CGPoint(x: 40, y: 190)),
        Sample(text: "Allow access", size: 14, weight: .semibold, color: .white, origin: CGPoint(x: 70, y: 53)),
    ]

    /// A chat sentence containing a red identifier on a grey chip, as in the
    /// reported corruption. The chip and its letters must survive byte-for-byte.
    static func inlinePicture(scale: CGFloat) -> (image: CGImage, chip: CGRect) {
        let height: CGFloat = 130
        let context = CGContext(data: nil, width: Int(920 * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 920, height: height))
        func draw(_ text: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        let font = NSFont.systemFont(ofSize: 18), code = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        let name = "idle_in_transaction_session_timeout"
        let prefix = draw("The connection", x: 20, y: 85, font: font, color: .black)
        let start = 20 + prefix + 10, width = Fitter.width(name, font: code)
        let chip = CGRect(x: start - 4, y: 79, width: width + 8, height: 25)
        context.setFillColor(NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1).cgColor)
        context.addPath(CGPath(roundedRect: chip, cornerWidth: 4, cornerHeight: 4, transform: nil)); context.fillPath()
        _ = draw(name, x: start, y: 85, font: code, color: NSColor(srgbRed: 0.65, green: 0.15, blue: 0.15, alpha: 1))
        _ = draw("stays idle for 10 seconds.", x: start + width + 10, y: 85, font: font, color: .black)
        _ = draw("Check the network connection again.", x: 20, y: 45, font: font, color: .black)
        return (context.makeImage()!, CGRect(x: chip.minX * scale, y: (height - chip.maxY) * scale,
            width: chip.width * scale, height: chip.height * scale))
    }

    /// A navigation bar read as one line, a table whose short cells stack in columns,
    /// and a count at the start of a cell.
    static func layoutPicture(scale: CGFloat) -> CGImage {
        let width = 520.0, height = 200.0
        let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = NSFont.systemFont(ofSize: 14)
        func draw(_ text: String, _ x: CGFloat, _ y: CGFloat) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: 0.15, alpha: 1)]))
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        var x: CGFloat = 40
        for item in ["Products", "Pricing", "Docs", "Support"] {
            draw(item, x, 165)
            x += Fitter.width(item, font: font) + 26
        }
        for (row, cells) in [["Status", "Owner"], ["Running", "2 minutes ago"], ["Failed", "Yesterday"]].enumerated() {
            draw(cells[0], 40, 110 - CGFloat(row) * 21)
            draw(cells[1], 40 + Fitter.width("Running", font: font) + 28, 110 - CGFloat(row) * 21)
        }
        return context.makeImage()!
    }

    static func main() throws {
        var passed = 0
        func check(_ condition: Bool, _ what: String) { precondition(condition, what); passed += 1 }

        // Narrow glyphs can leave an empty sampling ring. Rectangle conversion
        // must survive both that inset and out-of-image OCR coordinates.
        let bounds = PixelRect(minX: 0, minY: 0, maxX: 100, maxY: 100)
        check(PixelRect(CGRect(x: 10, y: 10, width: 2, height: 20).insetBy(dx: 4, dy: 4), in: bounds).isEmpty,
              "an empty glyph sampling ring must not trap converting infinity to Int")
        check(PixelRect(CGRect(x: 150, y: 150, width: 10, height: 10), in: bounds).isEmpty,
              "out-of-image OCR must produce a valid empty pixel range")
        check(PixelRect(CGRect(x: -10, y: -10, width: 30, height: 30), in: bounds)
              == PixelRect(minX: 0, minY: 0, maxX: 20, maxY: 20), "partial OCR bounds must clip to the image")

        let dense = NSImage(contentsOfFile: "Tests/Fixtures/dense-native-text.png")!
        let denseCG = dense.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let denseAnalysis = try ScreenPipeline.analyze(denseCG, scale: 1, source: .en, target: .zhHans)!
        check(denseAnalysis.lines.count == 4, "native text fixture should keep all four OCR lines")
        check(denseAnalysis.lines.allSatisfy { (10...14.5).contains($0.style.size) }, "neighbour ink must not inflate 12pt text to 28pt")
        let denseTranslations = Dictionary(uniqueKeysWithValues: denseAnalysis.blocks.enumerated().map { index, block in
            let text = block.original.contains("next frame") ? "下一帧已到" : block.original.contains("This message") ? "此消息在捕获后已更改。" : block.original.contains("Live translation") ? "实时翻译应自动更新。" : "第二帧"
            return (index, text)
        })
        let fixed = ScreenPipeline.compose(denseAnalysis, translations: denseTranslations)
        if let cg = fixed.pixels.cgImage() {
            try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/tests/dense-fixed.png"))
        }
        let ordered = denseAnalysis.lines.sorted { $0.box.midY < $1.box.midY }
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            check(a.ink.rect.maxY <= b.ink.rect.minY, "adjacent source ink must remain separated")
        }
        for scale in [1.0, 2.0] as [CGFloat] {
            let image = picture(scale: scale)
            guard let analysis = try ScreenPipeline.analyze(image, scale: scale, source: .en, target: .zhHans) else { fatalError("no analysis") }
            func block(_ word: String) -> (index: Int, block: TextBlock)? {
                analysis.blocks.enumerated().first { $0.element.original.contains(word) }.map { ($0.offset, $0.element) }
            }
            guard let title = block("Privacy"), let body = block("Choose"), let button = block("Allow") else {
                fatalError("@\(scale)x: lines not found in \(analysis.blocks.map(\.original))")
            }
            let label = "@\(Int(scale))x"
            // Size from the pixels, not from the recogniser's box.
            check(abs(title.block.style.size - 26) / 26 < 0.05, "\(label) title size \(title.block.style.size)")
            check(abs(body.block.style.size - 14) / 14 < 0.07, "\(label) body size \(body.block.style.size)")
            check(abs(button.block.style.size - 14) / 14 < 0.09, "\(label) button size \(button.block.style.size)")
            check(title.block.style.weight.rawValue >= 600 && body.block.style.weight.rawValue <= 500, "\(label) weights \(title.block.style.weight) \(body.block.style.weight)")
            check(title.block.style.color.luma < 60 && button.block.style.color.luma > 200, "\(label) colours")
            if case .flat(let paper) = button.block.background {
                check(paper.b > 200 && paper.r < 60, "\(label) the button's own paper is its background: \(paper)")
            } else { check(false, "\(label) button background \(button.block.background.name)") }
            check(title.block.translate && body.block.translate && button.block.translate, "\(label) all three are text to translate")

            // Translated in place: strokes gone, paper back, the new text where the old was.
            let composed = ScreenPipeline.compose(analysis, translations: [title.index: "隐私与安全设置", body.index: "选择哪些应用可以在你工作时读取屏幕。", button.index: "允许访问"])
            check(composed.placed.count == 3 && composed.cut == 0, "\(label) three blocks placed, none cut")
            let out = composed.pixels, before = analysis.pixels
            check(out.width == before.width && out.height == before.height, "\(label) the picture keeps its size")
            // The English title ran far to the right of where the Chinese one ends: that stretch is paper again.
            let titleRect = title.block.rect
            let farRight = (x: Int(titleRect.maxX - 6 * scale), y: Int(titleRect.midY))
            var inked = false
            for dx in -Int(8 * scale)...0 where before[farRight.x + dx, farRight.y].luma < 128 { inked = true }
            check(inked, "\(label) there was ink at the end of the English title")
            var clean = true
            for dx in -Int(8 * scale)...0 where out[farRight.x + dx, farRight.y].luma < 245 { clean = false }
            check(clean, "\(label) and it is erased")
            // The button is still blue beside its label, and nothing else in the picture moved.
            let beside = out[Int(46 * scale), Int((300 - 58) * scale)]
            check(beside.b > 200 && beside.r < 60, "\(label) the button keeps its colour: \(beside)")
            let corner = out[Int(700 * scale), Int(280 * scale)]
            check(corner.luma > 250, "\(label) untouched paper stays untouched")
            // Same type size for the translation as for the original.
            let placed = composed.placed.first { $0.index == title.index }!
            check(placed.placement.shrink == 1, "\(label) the Chinese title is set at the original size")

            let rich = inlinePicture(scale: scale)
            let mixed = try ScreenPipeline.analyze(rich.image, scale: scale, source: .en, target: .zhHans)!
            let name = "idle_in_transaction_session_timeout"
            let sentence = mixed.blocks.firstIndex { $0.original.contains("`\(name)`") }
            check(sentence.map { mixed.blocks[$0].translate && mixed.blocks[$0].chips.map(\.text) == [name] } == true,
                  "\(label) the sentence is translated whole, with the identifier as `code`: \(mixed.blocks.map(\.original))")
            let again = mixed.blocks.firstIndex { $0.original.contains("Check") }
            check(sentence != nil && again != nil, "\(label) both sentences are found")
            guard let sentence, let again else { continue }
            let translations = [sentence: "连接`\(name)`已空闲10秒。", again: "再次检查网络连接。"]
            let translated = ScreenPipeline.compose(mixed, translations: translations)
            check(translated.placed.count == 2, "\(label) both sentences are placed")
            let moved = translated.placed.first { $0.index == sentence }?.placement.chips.first
            check(moved != nil, "\(label) the chip moves with its sentence")
            let chip = mixed.blocks[sentence].chips[0].rect
            let dx = Int(moved!.origin.x.rounded()) - Int(chip.minX), dy = Int(moved!.origin.y.rounded()) - Int(chip.minY)
            let protected = PixelRect(rich.chip.insetBy(dx: 1, dy: 1), in: mixed.pixels.bounds)
            var unchanged = true
            for y in protected.minY..<protected.maxY {
                for x in protected.minX..<protected.maxX where mixed.pixels[x, y] != translated.pixels[x + dx, y + dy] { unchanged = false }
            }
            check(unchanged, "\(label) the chip's pixels arrive where it moved, byte for byte")
            // A translation that lost the code would lose it from the picture: the sentence stays as it was.
            let lost = ScreenPipeline.compose(mixed, translations: [sentence: "连接已空闲10秒。"])
            check(!lost.placed.contains { $0.index == sentence }, "\(label) without its chip the sentence keeps its pixels")
            if let cg = translated.pixels.cgImage() {
                try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: "build/tests/inline-\(Int(scale))x.png"))
            }
        }

        // Tiles for a large picture follow the columns of text.
        let lines = [RecognizedLine(text: "a", box: CGRect(x: 100, y: 0, width: 400, height: 20), confidence: 1, startsListItem: false),
                     RecognizedLine(text: "b", box: CGRect(x: 505, y: 40, width: 200, height: 20), confidence: 1, startsListItem: false),
                     RecognizedLine(text: "c", box: CGRect(x: 1500, y: 40, width: 300, height: 20), confidence: 1, startsListItem: false)]
        let columns = Recognizer.columns(width: 2560, initial: lines)
        check(columns.count == 2 && columns[0].0 == 100 && columns[0].1 == 705 && columns[1].0 == 1500, "columns \(columns)")
        check(Recognizer.columns(width: 2560, initial: []).count == 1, "nothing found: the whole width is read again")
        check(Recognizer.shouldKeep("OK", confidence: 0.3) && !Recognizer.shouldKeep("7", confidence: 0.4) && Recognizer.shouldKeep("12:30", confidence: 0.7), "what counts as text")
        check(Recognizer.isLikelyIconPrefix("Q") && !Recognizer.isLikelyIconPrefix("A") && Recognizer.isLikelyIconPrefix("8"), "icons read as letters")

        check(Recognizer.correctedWord("l'll") == "I'll" && Recognizer.correctedWord("Cl.") == "CI." && Recognizer.correctedWord("APl") == "API"
              && Recognizer.correctedWord("Clear") == "Clear" && Recognizer.correctedWord("all") == "all", "I read as l in interface type")
        let split = Recognizer.corrected([
            .init(text: "touches", box: CGRect(x: 0, y: 0, width: 50, height: 10), separator: "", literal: false),
            .init(text: "project.", box: CGRect(x: 55, y: 0, width: 40, height: 10), separator: " ", literal: false),
            .init(text: "yml", box: CGRect(x: 97, y: 0, width: 20, height: 10), separator: " ", literal: false)])
        check(split.count == 2 && split[1].text == "project.yml" && split[1].literal && split[1].box.maxX == 117, "a file name split after its dot is one literal: \(split.map(\.text))")
        check(CodeText.isFileName("notes-0.9.0.md") && !CodeText.isFileName("v0.9.0") && !CodeText.isFileName("done."), "file names")
        check(!Recognizer.isLikelyIconPrefix("2", before: "minutes ago") && Recognizer.isLikelyIconPrefix("2", before: "Inbox"), "a count before a word is text")
        for scale in [1.0, 2.0] {
            let layout = try ScreenPipeline.analyze(layoutPicture(scale: scale), scale: scale, source: .en, target: .zhHans)!
            let texts = layout.blocks.map(\.original)
            check(["Products", "Pricing", "Docs", "Support"].allSatisfy(texts.contains), "\(Int(scale))x navigation items stay apart: \(texts)")
            check(["Running", "Failed", "2 minutes ago", "Yesterday"].allSatisfy(texts.contains), "\(Int(scale))x stacked table cells stay apart, with their counts: \(texts)")
        }

        print("ScreenPipelineTests: \(passed) checks passed")
    }
}
