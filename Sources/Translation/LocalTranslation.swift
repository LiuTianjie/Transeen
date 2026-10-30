import Darwin
import Foundation

/// The bundled llama-server running one downloaded model, bound to 127.0.0.1 with a key
/// made per launch. It starts with the first capture that needs it and exits after a few
/// idle minutes, so the model's memory is only held while the user is translating.
@MainActor
final class LocalModelRuntime {
    static let shared = LocalModelRuntime()
    static let idleLimit: Duration = .seconds(300)

    struct Endpoint: Sendable {
        let url: URL
        let key: String
    }

    private var process: Process?
    private var running: (model: String, endpoint: Endpoint)?
    private var starting: (model: String, task: Task<Endpoint, Error>)?
    private var idle: Task<Void, Never>?
    private var busy = 0

    static var helperURL: URL? {
        #if arch(arm64)
        if let path = ProcessInfo.processInfo.environment["TRANSEEN_LLAMA_SERVER"] { return URL(filePath: path) }
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/llama-server")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        #else
        return nil
        #endif
    }

    static var isSupported: Bool { helperURL != nil }

    /// Starts the server early, so loading the model overlaps the user's selection.
    func prewarm(_ model: LocalModel, store: LocalModelStore) {
        guard running?.model != model.id, starting?.model != model.id, store.isInstalled(model) else { return }
        Task { _ = try? await endpoint(for: model, store: store) }
    }

    func endpoint(for model: LocalModel, store: LocalModelStore) async throws -> Endpoint {
        if let running, running.model == model.id, process?.isRunning == true {
            scheduleIdleStop()
            return running.endpoint
        }
        if let starting, starting.model == model.id { return try await starting.task.value }
        stop()
        guard let helper = Self.helperURL else { throw Self.isSupported ? LocalModelError.missingHelper : LocalModelError.unsupportedMac }
        guard store.isInstalled(model) else { throw LocalModelError.notDownloaded(model.name) }
        let file = store.url(for: model)
        let task = Task { @MainActor [weak self] () throws -> Endpoint in
            guard let self else { throw CancellationError() }
            return try await self.launch(helper: helper, model: file)
        }
        starting = (model.id, task)
        defer { if starting?.model == model.id { starting = nil } }
        let endpoint = try await task.value
        running = (model.id, endpoint)
        scheduleIdleStop()
        return endpoint
    }

    /// Keeps the server alive while a capture uses it.
    func begin() { busy += 1; idle?.cancel() }
    func end() { busy = max(0, busy - 1); scheduleIdleStop() }

    func stop() {
        idle?.cancel(); idle = nil
        starting?.task.cancel(); starting = nil
        running = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private func scheduleIdleStop() {
        idle?.cancel()
        guard busy == 0 else { return }
        idle = Task { [weak self] in
            do { try await Task.sleep(for: Self.idleLimit) } catch { return }
            self?.stop()
        }
    }

    /// The server does not notice its parent exiting. This shell stays between them and
    /// ends the server within a second of Transeen quitting or crashing.
    private static let watchdog = #"p=$1; shift; "$@" & c=$!; trap 'kill $c 2>/dev/null; wait $c; exit 0' TERM INT HUP; while kill -0 $p 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 1; done; kill $c 2>/dev/null; wait $c"#

    private func launch(helper: URL, model: URL) async throws -> Endpoint {
        let port = try Self.freePort()
        let key = UUID().uuidString + UUID().uuidString
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", Self.watchdog, "transeen-llama", String(getpid()), helper.path,
                             "--model", model.path, "--host", "127.0.0.1", "--port", String(port),
                             "--n-gpu-layers", "99", "--ctx-size", "16384", "--parallel", "4",
                             "--jinja", "--no-webui", "--log-disable"]
        process.environment = ["LLAMA_API_KEY": key]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self, self.process === ended else { return }
                self.process = nil
                self.running = nil
            }
        }
        try process.run()
        self.process = process
        let endpoint = Endpoint(url: URL(string: "http://127.0.0.1:\(port)")!, key: key)
        let health = endpoint.url.appending(path: "health")
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { process.terminate(); throw CancellationError() }
            guard process.isRunning else { throw LocalModelError.startFailed }
            var request = URLRequest(url: health, timeoutInterval: 2)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await LocalChat.session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 { return endpoint }
            try? await Task.sleep(for: .milliseconds(150))
        }
        process.terminate()
        throw LocalModelError.startFailed
    }

    nonisolated private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalModelError.startFailed }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw LocalModelError.startFailed }
        return UInt16(bigEndian: address.sin_port)
    }
}

