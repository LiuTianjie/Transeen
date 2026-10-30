import AppKit
import CryptoKit

/// Downloads into a temporary store from a local HTTP server and runs a translation
/// through the bundled llama-server when TRANSEEN_TEST_MODEL points at a downloaded model.
@main struct LocalModelTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        check(LocalModelCatalog.model(id: LocalModelCatalog.defaultID) != nil)
        check(Set(LocalModelCatalog.all.map(\.id)).count == LocalModelCatalog.all.count)
        for model in LocalModelCatalog.all {
            check(model.sha256.count == 64 && model.bytes > 500_000_000)
            check(model.sources(region: "CN").first == model.modelScope && model.sources(region: "US").first == model.huggingFace)
        }

        let index = LocalPrompt.message("Bump to 0.9.0", source: .en, target: .zhHans, prompt: .index)
        check(index == "请将以下英语文本翻译为简体中文，直接输出翻译结果，不要进行任何解释。\n\nBump to 0.9.0")
        check(LocalPrompt.message("x", source: .en, target: .zhHans, prompt: .hunyuan).hasPrefix("将以下文本翻译为简体中文"))
        check(LocalPrompt.message("x", source: .en, target: .ja, prompt: .hunyuan).hasPrefix("Translate the following text into Japanese."))
        check(LocalPrompt.clean("<think>\n\n</think>\n\n你好") == "你好")
        check(LocalPrompt.maxTokens(for: String(repeating: "a", count: 10_000)) == 2048)

        let defaults = UserDefaults(suiteName: "transeen.local.tests.\(UUID().uuidString)")!
        defaults.set(true, forKey: "useModel")
        check(AppSettings(defaults: defaults).service == .remote, "A saved remote model setting must survive the new service picker")
        defaults.removeObject(forKey: "useModel")
        let fresh = AppSettings(defaults: defaults)
        check(fresh.service == .apple && fresh.localModel == LocalModelCatalog.defaultID)
        fresh.service = .local
        check(AppSettings(defaults: defaults).service == .local)

        try await downloads()
        if let path = ProcessInfo.processInfo.environment["TRANSEEN_TEST_MODEL"] { try await translation(model: path) }
        else { print("LocalModelTests: skipped the live translation (set TRANSEEN_TEST_MODEL and TRANSEEN_LLAMA_SERVER)") }
        print("LocalModelTests: catalog, prompts, settings migration, resumable verified download, corrupt file rejection passed")
    }

    /// A partial file continues with a Range request; a wrong checksum is deleted.
    @MainActor static func downloads() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "transeen-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let served = root.appending(path: "served")
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: served.appending(path: "model.gguf"))
        let server = Process()
        server.executableURL = URL(filePath: "/usr/bin/python3")
        let port = 18_000 + Int.random(in: 0..<2000)
        server.arguments = ["-c", """
        import http.server, os, re
        class H(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_GET(self):
                data = open(os.path.join('\(served.path)', 'model.gguf'), 'rb').read()
                m = re.match(r'bytes=(\\d+)-', self.headers.get('Range', ''))
                start = int(m.group(1)) if m else 0
                self.send_response(206 if m else 200)
                if m: self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, len(data) - 1, len(data)))
                self.send_header('Content-Length', str(len(data) - start)); self.end_headers()
                self.wfile.write(data[start:])
        http.server.HTTPServer(('127.0.0.1', \(port)), H).serve_forever()
        """]
        try server.run()
        defer { server.terminate() }
        let url = URL(string: "http://127.0.0.1:\(port)/model.gguf")!
        for _ in 0..<100 {
            if (try? await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1))) != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let good = LocalModel(id: "t", name: "Test", summaryKey: "", file: "model.gguf", bytes: Int64(payload.count), sha256: digest,
                              modelScope: url, huggingFace: url, prompt: .index)
        let store = LocalModelStore(directory: root.appending(path: "models"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try payload.prefix(1_234_567).write(to: store.directory.appending(path: "model.gguf.partial"))
        store.download(good)
        try await wait { store.status(good) == .installed || { if case .failed = store.status(good) { true } else { false } }() }
        check(store.status(good) == .installed, "Resumed download must finish: \(store.status(good))")
        let downloaded = try Data(contentsOf: store.url(for: good))
        check(downloaded == payload, "Resumed download must equal the served file")
        check(store.isInstalled(good))
        store.delete(good)
        check(!store.isInstalled(good) && store.status(good) == .missing)

        let bad = LocalModel(id: "b", name: "Bad", summaryKey: "", file: "model.gguf", bytes: Int64(payload.count), sha256: String(repeating: "0", count: 64),
                             modelScope: url, huggingFace: url, prompt: .index)
        store.download(bad)
        try await wait { if case .failed = store.status(bad) { true } else { false } }
        check(store.status(bad) == .failed(LocalModelError.corrupted.localizedDescription), "A wrong checksum must fail as corrupted: \(store.status(bad))")
        check(!FileManager.default.fileExists(atPath: store.directory.appending(path: "model.gguf.partial").path), "A corrupt download must be deleted")
        check(!store.isInstalled(bad))
    }

    @MainActor static func translation(model path: String) async throws {
        let file = URL(filePath: path)
        let bytes = (try FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).int64Value
        let model = LocalModel(id: "live", name: "Live", summaryKey: "", file: file.lastPathComponent, bytes: bytes, sha256: "",
                               modelScope: file, huggingFace: file, prompt: path.contains("Hy-MT") ? .hunyuan : .index)
        let store = LocalModelStore(directory: file.deletingLastPathComponent())
        let runtime = LocalModelRuntime()
        let lines = ["Notarization finished. Waiting for CI.", "Show all files", "Open in Finder", "Keyboard shortcuts",
                     "Terms of Service", "Sign in with Apple", "Download the packages"]
        let height = lines.count * 70 + 20
        let ctx = CGContext(data: nil, width: 900, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 900, height: height))
        // More blocks than parallel requests: each answer must land on its own block.
        for (y, text) in lines.enumerated().map({ (height - 60 - $0.offset * 70, $0.element) }) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black]))
            ctx.textPosition = CGPoint(x: 24, y: y); CTLineDraw(line, ctx)
        }
        let analysis = try ScreenPipeline.analyze(ctx.makeImage()!, scale: 1, source: .en, target: .zhHans, detectsSource: true)!
        let backend = try LocalModelTranslationBackend(model: model, store: store, runtime: runtime)
        let started = Date()
        var reports: [Int] = []
        let output = try await backend.translate(analysis, direction: TranslationDirection(source: .en, target: .zhHans), app: nil) { reports.append($0.translations.count) }
        check(reports.count > 2 && reports == reports.sorted(), "Answers must be reported as they arrive, growing: \(reports)")
        let first = Date().timeIntervalSince(started)
        let texts = output.translations.values.sorted()
        check(texts.count == analysis.blocks.filter(\.translate).count && texts.allSatisfy { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } },
                     "Every block must come back in Chinese: \(texts)")
        check(Set(texts).count == texts.count, "Each block must keep its own translation: \(texts)")
        for (original, word) in [("Keyboard shortcuts", "快捷键"), ("Terms of Service", "条款"), ("Show all files", "文件")] {
            guard let index = analysis.blocks.firstIndex(where: { $0.original == original }) else { continue }
            check(output.translations[index]?.contains(word) == true, "Answers must not be shuffled: \(output.translations)")
        }
        let again = Date()
        _ = try await backend.translate(analysis, direction: TranslationDirection(source: .en, target: .zhHans), app: nil) { _ in }
        check(Date().timeIntervalSince(again) < 0.5, "A repeated capture must use the cache and the running server")
        runtime.stop()
        print("LocalModelTests: live translation in \(String(format: "%.1f", first))s including model load: \(texts)")
    }

    @MainActor static func wait(_ done: () -> Bool) async throws {
        for _ in 0..<1200 where !done() { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// `precondition` drops its message in -O builds; CI needs the reason.
    static func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
        guard !condition else { return }
        FileHandle.standardError.write(Data("LocalModelTests failed at line \(line): \(message())\n".utf8))
        exit(1)
    }
}
