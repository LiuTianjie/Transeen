import AppKit

struct TranslationOutput {
    var translations: [Int: String] = [:]
    var kept: Set<Int> = []
    var warning: String? = nil
}

@MainActor
protocol TranslationBackend {
    func translate(_ analysis: ScreenPipeline.Analysis, direction: TranslationDirection, app: String?) async throws -> TranslationOutput
    func cancel()
}

@MainActor
final class AppleTranslationBackend: TranslationBackend {
    private let provider = TranslationProvider()
    private var prepared: TranslationDirection?
    private var cache = ScreenTranslationCache()

    func cancel() { provider.reset(); prepared = nil }

    func translate(_ analysis: ScreenPipeline.Analysis, direction: TranslationDirection, app: String?) async throws -> TranslationOutput {
        let indices = analysis.blocks.indices.filter { analysis.blocks[$0].translate }
        var output = TranslationOutput()
        let groups = Dictionary(grouping: indices) { index in
            TextLanguage.source(of: analysis.blocks[index].original, fallback: direction.source)
        }
        for source in AppLanguage.allCases {
            guard let members = groups[source] else { continue }
            try Task.checkCancellation()
            if source == direction.target {
                output.kept.formUnion(members)
                continue
            }
            if [.zhHans, .zhHant].contains(source), [.zhHans, .zhHant].contains(direction.target) {
                for index in members {
                    output.translations[index] = TranslationText.normalize(analysis.blocks[index].original, locale: direction.target.speechLocale)
                }
                continue
            }
            let pair = TranslationDirection(source: source, target: direction.target)
            if prepared != pair || !provider.isReady {
                provider.reset()
                try await provider.ready(source: source.translationLanguage, target: direction.target.translationLanguage)
                try Task.checkCancellation()
                prepared = pair
            }
            let texts = members.map { analysis.blocks[$0].original }
            let missing = cache.missing(texts, direction: pair.id)
            if !missing.isEmpty {
                let answers = try await provider.translateBatch(missing)
                try Task.checkCancellation()
                for (original, translated) in zip(missing, answers) { cache.store(original, translation: translated, direction: pair.id) }
            }
            for index in members {
                output.translations[index] = cache.value(analysis.blocks[index].original, direction: pair.id)
            }
        }
        return output
    }
}

@MainActor
final class ModelTranslationBackend: TranslationBackend {
    let configuration: ModelConfiguration
    init(configuration: ModelConfiguration) { self.configuration = configuration }
    func cancel() {}
    func translate(_ analysis: ScreenPipeline.Analysis, direction: TranslationDirection, app: String?) async throws -> TranslationOutput {
        let config = configuration
        let translator = ScreenPreciseTranslator(transport: { system, user in
            try await ModelHTTP.chat(configuration: config, apiKey: ModelKeychain.read(endpoint: config.endpoint), system: system, user: user, timeout: 30)
        })
        let outcome = await translator.translate(PreciseTranslation.requests(analysis.blocks, scale: analysis.scale, target: direction.target), source: direction.source, target: direction.target, app: app)
        try Task.checkCancellation()
        if let failure = outcome.failure, outcome.accepted.isEmpty {
            switch failure {
            case .timeout: throw ModelError.message("模型翻译超时，请重试或切换本机翻译。")
            case .unusable: throw ModelError.message("模型未返回可用的翻译。")
            case .endpoint(let reason): throw ModelError.message(reason)
            }
        }
        let wanted = Set(analysis.blocks.indices.filter { analysis.blocks[$0].translate })
        let missing = wanted.subtracting(outcome.accepted.translations.keys).subtracting(outcome.accepted.kept)
        return TranslationOutput(
            translations: outcome.accepted.translations.mapValues { TranslationText.normalize($0, locale: direction.target.speechLocale) },
            kept: outcome.accepted.kept,
            warning: missing.isEmpty ? nil : "有 \(missing.count) 处未能翻译，已保留原文，可重新翻译。")
    }
}

enum TranslationText {
    static func normalize(_ text: String, locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier
        guard language == "zh" || language == "ja" else { return text }
        // Full-width punctuation carries its own spacing; Apple Translation still puts a
        // space between sentences ("数据。 如果").
        let spaced = text.replacingOccurrences(of: #"([。！？；：，、」』）])[ \t]+(?=\S)"#, with: "$1", options: .regularExpression)
        guard language == "zh" else { return spaced }
        let transform: StringTransform = locale.language.script?.identifier == "Hant" ? StringTransform("Simplified-Traditional") : StringTransform("Traditional-Simplified")
        return spaced.applyingTransform(transform, reverse: false) ?? spaced
    }
}