/// The prompts each model was trained with: Index-Translate and Hy-MT2 take a single
/// user message and no system message.
enum LocalPrompt {
    static func message(_ text: String, source: AppLanguage, target: AppLanguage, prompt: LocalModel.Prompt) -> String {
        switch prompt {
        case .index:
            return "请将以下\(chineseName(source))文本翻译为\(chineseName(target))，直接输出翻译结果，不要进行任何解释。\n\n\(text)"
        case .hunyuan:
            if [source, target].contains(where: { [.zhHans, .zhHant].contains($0) }) {
                return "将以下文本翻译为\(chineseName(target))，注意只需要输出翻译后的结果，不要额外解释：\n\n\(text)"
            }
            return "Translate the following text into \(englishName(target)). Note that you should only output the translated result without any additional explanation:\n\n\(text)"
        }
    }

    static func sampling(_ prompt: LocalModel.Prompt) -> [String: Any] {
        switch prompt {
        case .index: return ["temperature": 0.2, "chat_template_kwargs": ["enable_thinking": false]]
        case .hunyuan: return ["temperature": 0.7, "top_p": 0.6, "top_k": 20, "repeat_penalty": 1.05]
        }
    }

    /// Output room for one block: a translation is rarely more than three tokens per input byte.
    static func maxTokens(for text: String) -> Int { min(2048, text.utf8.count * 3 + 64) }

    static func clean(_ answer: String) -> String {
        answer.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func chineseName(_ language: AppLanguage) -> String {
        switch language {
        case .zhHans: "简体中文"
        case .zhHant: "繁体中文"
        case .en: "英语"
        case .ja: "日语"
        case .ko: "韩语"
        case .fr: "法语"
        case .es: "西班牙语"
        case .de: "德语"
        }
    }

    static func englishName(_ language: AppLanguage) -> String {
        switch language {
        case .zhHans: "Simplified Chinese"
        case .zhHant: "Traditional Chinese"
        case .en: "English"
        case .ja: "Japanese"
        case .ko: "Korean"
        case .fr: "French"
        case .es: "Spanish"
        case .de: "German"
        }
    }
}

enum LocalChat {
    static let session: URLSession = {
        let options = URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil; options.urlCache = nil; options.httpShouldSetCookies = false
        options.connectionProxyDictionary = [:]
        options.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: options)
    }()

