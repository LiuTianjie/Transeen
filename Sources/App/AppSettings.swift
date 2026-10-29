import Foundation

enum CaptureMode: String, CaseIterable, Identifiable {
    case translate, screenshot
    var id: String { rawValue }
    var title: String { switch self { case .translate: "截屏翻译"; case .screenshot: "截图标注" } }
}

@MainActor @Observable
final class AppSettings {
    let shortcuts: ShortcutStore
    var source: AppLanguage { didSet { defaults.set(source.rawValue, forKey: "source") } }
    var detectsSource: Bool { didSet { defaults.set(detectsSource, forKey: "detectsSource") } }
    var target: AppLanguage { didSet { defaults.set(target.rawValue, forKey: "target") } }
    var copyCloses: Bool { didSet { defaults.set(copyCloses, forKey: "copyCloses") } }
    var useModel: Bool { didSet { defaults.set(useModel, forKey: "useModel") } }
    var endpoint: String { didSet { defaults.set(endpoint, forKey: "endpoint") } }
    var model: String { didSet { defaults.set(model, forKey: "model") } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcuts = ShortcutStore(defaults: defaults)
        source = AppLanguage(rawValue: defaults.string(forKey: "source") ?? "") ?? .en
        detectsSource = defaults.object(forKey: "detectsSource") == nil ? true : defaults.bool(forKey: "detectsSource")
        target = AppLanguage(rawValue: defaults.string(forKey: "target") ?? "") ?? .zhHans
        copyCloses = defaults.object(forKey: "copyCloses") == nil ? true : defaults.bool(forKey: "copyCloses")
        useModel = defaults.bool(forKey: "useModel")
        endpoint = defaults.string(forKey: "endpoint") ?? "http://127.0.0.1:1234/v1/chat/completions"
        model = defaults.string(forKey: "model") ?? ""
    }
    func makeBackend() throws -> any TranslationBackend {
        if useModel { return ModelTranslationBackend(configuration: try ModelConfiguration(endpoint: endpoint, model: model)) }
        return AppleTranslationBackend()
    }
}
