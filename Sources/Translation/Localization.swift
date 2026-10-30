import Foundation
import Observation

/// The interface language follows the native language chosen in settings and
/// switches live: SwiftUI bodies that call `L` observe `InterfaceLanguage.shared`.
final class InterfaceLanguage: Observable, @unchecked Sendable {
    static let shared = InterfaceLanguage()
    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var stored: AppLanguage
    private var bundles: [AppLanguage: Bundle] = [:]

    private init() {
        stored = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "target") ?? "") ?? AppLanguage.preferred()
    }

    var language: AppLanguage {
        get {
            registrar.access(self, keyPath: \.language)
            return lock.withLock { stored }
        }
        set {
            guard lock.withLock({ stored }) != newValue else { return }
            registrar.withMutation(of: self, keyPath: \.language) { lock.withLock { stored = newValue } }
            // System-drawn text (open panels, standard menus) picks this up on the next launch.
            UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
        }
    }

    var locale: Locale { Locale(identifier: language.rawValue) }

    func lookup(_ key: String) -> String {
        let language = language
        if let value = bundle(for: language)?.string(key) { return value }
        if language != .zhHans && language != .zhHant, let value = bundle(for: .en)?.string(key) { return value }
        return key
    }

    private func bundle(for language: AppLanguage) -> Bundle? {
        lock.withLock {
            if let bundle = bundles[language] { return bundle }
            let bundle = Bundle.main.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
            bundles[language] = bundle
            return bundle
        }
    }
}

private extension Bundle {
    func string(_ key: String) -> String? {
        let missing = "\u{1}"
        let value = localizedString(forKey: key, value: missing, table: nil)
        return value == missing ? nil : value
    }
}

/// Interface text in the chosen language. Keys are the Simplified Chinese source text;
/// format keys use `%@` / `%ld` and translations may reorder them with `%1$@`.
func L(_ key: String) -> String { InterfaceLanguage.shared.lookup(key) }

func L(_ key: String, _ arguments: any CVarArg...) -> String {
    String(format: InterfaceLanguage.shared.lookup(key), locale: InterfaceLanguage.shared.locale, arguments: arguments)
}
