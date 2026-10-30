import AppKit
import Carbon

enum ShortcutAction: String, CaseIterable, Identifiable {
    case captureTranslate, captureScreenshot, globalCompare
    case lastArea
    case compare, translate, direction, rectangle, ellipse, arrow, pen, move, copy, save, undo, redo, close
    case annotate, pin, reselect
    case peek
    case openImage, settings, quit
    var id: String { rawValue }
    var group: String {
        switch self {
        case .captureTranslate, .captureScreenshot, .globalCompare: "全局"
        case .openImage, .settings, .quit: "应用"
        case .lastArea: "框选"
        default: "截图窗口"
        }
    }
    var title: String {
        switch self {
        case .captureTranslate: L("截图翻译")
        case .captureScreenshot: L("截图标注")
        case .globalCompare: L("全局对照原文")
        case .lastArea: L("选择上次的区域")
        case .compare: L("原文 / 译文")
        case .translate: L("翻译 / 重试")
        case .direction: L("交换语言")
        case .rectangle: L("矩形")
        case .ellipse: L("椭圆")
        case .arrow: L("箭头")
        case .pen: L("画笔")
        case .move: L("移动")
        case .copy: L("复制图片")
        case .save: L("保存图片")
        case .undo: L("撤销标注")
        case .redo: L("重做标注")
        case .close: L("关闭截图 / 取消框选")
        case .annotate: L("展开 / 收起标注")
        case .pin: L("钉到屏幕")
        case .reselect: L("重新框选")
        case .peek: L("按住对照原文")
        case .openImage: L("打开图片")
        case .settings: L("打开设置")
        case .quit: L("退出 Transeen")
        }
    }
    var command: String {
        switch self {
        case .compare, .globalCompare: "toggle"
        case .rectangle, .ellipse, .arrow, .pen, .move: "tool." + rawValue
        default: rawValue
        }
    }
    var defaultBinding: KeyBinding? {
        let command = ScreenModifier.command
        switch self {
        // F1; capturing for annotation and the global comparison have no key until the user gives them one.
        case .captureTranslate: return KeyBinding(122)
        case .lastArea: return KeyBinding(15)
        case .compare: return KeyBinding(48)
        case .translate: return KeyBinding(17)
        case .direction: return KeyBinding(2)
        case .rectangle: return KeyBinding(15)
        case .ellipse: return KeyBinding(31)
        case .arrow: return KeyBinding(0)
        case .pen: return KeyBinding(35)
        case .move: return KeyBinding(9)
        case .copy: return KeyBinding(8, command)
        case .save: return KeyBinding(1, command)
        case .undo: return KeyBinding(6, command)
        case .redo: return KeyBinding(6, command | ScreenModifier.shift)
        case .close: return KeyBinding(53)
        case .peek: return KeyBinding(49)
        case .openImage: return KeyBinding(31, command)
        case .settings: return KeyBinding(43, command)
        case .quit: return KeyBinding(12, command)
        default: return nil
        }
    }
    static var globals: [Self] { allCases.filter { $0.group == "全局" } }
    /// Where the shortcut works. Two shortcuts can share a key only where they never work at
    /// the same time: R picks the last area while selecting and the rectangle in a capture.
    var contexts: Set<String> {
        switch group {
        case "框选": ["框选"]
        case "截图窗口": self == .close ? ["截图窗口", "框选"] : ["截图窗口"]
        default: ["全局", "应用", "截图窗口", "框选"]
        }
    }
    func conflicts(with other: Self) -> Bool { self != other && !contexts.isDisjoint(with: other.contexts) }
}

