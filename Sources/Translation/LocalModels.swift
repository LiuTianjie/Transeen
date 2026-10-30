import CryptoKit
import Foundation

/// A translation model the user can download and run on this Mac with the bundled llama-server.
struct LocalModel: Identifiable, Sendable, Equatable {
    enum Prompt: Sendable { case index, hunyuan }
    let id: String
    let name: String
    let summaryKey: String
    var summary: String { L(summaryKey) }
    let file: String
    let bytes: Int64
    let sha256: String
    let modelScope: URL
    let huggingFace: URL
    let prompt: Prompt

    /// ModelScope first in mainland China, where Hugging Face is often unreachable.
    func sources(region: String? = Locale.current.region?.identifier) -> [URL] {
        region == "CN" ? [modelScope, huggingFace] : [huggingFace, modelScope]
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

enum LocalModelCatalog {
    static let defaultID = "index-translate-2b"
    static let all: [LocalModel] = [
        LocalModel(id: "index-translate-2b", name: "Index-Translate 2B",
                   summaryKey: "哔哩哔哩开源，150 种语言，代码和术语保留得好",
                   file: "Index-Translate-2B.Q3_K_M.gguf", bytes: 1_127_802_368,
                   sha256: "230306b90b65af599dd86a003b170824f694952ae1e8e7addacdababfc750de5",
                   modelScope: URL(string: "https://modelscope.cn/models/IndexTeam/Index-Translate-2B-GGUF/resolve/master/Index-Translate-2B.Q3_K_M.gguf")!,
                   huggingFace: URL(string: "https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF/resolve/main/Index-Translate-2B.Q3_K_M.gguf")!,
                   prompt: .index),
        LocalModel(id: "hy-mt2-1.8b", name: "Hy-MT2 1.8B",
                   summaryKey: "腾讯混元开源，33 种语言，速度最快",
                   file: "Hy-MT2-1.8B-Q4_K_M.gguf", bytes: 1_133_080_448,
                   sha256: "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699",
                   modelScope: URL(string: "https://modelscope.cn/models/Tencent-Hunyuan/Hy-MT2-1.8B-GGUF/resolve/master/Hy-MT2-1.8B-Q4_K_M.gguf")!,
                   huggingFace: URL(string: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/main/Hy-MT2-1.8B-Q4_K_M.gguf")!,
                   prompt: .hunyuan)
    ]
    static func model(id: String) -> LocalModel? { all.first { $0.id == id } }
}

enum LocalModelError: LocalizedError {
    case unsupportedMac, missingHelper, notDownloaded(String), diskSpace(String), corrupted, unexpectedSize, http(Int), startFailed, noTranslation
    var errorDescription: String? {
        switch self {
        case .unsupportedMac: return L("本地翻译模型需要 Apple 芯片的 Mac。")
        case .missingHelper: return L("这个版本没有附带本地模型运行组件，请重新安装 Transeen。")
        case .notDownloaded(let name): return L("本地模型 %@ 还没下载。可在设置 → 通用 → 翻译中下载。", name)
        case .diskSpace(let size): return L("磁盘空间不足，下载需要约 %@。", size)
        case .corrupted: return L("下载的模型文件校验失败，已删除，请重新下载。")
        case .unexpectedSize: return L("下载的模型文件大小不对，请重新下载。")
        case .http(let code): return L("下载服务器返回 HTTP %ld。", code)
        case .startFailed: return L("本地翻译模型没能启动，请重试；仍不行可在设置中删除后重新下载。")
        case .noTranslation: return L("本地模型没有返回可用的翻译，请重试。")
        }
    }
}

/// Downloaded models in Application Support, with resumable, checksum-verified downloads.
@MainActor @Observable
final class LocalModelStore {
    enum Status: Equatable {
        case missing, installed
        case downloading(Double)
        case failed(String)
    }
    static let shared = LocalModelStore()
    let directory: URL
    private(set) var statuses: [String: Status] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Transeen/Models", directoryHint: .isDirectory)) {
        self.directory = directory
        for model in LocalModelCatalog.all { statuses[model.id] = isInstalled(model) ? .installed : .missing }
    }

    func url(for model: LocalModel) -> URL { directory.appending(path: model.file) }
    private func partialURL(for model: LocalModel) -> URL { directory.appending(path: model.file + ".partial") }

    /// The checksum is verified when the download finishes; the size guards against a file changed since.
    func isInstalled(_ model: LocalModel) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url(for: model).path)[.size] as? NSNumber)?.int64Value
        return size == model.bytes
    }

    func status(_ model: LocalModel) -> Status { statuses[model.id] ?? .missing }

    func download(_ model: LocalModel) {
        guard tasks[model.id] == nil, !isInstalled(model) else { return }
        statuses[model.id] = .downloading(fraction(of: partialURL(for: model), model: model))
        tasks[model.id] = Task { [weak self] in await self?.perform(model) }
    }

    /// Keeps the partial file, so the next download continues where this one stopped.
    func cancel(_ model: LocalModel) {
        tasks[model.id]?.cancel()
    }

    func delete(_ model: LocalModel) {
        tasks[model.id]?.cancel()
        try? FileManager.default.removeItem(at: url(for: model))
        try? FileManager.default.removeItem(at: partialURL(for: model))
        statuses[model.id] = .missing
    }

    private func fraction(of partial: URL, model: LocalModel) -> Double {
        let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
        return min(1, Double(size) / Double(model.bytes))
    }

    private func perform(_ model: LocalModel) async {
        let partial = partialURL(for: model)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let have = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
            let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
            guard free > model.bytes - have + 200_000_000 else { throw LocalModelError.diskSpace(model.sizeText) }
            var digest: String?
            var lastError: Error = LocalModelError.unexpectedSize
            for source in model.sources() {
                do {
                    digest = try await ModelDownload.run(from: source, to: partial, expected: model.bytes) { [weak self] value in
                        Task { @MainActor in
                            guard let self, case .downloading = self.statuses[model.id] else { return }
                            self.statuses[model.id] = .downloading(value)
                        }
                    }
                    break
                } catch {
                    try Task.checkCancellation()
                    lastError = error
                }
            }
            guard let digest else { throw lastError }
            guard digest == model.sha256 else {
                try? FileManager.default.removeItem(at: partial)
                throw LocalModelError.corrupted
            }
            try? FileManager.default.removeItem(at: url(for: model))
            try FileManager.default.moveItem(at: partial, to: url(for: model))
            statuses[model.id] = .installed
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                statuses[model.id] = .missing
            } else if let error = error as? LocalModelError {
                statuses[model.id] = .failed(error.localizedDescription)
            } else {
                statuses[model.id] = .failed(L("下载中断：%@", error.localizedDescription))
            }
        }
        tasks[model.id] = nil
    }
}

