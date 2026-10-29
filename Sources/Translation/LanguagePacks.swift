import Foundation
@preconcurrency import Translation

/// The Apple language packs a capture into `target` will need, checked and
/// downloaded ahead of the first capture. The view showing them hosts
/// `.translationTask`; that session only downloads and never translates.
@MainActor @Observable
final class LanguagePacks {
    enum Status: Equatable {
        case checking, installed, missing, unsupported, downloading
    }
    private(set) var target: AppLanguage = .zhHans
    private(set) var sources: [AppLanguage] = []
    private(set) var statuses: [AppLanguage: Status] = [:]
    private(set) var message: String?
    private(set) var configuration: TranslationSession.Configuration?
    private var downloading: (source: AppLanguage, target: AppLanguage)?
    private var generation = 0

    var installedCount: Int { sources.filter { statuses[$0] == .installed }.count }
    var isDownloading: Bool { downloading != nil }

    /// With automatic detection every other language may appear on screen. Chinese
    /// variants convert between each other without a pack.
    static func sources(for target: AppLanguage, source: AppLanguage?) -> [AppLanguage] {
        let chinese: [AppLanguage] = [.zhHans, .zhHant]
        return (source.map { [$0] } ?? AppLanguage.allCases).filter {
            $0 != target && !(chinese.contains($0) && chinese.contains(target))
        }
    }

    func refresh(source: AppLanguage?, target: AppLanguage) async {
        generation += 1
        let token = generation
        if target != self.target { statuses = [:] }
        self.target = target
        sources = Self.sources(for: target, source: source)
        for language in sources where statuses[language] == nil { statuses[language] = .checking }
        for language in sources {
            let (status, _) = await TranslationEngine.availability(source: language.translationLanguage, target: target.translationLanguage)
            guard token == generation else { return }
            if downloading?.source == language, downloading?.target == target { continue }
            statuses[language] = Self.status(status)
        }
    }

    func download(_ source: AppLanguage) {
        guard downloading == nil, statuses[source] == .missing else { return }
        downloading = (source, target)
        statuses[source] = .downloading
        message = nil
        let next: TranslationSession.Configuration
        if #available(macOS 26.4, *) {
            next = TranslationSession.Configuration(source: source.translationLanguage, target: target.translationLanguage, preferredStrategy: .lowLatency)
        } else {
            next = TranslationSession.Configuration(source: source.translationLanguage, target: target.translationLanguage)
        }
        // The same pair again (after a declined prompt) needs a new version to run the task.
        if configuration == next { configuration?.invalidate() } else { configuration = next }
    }

    func handle(_ session: TranslationSession) async {
        guard let pair = downloading else { return }
        var failure: String?
        do { try await session.prepareTranslation() } catch { failure = error.localizedDescription }
        let (status, _) = await TranslationEngine.availability(source: pair.source.translationLanguage, target: pair.target.translationLanguage)
        downloading = nil
        guard pair.target == target else { return }
        statuses[pair.source] = Self.status(status)
        if status != .installed {
            message = "\(pair.source.displayName) 语言包没有下载完成" + (failure.map { "：\($0)" } ?? "。")
        }
    }

    private static func status(_ status: LanguageAvailability.Status) -> Status {
        switch status {
        case .installed: .installed
        case .supported: .missing
        default: .unsupported
        }
    }
}