struct KeyBinding: Codable, Equatable {
    let keyCode: UInt16
    let flags: UInt64
    init(_ keyCode: UInt16, _ flags: UInt64 = 0) {
        self.keyCode = keyCode
        self.flags = flags & ScreenModifier.relevant
    }
    init(_ event: NSEvent) { self.init(event.keyCode, UInt64(event.modifierFlags.rawValue)) }
    var display: String { ScreenCaptureShortcut(keyCode: keyCode, modifierFlags: flags).displayName }
    var carbonFlags: UInt32 {
        var value: UInt32 = 0
        for (mask, carbon) in [(ScreenModifier.command, cmdKey), (ScreenModifier.option, optionKey), (ScreenModifier.control, controlKey), (ScreenModifier.shift, shiftKey)] {
            if flags & mask != 0 { value |= UInt32(carbon) }
        }
        return value
    }
    var validGlobal: Bool {
        flags & (ScreenModifier.command | ScreenModifier.option | ScreenModifier.control) != 0 ||
        ScreenCaptureShortcut(keyCode: keyCode, modifierFlags: flags).isFunctionKey
    }
    var menuKey: String? {
        let special: [UInt16: String] = [36: "\r", 48: "\t", 49: " ", 51: "\u{8}", 53: "\u{1b}",
            43: ",", 47: ".", 44: "/", 41: ";", 39: "'", 33: "[", 30: "]", 42: "\\", 27: "-", 24: "=", 50: "`",
            123: "\u{f702}", 124: "\u{f703}", 125: "\u{f701}", 126: "\u{f700}", 117: "\u{f728}"]
        if let key = special[keyCode] { return key }
        let name = ScreenCaptureShortcut.keyName(keyCode)
        if name.count == 1 { return name.lowercased() }
        if name.hasPrefix("F"), let number = Int(name.dropFirst()), let scalar = UnicodeScalar(0xf703 + number) { return String(scalar) }
        return nil
    }
}

@MainActor @Observable
final class ShortcutStore {
    private(set) var bindings: [String: KeyBinding]
    var recording: ShortcutAction? { didSet { onRecordingChanged?(recording != nil) } }
    var message = ""
    var validateGlobals: (([String: KeyBinding]) -> String?)?
    var onRecordingChanged: ((Bool) -> Void)?
    var onChanged: (() -> Void)?
    private let defaults: UserDefaults
    private static let storageKey = "keyboardShortcuts.v2"
    static var factory: [String: KeyBinding] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.compactMap { action in action.defaultBinding.map { (action.rawValue, $0) } })
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode([String: KeyBinding].self, from: $0) }
        // Retired actions must not reserve shortcuts or survive future saves.
        bindings = (stored ?? Self.factory).filter { ShortcutAction(rawValue: $0.key) != nil }
    }
    func binding(_ action: ShortcutAction) -> KeyBinding? { bindings[action.rawValue] }
    func label(_ action: ShortcutAction) -> String { binding(action)?.display ?? L("未设置") }
    func help(_ text: String, _ action: ShortcutAction) -> String { binding(action).map { "\(text)（\($0.display)）" } ?? text }
    func action(for event: NSEvent, group: String) -> ShortcutAction? {
        guard recording == nil, !event.isARepeat else { return nil }
        let key = KeyBinding(event)
        return ShortcutAction.allCases.first { $0.group == group && binding($0) == key }
    }
    @discardableResult func set(_ key: KeyBinding?, for action: ShortcutAction) -> Bool {
        if let key {
            guard key.menuKey != nil else { message = L("这个按键暂不支持，请选择字母、数字、方向键或功能键。"); return false }
            if action.group != "截图窗口" && !key.validGlobal { message = L("全局和应用快捷键需要搭配 ⌘、⌥ 或 ⌃，也可以使用 F 功能键。"); return false }
            if let other = ShortcutAction.allCases.first(where: { $0.conflicts(with: action) && binding($0) == key }) {
                message = L("%@ 已用于「%@」，请先修改或清除该项。", key.display, other.title); return false
            }
        }
        var next = bindings
        next[action.rawValue] = key
        if let error = validateGlobals?(next) { message = error; return false }
        bindings = next
        persist()
        message = key == nil ? L("已清除「%@」快捷键", action.title) : L("已更新「%@」", action.title)
        return true
    }
    func restoreDefaults() {
        recording = nil
        if let error = validateGlobals?(Self.factory) { message = error; return }
        bindings = Self.factory
        persist()
        message = L("已恢复默认快捷键")
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: Self.storageKey) }
        onChanged?()
    }
}
