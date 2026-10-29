import Foundation
@preconcurrency import Translation

enum TranslationEngineError: LocalizedError {
    case notReady
    case unsupported
    case incomplete

    var errorDescription: String? {
        switch self {
        case .notReady: return String(localized: "翻译语言包还没下载。可在设置 → 通用 → 翻译中提前下载。")
        case .unsupported: return String(localized: "系统不支持这对语言。")
        case .incomplete: return String(localized: "系统翻译没有返回完整结果，请重试。")
        }
    }
}

@MainActor
@Observable
final class TranslationEngine {
    private(set) var isReady = false
    private(set) var needsDownload = false
    private(set) var isPassthrough = false
    private var languages: (source: Locale.Language, target: Locale.Language)?
    private var activeSession: TranslationSession?
    private var usesHighFidelity = false
    private var generation = 0
    private var outputLocale: Locale?

    func reset() {
        generation += 1
        activeSession?.cancel()
        activeSession = nil
        languages = nil
        usesHighFidelity = false
        isReady = false
        needsDownload = false
        isPassthrough = false
        outputLocale = nil
    }

    func enablePassthrough() {
        reset()
        isPassthrough = true
        isReady = true
        needsDownload = false
    }

    /// SDK 26.4 changed the default strategy. Check each strategy's own assets:
    /// ordinary language packs must not wait for unavailable AI models, and a
    /// ready high-fidelity model should be used when present.
    static func availability(source: Locale.Language, target: Locale.Language) async -> (status: LanguageAvailability.Status, highFidelity: Bool) {
        if #available(macOS 26.4, *) {
            let high = await LanguageAvailability(preferredStrategy: .highFidelity).status(from: source, to: target)
            if high == .installed { return (high, true) }
            return (await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target), false)
        }
        return (await LanguageAvailability().status(from: source, to: target), false)
    }

    func prepareInstalled(source: Locale.Language, target: Locale.Language) async throws {
        let token = generation
        outputLocale = Locale(identifier: target.maximalIdentifier)
        let (status, highFidelity) = await Self.availability(source: source, target: target)
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        usesHighFidelity = highFidelity
        switch status {
        case .installed:
            languages = (source, target)
            isReady = true
            needsDownload = false
        case .supported:
            isReady = false
            needsDownload = true
        case .unsupported:
            throw TranslationEngineError.unsupported
        @unknown default:
            throw TranslationEngineError.unsupported
        }
    }

    /// Preserve IDs because batch responses need not arrive in request order.
    func translateBatch(_ texts: [String]) async throws -> [String] {
        try Task.checkCancellation()
        if texts.isEmpty || isPassthrough { return texts }
        guard isReady, let languages else { throw TranslationEngineError.notReady }
        let token = generation
        let locale = outputLocale
        // A view-owned session must never escape .translationTask. Each workload
        // gets an independent session for installed languages, with no download
        // preparation (and no cancelled session reused by the next workload).
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: languages.source, target: languages.target,
                                         preferredStrategy: usesHighFidelity ? .highFidelity : .lowLatency)
        } else {
            session = TranslationSession(installedSource: languages.source, target: languages.target)
        }
        activeSession = session
        defer {
            session.cancel()
            if activeSession === session { activeSession = nil }
        }
        var results = Array<String?>(repeating: nil, count: texts.count)
        let indices = texts.indices.filter {
            if texts[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results[$0] = texts[$0]
                return false
            }
            return true
        }
        for start in stride(from: 0, to: indices.count, by: 32) {
            try Task.checkCancellation()
            let chunk = indices[start..<min(start + 32, indices.count)]
            nonisolated(unsafe) let requests = chunk.map {
                TranslationSession.Request(sourceText: texts[$0], clientIdentifier: String($0))
            }
            let responses = try await session.translations(from: requests)
            guard token == generation, !Task.isCancelled else { throw CancellationError() }
            for response in responses {
                guard let id = response.clientIdentifier, let index = Int(id), chunk.contains(index),
                      !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                results[index] = locale.map { TranslationText.normalize(response.targetText, locale: $0) } ?? response.targetText
            }
        }
        guard results.allSatisfy({ $0 != nil }) else { throw TranslationEngineError.incomplete }
        return results.compactMap { $0 }
    }

    func translate(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return try await translateBatch([trimmed])[0]
    }
}
