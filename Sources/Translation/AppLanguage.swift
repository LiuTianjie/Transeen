import Foundation
import NaturalLanguage

enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case fr = "fr"
    case es = "es"
    case de = "de"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .es: return "Español"
        case .de: return "Deutsch"
        }
    }

    var shortName: String {
        switch self {
        case .zhHans: return "中文"
        case .zhHant: return "繁中"
        case .en: return "EN"
        case .ja: return "JA"
        case .ko: return "KO"
        case .fr: return "FR"
        case .es: return "ES"
        case .de: return "DE"
        }
    }

    var speechLocale: Locale {
        Locale(identifier: speechIdentifier)
    }

    var speechIdentifier: String {
        switch self {
        case .zhHans: return "zh-CN"
        case .zhHant: return "zh-TW"
        case .en: return "en-US"
        case .ja: return "ja-JP"
        case .ko: return "ko-KR"
        case .fr: return "fr-FR"
        case .es: return "es-ES"
        case .de: return "de-DE"
        }
    }

    var translationLanguage: Locale.Language {
        Locale(identifier: rawValue).language
    }
}

/// Script checks prevent short Japanese and Korean labels being mistaken for
/// Chinese. Language recognition handles prose in languages sharing a script.
enum TextLanguage {
    static func identify(_ text: String) -> AppLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(12_000)))
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
              best.value >= 0.65 else { return nil }
        return AppLanguage(rawValue: best.key.rawValue)
    }

    static func source(in texts: [String], target: AppLanguage, fallback: AppLanguage) -> AppLanguage {
        let whole = texts.joined(separator: "\n")
        let dominant = identify(whole) ?? fallback
        let remaining = texts.filter { !isTarget($0, source: dominant, target: target) }
        guard !remaining.isEmpty else { return target }
        return identify(remaining.joined(separator: "\n")) ?? (dominant == target ? fallback : dominant)
    }

    static func source(of text: String, fallback: AppLanguage) -> AppLanguage {
        if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return .ja }
        if text.unicodeScalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }) { return .ko }
        let hasHan = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        // A short kanji-only label inherits its page's language. Otherwise a
        // Japanese button such as 設定 can be misidentified as Chinese again.
        if hasHan, [.zhHans, .zhHant, .ja, .ko].contains(fallback) { return fallback }
        if hasHan || text.split(separator: " ").count >= 5 { return identify(text) ?? fallback }
        return fallback
    }

    static func isTarget(_ text: String, source: AppLanguage, target: AppLanguage) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let kana = letters.contains { (0x3040...0x30FF).contains($0.value) }
        let hangul = letters.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }
        let han = letters.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }.count
        switch target {
        case .zhHans, .zhHant:
            guard !kana, !hangul, han > 0, han * 2 >= letters.count,
                  source != .ja, source != .ko else { return false }
            let transform = StringTransform(target == .zhHans ? "Traditional-Simplified" : "Simplified-Traditional")
            return text.applyingTransform(transform, reverse: false) == text
        case .ja: return kana && !hangul
        case .ko: return hangul && !kana
        default:
            guard han == 0, !kana, !hangul else { return false }
            return identify(text) == target
        }
    }
}

struct TranslationDirection: Equatable, Hashable, Identifiable {
    let source: AppLanguage
    let target: AppLanguage
    var id: String { source.rawValue + ">" + target.rawValue }
    var reversed: Self { Self(source: target, target: source) }

    var title: String {
        if source == target { return "\(source.displayName)原文" }
        return "\(source.shortName) → \(target.shortName)"
    }

    var compactTitle: String {
        if source == target { return "\(source.shortName) 原文" }
        return "\(source.shortName) → \(target.shortName)"
    }

    /// Four directions from the two languages chosen in settings:
    /// A→A, A→B, B→A, B→B.
    static func voiceModes(a: AppLanguage, b: AppLanguage) -> [TranslationDirection] {
        let raw = [
            TranslationDirection(source: a, target: a),
            TranslationDirection(source: a, target: b),
            TranslationDirection(source: b, target: a),
            TranslationDirection(source: b, target: b)
        ]
        var seen = Set<String>()
        return raw.filter { seen.insert($0.id).inserted }
    }

    static func cycled(current: TranslationDirection, a: AppLanguage, b: AppLanguage) -> TranslationDirection {
        let modes = voiceModes(a: a, b: b)
        if let index = modes.firstIndex(of: current) {
            return modes[(index + 1) % modes.count]
        }
        return modes[min(1, modes.count - 1)]
    }
}
