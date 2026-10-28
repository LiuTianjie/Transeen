import AppKit
import SwiftUI
import CoreText

/// Public-safe website artwork. Authored sample screens go through the production OCR,
/// compositor, annotation drawing and toolbar with fixed translations; the desktop is never captured.
@main struct WebsitePreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: "build/website-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let save = { (image: CGImage, name: String) in
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent(name + ".png"))
        }

        let docs = Sample.docs()
        try save(docs.image, "docs-en")
        var docsChinese: (image: CGImage, toolbar: CGImage)?
        for (language, strings) in Sample.docsTranslations {
            let translated = try translate(docs, from: .en, to: language, strings)
            let bar = toolbar(scale: 2) { $0.direction = "EN → \(language.shortName)"; $0.target = language }
            try save(translated, "docs-\(language.rawValue.lowercased())")
            try save(bar, "toolbar-\(language.rawValue.lowercased())")
            if language == .zhHans { docsChinese = (translated, bar) }
        }
        if let docsChinese {
            let composite = capture(docsChinese.image, size: docs.size, toolbar: docsChinese.toolbar)
            try save(composite, "capture-docs")
            try save(readmePreview(composite), "preview")
        }

        let chart = Sample.chart()
        let chartTranslated = try translate(chart, from: .en, to: .zhHans, Sample.chartTranslation)
        let annotated = annotate(chartTranslated, size: chart.size, marks: Sample.chartMarks)
        try save(chart.image, "chart-en")
        try save(selecting(chart.image, size: chart.size, selection: Sample.chartSelection), "chart-select")

        let read = toolbar(scale: 2) { _ in }
        let mark = toolbar(scale: 2, markState)
        let kept = toolbar(scale: 2) { state in
            state.copyCompleted = true
            state.pinned = true
        }
        try save(read, "toolbar-read")
        try save(toolbar(scale: 2) { $0.overlay = false }, "toolbar-original")
        try save(mark, "toolbar-mark")
        try save(kept, "toolbar-kept")
        try save(capture(chartTranslated, size: chart.size, toolbar: read), "capture-read")
        try save(capture(annotated, size: chart.size, toolbar: mark), "capture-mark")
        try save(capture(annotated, size: chart.size, toolbar: kept), "capture-keep")

        // Close-ups for the toolbar board: 8 pixels per point, cropped in points.
        let markLarge = toolbar(scale: 8, markState)
        let keptLarge = toolbar(scale: 8) { state in
            state.copyCompleted = true
            state.pinned = true
        }
        try save(markLarge, "toolbar-mark-8x")
        try save(keptLarge, "toolbar-kept-8x")
        try save(toolbar(scale: 8, dark: true, markState), "toolbar-mark-8x-dark")

        // The first-run permission window, as a Mac without Screen Recording access shows it.
        NSImage(contentsOfFile: "Sources/Resources/AppIcon.png")?.setName("AppIcon")
        try save(render(PermissionGuide(permission: ScreenPermission(), continueCapture: {}, later: {}).background(Color(nsColor: .windowBackgroundColor)), scale: 2), "permission")
        try save(toolbar(scale: 8, dark: true) { state in
            state.copyCompleted = true
            state.pinned = true
        }, "toolbar-kept-8x-dark")
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
        let sheet = Sheet(1200, 740, background: Sample.color(0x0b0e0d))
        let size = CGSize(width: CGFloat(composite.width) / 2, height: CGFloat(composite.height) / 2)
        sheet.context.draw(composite, in: sheet.flip(CGRect(x: (1200 - size.width) / 2, y: (740 - size.height) / 2, width: size.width, height: size.height)))
        return sheet.image
    }

    /// Recognises the authored sheet with the production pipeline and composes it with fixed
    /// translations, matched to the recognised blocks by their letters and digits.
    @MainActor static func translate(_ sheet: Sheet, from source: AppLanguage, to target: AppLanguage, _ strings: [(String, String)]) throws -> CGImage {
        let analysis = try ScreenPipeline.analyze(sheet.image, scale: sheet.scale, source: source, target: target)!
        func key(_ text: String) -> String { String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)) }
        let table = Dictionary(strings.map { (key($0.0), $0.1) }, uniquingKeysWith: { first, _ in first })
        var mapped: [Int: String] = [:]
        for (index, block) in analysis.blocks.enumerated() {
            if let translation = table[key(block.original)] {
                mapped[index] = translation
            } else {
                print("\(target.rawValue) kept: \(block.original)")
            }
        }
        if mapped.count != strings.count { print("\(target.rawValue): \(mapped.count) of \(strings.count) strings placed") }
        return ScreenPipeline.compose(analysis, translations: mapped).pixels.cgImage()!
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

    /// The selection overlay as `ScreenSelectionView.draw` paints it mid-drag.
    @MainActor static func selecting(_ image: CGImage, size: CGSize, selection: CGRect) -> CGImage {
        let sheet = Sheet(size.width, size.height, background: .white)
        let context = sheet.context
        context.draw(image, in: CGRect(origin: .zero, size: size))
        let highlight = sheet.flip(selection)
        let radius = min(10, min(highlight.width, highlight.height) / 6)
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
        let r = highlight.insetBy(dx: 2, dy: 2)
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            context.move(to: CGPoint(x: x, y: y + 12 * dy))
            context.addLine(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x + 12 * dx, y: y))
        }
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(2.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        let prompt = NSAttributedString(string: "\(Int(selection.width * 2)) × \(Int(selection.height * 2)) px  ·  松开完成", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.black.withAlphaComponent(0.85)
        ])
        let chip = CGRect(x: selection.maxX - prompt.size().width - 24 + 18, y: selection.maxY + 12, width: prompt.size().width + 24, height: 34)
        let chipPath = CGPath(roundedRect: sheet.flip(chip), cornerWidth: 11, cornerHeight: 11, transform: nil)
        context.addPath(chipPath)
        context.setFillColor(NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1).cgColor)
        context.fillPath()
        context.addPath(chipPath)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.1).cgColor)
        context.setLineWidth(0.75)
        context.strokePath()
        let line = CTLineCreateWithAttributedString(prompt)
        context.textPosition = CGPoint(x: chip.minX + 12, y: size.height - chip.minY - 22)
        CTLineDraw(line, context)
        return sheet.image
    }

    /// A capture as the panel shows it in place: the picture inside the pin border, the toolbar
    /// centred 8 points below it (the toolbar image carries its own 8-point margin).
    @MainActor static func capture(_ image: CGImage, size: CGSize, toolbar: CGImage) -> CGImage {
        let barSize = CGSize(width: CGFloat(toolbar.width) / 2, height: CGFloat(toolbar.height) / 2)
        let width = max(size.width + 4, barSize.width), height = size.height + 4 + barSize.height
        let sheet = Sheet(width, height, background: .clear)
        let frame = CGRect(x: (width - size.width) / 2, y: 2, width: size.width, height: size.height)
        sheet.context.draw(image, in: sheet.flip(frame))
        sheet.stroke(frame.insetBy(dx: -0.5, dy: -0.5), NSColor.black.withAlphaComponent(0.38), width: 3)
        sheet.stroke(frame.insetBy(dx: 0.8, dy: 0.8), NSColor.white.withAlphaComponent(0.95), width: 1.6)
        sheet.context.draw(toolbar, in: sheet.flip(CGRect(x: (width - barSize.width) / 2, y: size.height + 4, width: barSize.width, height: barSize.height)))
        return sheet.image
    }

    @MainActor static func toolbar(scale: CGFloat, dark: Bool = false, _ configure: (CaptureState) -> Void) -> CGImage {
        let state = CaptureState()
        state.translated = true
        state.direction = "EN → 中文"
        state.detectsSource = false
        state.textBlocks = [CaptureTextBlock(id: 0, original: "Where readers come from", translation: "读者从哪里来")]
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

/// A drawing surface in points with the origin at the top left; text is placed by its baseline.
@MainActor final class Sheet {
    let size: CGSize
    let scale: CGFloat = 2
    let context: CGContext

    init(_ width: CGFloat, _ height: CGFloat, background: NSColor) {
        size = CGSize(width: width, height: height)
        context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        fill(CGRect(origin: .zero, size: size), background)
    }

    var image: CGImage { context.makeImage()! }

    func flip(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height) }

    func fill(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
        context.addPath(CGPath(roundedRect: flip(rect), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(color.cgColor)
        context.fillPath()
    }

    func stroke(_ rect: CGRect, _ color: NSColor, width: CGFloat) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.stroke(flip(rect))
    }

    func line(_ from: CGPoint, _ to: CGPoint, _ color: NSColor, width: CGFloat = 1) {
        context.move(to: CGPoint(x: from.x, y: size.height - from.y))
        context.addLine(to: CGPoint(x: to.x, y: size.height - to.y))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.strokePath()
    }

    @discardableResult
    func text(_ value: String, _ x: CGFloat, _ baseline: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor,
              mono: Bool = false, alignRight: Bool = false, centre: Bool = false) -> CGFloat {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let start = alignRight ? x - width : centre ? x - width / 2 : x
        context.textPosition = CGPoint(x: start, y: self.size.height - baseline)
        CTLineDraw(line, context)
        return width
    }
}

enum Sample {
    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// A documentation page with a sidebar, a callout, a code block, numbered steps and a button.
    @MainActor static func docs() -> Sheet {
        let sheet = Sheet(720, 500, background: .white)
        let ink = color(0x16181d), muted = color(0x5b616e), blue = color(0x2557d6)
        sheet.fill(CGRect(x: 0, y: 0, width: 188, height: 500), color(0xf5f6f8))
        sheet.text("GUIDE", 24, 46, 11, .semibold, color(0x868c98))
        let items = ["Getting started", "Sync your notes", "Share a notebook", "Keyboard shortcuts", "Troubleshooting"]
        for (index, item) in items.enumerated() {
            let baseline = 80 + CGFloat(index) * 32
            if index == 1 { sheet.fill(CGRect(x: 12, y: baseline - 20, width: 164, height: 30), color(0xe5ecfc), radius: 7) }
            sheet.text(item, 24, baseline, 13, index == 1 ? .semibold : .regular, index == 1 ? blue : color(0x3d424d))
        }
        let left: CGFloat = 220
        sheet.text("Guide  /  Sync", left, 50, 12, .regular, muted)
        sheet.text("Keep every device in sync", left, 94, 28, .semibold, ink)
        sheet.text("Turn on sync once, and every change you make", left, 128, 15, .regular, color(0x3b414d))
        sheet.text("shows up on your other devices within seconds.", left, 150, 15, .regular, color(0x3b414d))
        sheet.fill(CGRect(x: left, y: 174, width: 472, height: 74), color(0xeef3ff), radius: 10)
        sheet.text("Before you begin", left + 18, 202, 13, .semibold, color(0x2347b8))
        sheet.text("Every device needs version 4.2 or later.", left + 18, 226, 14, .regular, color(0x2b3140))
        sheet.fill(CGRect(x: left, y: 262, width: 472, height: 58), color(0x1c2130), radius: 10)
        sheet.text("$ notes --version", left + 18, 286, 13, .regular, color(0xd7dce6), mono: true)
        sheet.text("notes 4.2.1", left + 18, 306, 13, .regular, color(0x8ea0c4), mono: true)
        let steps = ["Open Settings and choose Account.", "Turn on Sync, then sign in.", "Wait for the green check next to each device."]
        for (index, step) in steps.enumerated() {
            let baseline = 356 + CGFloat(index) * 32
            sheet.fill(CGRect(x: left, y: baseline - 15, width: 20, height: 20), blue, radius: 10)
            sheet.text("\(index + 1)", left + 10, baseline - 0.5, 11, .semibold, .white, centre: true)
            sheet.text(step, left + 32, baseline, 14, .regular, ink)
        }
        sheet.fill(CGRect(x: left, y: 438, width: 168, height: 38), blue, radius: 8)
        sheet.text("Turn on sync", left + 84, 462, 14, .semibold, .white, centre: true)
        sheet.text("Read the FAQ", left + 196, 462, 14, .medium, blue)
        return sheet
    }

    static let docsSource = [
        "GUIDE", "Getting started", "Sync your notes", "Share a notebook", "Keyboard shortcuts", "Troubleshooting",
        "Guide / Sync", "Keep every device in sync",
        "Turn on sync once, and every change you make shows up on your other devices within seconds.",
        "Before you begin", "Every device needs version 4.2 or later.",
        "Open Settings and choose Account.", "Turn on Sync, then sign in.", "Wait for the green check next to each device.",
        "Turn on sync", "Read the FAQ"
    ]

    static let docsTranslations: [(AppLanguage, [(String, String)])] = [
        (.zhHans, zip(docsSource, [
            "指南", "快速上手", "同步笔记", "共享笔记本", "键盘快捷键", "疑难解答",
            "指南 / 同步", "让每台设备保持同步",
            "只需开启一次同步，你的每处修改都会在几秒内出现在其他设备上。",
            "开始之前", "每台设备都需要 4.2 或更高版本。",
            "打开“设置”，选择“账户”。", "开启“同步”，然后登录。", "等待每台设备旁出现绿色对勾。",
            "开启同步", "阅读常见问题"
        ]).map { $0 }),
        (.zhHant, zip(docsSource, [
            "指南", "快速入門", "同步筆記", "共享筆記本", "鍵盤快速鍵", "疑難排解",
            "指南 / 同步", "讓每台裝置保持同步",
            "只要開啟一次同步，你的每項變更都會在幾秒內出現在其他裝置上。",
            "開始之前", "每台裝置都需要 4.2 或以上版本。",
            "打開「設定」，選擇「帳號」。", "開啟「同步」，然後登入。", "等待每台裝置旁出現綠色勾號。",
            "開啟同步", "閱讀常見問題"
        ]).map { $0 }),
        (.ja, zip(docsSource, [
            "ガイド", "はじめに", "メモを同期", "ノートブックを共有", "キーボードショートカット", "トラブルシューティング",
            "ガイド / 同期", "すべてのデバイスを同期",
            "同期を一度オンにすれば、変更は数秒でほかのデバイスにも反映されます。",
            "始める前に", "すべてのデバイスにバージョン 4.2 以降が必要です。",
            "「設定」を開き、「アカウント」を選びます。", "「同期」をオンにして、サインインします。", "各デバイスの横に緑のチェックが付くまで待ちます。",
            "同期をオン", "よくある質問"
        ]).map { $0 }),
        (.ko, zip(docsSource, [
            "가이드", "시작하기", "메모 동기화", "노트북 공유", "키보드 단축키", "문제 해결",
            "가이드 / 동기화", "모든 기기를 동기화하세요",
            "동기화를 한 번만 켜면 변경 사항이 몇 초 안에 다른 기기에도 나타납니다.",
            "시작하기 전에", "모든 기기에 4.2 이상 버전이 필요합니다.",
            "설정을 열고 계정을 선택하세요.", "동기화를 켠 다음 로그인하세요.", "각 기기 옆에 녹색 체크가 나타날 때까지 기다리세요.",
            "동기화 켜기", "FAQ 읽기"
        ]).map { $0 }),
        (.fr, zip(docsSource, [
            "GUIDE", "Premiers pas", "Synchroniser vos notes", "Partager un carnet", "Raccourcis clavier", "Dépannage",
            "Guide / Synchro", "Synchronisez vos appareils",
            "Activez la synchro une fois : vos changements arrivent partout en quelques secondes.",
            "Avant de commencer", "Chaque appareil doit avoir la version 4.2 ou plus.",
            "Ouvrez Réglages et choisissez Compte.", "Activez Synchro, puis connectez-vous.", "Attendez la coche verte à côté de chaque appareil.",
            "Activer la synchro", "Lire la FAQ"
        ]).map { $0 }),
        (.de, zip(docsSource, [
            "ANLEITUNG", "Erste Schritte", "Notizen synchronisieren", "Notizbuch teilen", "Tastaturkurzbefehle", "Fehlerbehebung",
            "Anleitung / Sync", "Alle Geräte synchron halten",
            "Aktiviere Sync einmal, und jede Änderung erscheint in Sekunden auf deinen anderen Geräten.",
            "Bevor du beginnst", "Jedes Gerät braucht Version 4.2 oder neuer.",
            "Öffne die Einstellungen und wähle Account.", "Aktiviere Sync und melde dich an.", "Warte auf das grüne Häkchen neben jedem Gerät.",
            "Sync aktivieren", "FAQ lesen"
        ]).map { $0 }),
        (.es, zip(docsSource, [
            "GUÍA", "Primeros pasos", "Sincronizar notas", "Compartir un cuaderno", "Atajos de teclado", "Solución de problemas",
            "Guía / Sincronizar", "Sincroniza tus dispositivos",
            "Activa la sincronización una vez y cada cambio aparecerá en tus otros dispositivos en segundos.",
            "Antes de empezar", "Cada dispositivo necesita la versión 4.2 o posterior.",
            "Abre Ajustes y elige Cuenta.", "Activa la sincronización e inicia sesión.", "Espera la marca verde junto a cada dispositivo.",
            "Sincronizar", "Leer las preguntas"
        ]).map { $0 })
    ]

    /// A report chart: one label per row, so every label is its own recognised block.
    @MainActor static func chart() -> Sheet {
        let sheet = Sheet(640, 404, background: .white)
        let ink = color(0x111827), muted = color(0x6b7280), faint = color(0x9aa1ad)
        sheet.text("Where readers come from", 32, 50, 21, .semibold, ink)
        sheet.text("Share of weekly visits, June 2026", 32, 76, 13, .regular, muted)
        let rows: [(String, CGFloat, UInt32)] = [("Search", 41, 0x2f6fed), ("Newsletter", 23, 0x22a06b), ("Social media", 18, 0x7aa7f7),
                                                  ("Direct visits", 12, 0x9db8f2), ("Other", 6, 0xc6d3ee)]
        for (index, row) in rows.enumerated() {
            let top = 112 + CGFloat(index) * 46
            sheet.text(row.0, 32, top + 21, 14, .medium, color(0x374151))
            let length = row.1 * 8.4
            sheet.fill(CGRect(x: 160, y: top + 4, width: length, height: 24), color(row.2), radius: 4)
            sheet.text("\(Int(row.1))%", 160 + length + 10, top + 21, 13, .semibold, color(0x374151))
        }
        sheet.fill(CGRect(x: 424, y: 151, width: 192, height: 36), color(0x111827), radius: 8)
        sheet.text("Up 9 points since March", 520, 174, 12, .medium, .white, centre: true)
        sheet.line(CGPoint(x: 424, y: 169), CGPoint(x: 402, y: 169), color(0x111827), width: 1.5)
        sheet.text("Source: in-app analytics", 32, 378, 12, .regular, faint)
        return sheet
    }

    static let chartTranslation: [(String, String)] = [
        ("Where readers come from", "读者从哪里来"), ("Share of weekly visits, June 2026", "每周访问占比，2026 年 6 月"),
        ("Search", "搜索"), ("Newsletter", "邮件简报"), ("Social media", "社交媒体"), ("Direct visits", "直接访问"), ("Other", "其他"),
        ("Up 9 points since March", "比 3 月高 9 个百分点"), ("Source: in-app analytics", "来源：应用内统计")
    ]

    static let chartSelection = CGRect(x: 18, y: 92, width: 604, height: 262)

    @MainActor static var chartMarks: [Annotation] {
        [
            Annotation(tool: .rectangle, points: [CGPoint(x: 22, y: 148), CGPoint(x: 404, y: 198)], color: .systemRed, width: 4),
            Annotation(tool: .arrow, points: [CGPoint(x: 574, y: 246), CGPoint(x: 532, y: 196)], color: .systemGreen, width: 4),
            Annotation(tool: .number, points: [CGPoint(x: 604, y: 128)], color: .systemRed, width: 4, number: 1),
            Annotation(tool: .number, points: [CGPoint(x: 126, y: 128)], color: .systemOrange, width: 4, number: 2)
        ]
    }
}