    static func translate(_ text: String, source: AppLanguage, target: AppLanguage, prompt: LocalModel.Prompt, endpoint: LocalModelRuntime.Endpoint) async throws -> String {
        var body = LocalPrompt.sampling(prompt)
        body["messages"] = [["role": "user", "content": LocalPrompt.message(text, source: source, target: target, prompt: prompt)]]
        body["max_tokens"] = LocalPrompt.maxTokens(for: text)
        body["stream"] = false
        var request = URLRequest(url: endpoint.url.appending(path: "v1/chat/completions"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let answer = LocalPrompt.clean(try ModelHTTP.decode(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0))
        guard !answer.isEmpty else { throw LocalModelError.noTranslation }
        return answer
    }
}

@MainActor
final class LocalModelTranslationBackend: TranslationBackend {
    /// A named type: Swift 6.4 at -O drops the index of an `(Int, Result<String, Error>)` child-task result.
    private struct Answer: Sendable {
        let index: Int
        let text: String?
        let error: Error?
    }
    let model: LocalModel
    private let store: LocalModelStore
    private let runtime: LocalModelRuntime
    private var cache = ScreenTranslationCache()
    private var work: Task<TranslationOutput, Error>?

    init(model: LocalModel, store: LocalModelStore = .shared, runtime: LocalModelRuntime = .shared) throws {
        guard LocalModelRuntime.isSupported else { throw LocalModelError.unsupportedMac }
        guard store.isInstalled(model) else { throw LocalModelError.notDownloaded(model.name) }
        self.model = model; self.store = store; self.runtime = runtime
    }

    func prepare() { runtime.prewarm(model, store: store) }
    func cancel() { work?.cancel(); work = nil }

    func translate(_ analysis: ScreenPipeline.Analysis, direction: TranslationDirection, app: String?,
                   progress: @escaping TranslationProgress) async throws -> TranslationOutput {
        runtime.begin()
        defer { runtime.end() }
        let endpoint = try await runtime.endpoint(for: model, store: store)
        try Task.checkCancellation()
        var output = TranslationOutput()
        var jobs: [(index: Int, source: AppLanguage)] = []
        for index in analysis.blocks.indices where analysis.blocks[index].translate {
            let original = analysis.blocks[index].original
            let source = TextLanguage.source(of: original, fallback: direction.source)
            if source == direction.target { output.kept.insert(index); continue }
            if [.zhHans, .zhHant].contains(source), [.zhHans, .zhHant].contains(direction.target) {
                output.translations[index] = TranslationText.normalize(original, locale: direction.target.speechLocale)
                continue
            }
            if let cached = cache.value(original, direction: TranslationDirection(source: source, target: direction.target).id) {
                output.translations[index] = cached
                continue
            }
            jobs.append((index, source))
        }
        let texts = analysis.blocks.map(\.original)
        let target = direction.target, prompt = model.prompt
        let early = output
        if !jobs.isEmpty { progress(early) }
        let task = Task { () throws -> TranslationOutput in
            var result = TranslationOutput()
            var failures = 0
            var lastError: Error?
            try await withThrowingTaskGroup(of: Answer.self) { group in
                var next = 0, inFlight = 0
                while next < jobs.count || inFlight > 0 {
                    while next < jobs.count, inFlight < 4 {
                        let index = jobs[next].index, source = jobs[next].source, text = texts[index]
                        next += 1; inFlight += 1
                        group.addTask {
                            do { return Answer(index: index, text: try await LocalChat.translate(text, source: source, target: target, prompt: prompt, endpoint: endpoint), error: nil) }
                            catch { return Answer(index: index, text: nil, error: error) }
                        }
                    }
                    guard let answer = try await group.next() else { break }
                    inFlight -= 1
                    try Task.checkCancellation()
                    if let text = answer.text {
                        result.translations[answer.index] = TranslationText.normalize(text, locale: target.speechLocale)
                        var sofar = early
                        sofar.translations.merge(result.translations) { _, new in new }
                        progress(sofar)
                    } else { failures += 1; lastError = answer.error }
                }
            }
            if failures > 0, result.translations.isEmpty, let lastError { throw lastError }
            if failures > 0 { result.warning = L("有 %ld 处未能翻译，已保留原文，可重新翻译。", failures) }
            return result
        }
        work = task
        let fresh: TranslationOutput
        do { fresh = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch is URLError where !Task.isCancelled { throw LocalModelError.startFailed }
        try Task.checkCancellation()
        for (index, text) in fresh.translations {
            let source = jobs.first { $0.index == index }?.source ?? direction.source
            cache.store(texts[index], translation: text, direction: TranslationDirection(source: source, target: target).id)
            output.translations[index] = text
        }
        output.warning = fresh.warning
        return output
    }
}