/// One HTTP download into `partial`, continuing an earlier one with a Range request.
/// Hashes while writing, so the finished file is verified without reading it again.
private final class ModelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partial: URL
    private let expected: Int64
    private let report: @Sendable (Double) -> Void
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var resumed: Int64 = 0
    private var reported = Date.distantPast
    private var failure: Error?
    private var continuation: CheckedContinuation<String, Error>?

    private init(partial: URL, expected: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.partial = partial; self.expected = expected; self.report = report
    }

    static func run(from source: URL, to partial: URL, expected: Int64, report: @escaping @Sendable (Double) -> Void) async throws -> String {
        let download = ModelDownload(partial: partial, expected: expected, report: report)
        try await download.prepare()
        var request = URLRequest(url: source, timeoutInterval: 60)
        if download.resumed > 0 { request.setValue("bytes=\(download.resumed)-", forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: download.queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.queue.addOperation {
                    download.continuation = continuation
                    task.resume()
                }
            }
        } onCancel: { task.cancel() }
    }

    /// Hashes what an earlier attempt already wrote, off the main thread.
    private func prepare() async throws {
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let file = try FileHandle(forUpdating: partial)
        let size = try file.seekToEnd()
        if size >= UInt64(expected) {
            try file.truncate(atOffset: 0)
        } else if size > 0 {
            try file.seek(toOffset: 0)
            while let chunk = try file.read(upToCount: 8 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            resumed = Int64(size)
        }
        handle = file
        received = resumed
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { failure = LocalModelError.http(0); completionHandler(.cancel); return }
        do {
            switch http.statusCode {
            case 206 where resumed > 0:
                let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard range.hasPrefix("bytes \(resumed)-") else { fallthrough }
            case 200:
                if http.statusCode == 200 || received != resumed {
                    try handle?.truncate(atOffset: 0)
                    hasher = SHA256(); received = 0
                }
            default:
                throw LocalModelError.http(http.statusCode)
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            guard received + Int64(data.count) <= expected else { throw LocalModelError.unexpectedSize }
            try handle?.write(contentsOf: data)
            hasher.update(data: data)
            received += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(reported) > 0.2 {
                reported = now
                report(Double(received) / Double(expected))
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let continuation = self.continuation
        self.continuation = nil
        if let failure = failure ?? error {
            continuation?.resume(throwing: failure)
        } else if received != expected {
            continuation?.resume(throwing: LocalModelError.unexpectedSize)
        } else {
            continuation?.resume(returning: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
}
