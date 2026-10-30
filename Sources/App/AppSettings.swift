import Foundation

enum CaptureMode: String, CaseIterable, Identifiable {
    case translate, screenshot
    var id: String { rawValue }
    var title: String { switch self { case .translate: L("截屏翻译"); case .screenshot: L("截图标注") } }
}

enum TranslationService: String, CaseIterable, Identifiable {
    case apple, local, remote
    var id: String { rawValue }
}

@MainActor @Observable
final class AppSettings {
    let shortcuts: ShortcutStore
    var source: AppLanguage { didSet { defaults.set(source.rawValue, forKey: "source") } }
    var detectsSource: Bool { didSet { defaults.set(detectsSource, forKey: "detectsSource") } }
    var target: AppLanguage { didSet { defaults.set(target.rawValue, forKey: "target"); InterfaceLanguage.shared.language = target } }
    var copyCloses: Bool { didSet { defaults.set(copyCloses, forKey: "copyCloses") } }
    var service: TranslationService { didSet { defaults.set(service.rawValue, forKey: "translationService") } }
    var localModel: String { didSet { defaults.set(localModel, forKey: "localModel") } }
    var endpoint: String { didSet { defaults.set(endpoint, forKey: "endpoint") } }
    var model: String { didSet { defaults.set(model, forKey: "model") } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcuts = ShortcutStore(defaults: defaults)
        let native = AppLanguage(rawValue: defaults.string(forKey: "target") ?? "") ?? AppLanguage.preferred()
        source = AppLanguage(rawValue: defaults.string(forKey: "source") ?? "") ?? native.alternate
        detectsSource = defaults.object(forKey: "detectsSource") == nil ? true : defaults.bool(forKey: "detectsSource")
        target = native
        InterfaceLanguage.shared.language = native
        copyCloses = defaults.object(forKey: "copyCloses") == nil ? true : defaults.bool(forKey: "copyCloses")
        service = TranslationService(rawValue: defaults.string(forKey: "translationService") ?? "") ?? (defaults.bool(forKey: "useModel") ? .remote : .apple)
        localModel = LocalModelCatalog.model(id: defaults.string(forKey: "localModel") ?? "")?.id ?? LocalModelCatalog.defaultID
        endpoint = defaults.string(forKey: "endpoint") ?? "http://127.0.0.1:1234/v1/chat/completions"
        model = defaults.string(forKey: "model") ?? ""
    }
    var selectedLocalModel: LocalModel { LocalModelCatalog.model(id: localModel) ?? LocalModelCatalog.all[0] }
    func makeBackend() throws -> any TranslationBackend {
        switch service {
        case .remote: return ModelTranslationBackend(configuration: try ModelConfiguration(endpoint: endpoint, model: model))
        case .local:
            let backend = try LocalModelTranslationBackend(model: selectedLocalModel)
            backend.prepare()
            return backend
        case .apple: return AppleTranslationBackend()
        }
    }
}
