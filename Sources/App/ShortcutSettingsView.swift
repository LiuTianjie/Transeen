import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @Bindable var shortcuts: ShortcutStore
    var body: some View {
        Form {
            Section {
                Text("点击右侧按键，再直接按下新的组合键。更改立即生效；× 可停用该项。").font(.callout).foregroundStyle(.secondary)
                if !shortcuts.message.isEmpty { Text(shortcuts.message).font(.callout).accessibilityIdentifier("shortcutFeedback") }
                if shortcuts.recording != nil { Button("取消录制") { shortcuts.recording = nil } }
            }
            ForEach(["全局", "截图窗口", "应用"], id: \.self) { group in
                Section(group) {
                    ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                        HStack {
                            Text(action.title)
                            Spacer()
                            ShortcutRecorder(shortcuts: shortcuts, action: action).frame(width: 136, height: 28)
                            Button { shortcuts.recording = nil; shortcuts.set(nil, for: action) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }.buttonStyle(.plain).help("清除\(action.title)快捷键")
                                .accessibilityLabel("清除\(action.title)快捷键")
                        }
                    }
                }
            }
            Section { Button("恢复全部默认快捷键") { shortcuts.restoreDefaults() } }
        }.formStyle(.grouped)
            .onDisappear { shortcuts.recording = nil }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Bindable var shortcuts: ShortcutStore
    let action: ShortcutAction
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(RecorderButton.beginRecording)
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.shortcuts = shortcuts
        button.shortcutAction = action
        button.title = shortcuts.recording == action ? "请按快捷键…" : shortcuts.label(action)
        button.setAccessibilityLabel("\(action.title)：\(button.title)")
        button.syncRecording()
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.stopMonitor() }
}

private final class RecorderButton: NSButton {
    var shortcuts: ShortcutStore?
    var shortcutAction: ShortcutAction?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    @objc func beginRecording() {
        guard let shortcuts, let shortcutAction else { return }
        shortcuts.message = "录制时 Esc 也可设为快捷键；如需退出，请点击「取消录制」。"
        shortcuts.recording = shortcutAction
        window?.makeFirstResponder(self)
        syncRecording()
    }
    func syncRecording() {
        guard let shortcuts, shortcuts.recording == shortcutAction else { stopMonitor(); return }
        guard monitor == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shortcuts?.recording == self.shortcutAction else { return }
                self.shortcuts?.recording = nil
                self.stopMonitor()
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let shortcuts = self.shortcuts, let action = self.shortcutAction,
                  shortcuts.recording == action, event.window === self.window else { return event }
            guard !event.isARepeat else { return nil }
            // Re-register globals during validation, then resume normal dispatch.
            if shortcuts.set(KeyBinding(event), for: action) { shortcuts.recording = nil }
            return nil
        }
    }
    func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
    }
}

extension View {
    @ViewBuilder func configuredShortcut(_ action: ShortcutAction, in store: ShortcutStore) -> some View {
        if store.recording == nil, let binding = store.binding(action), let key = binding.menuKey?.first {
            let modifiers: EventModifiers = [
                binding.flags & ScreenModifier.command != 0 ? .command : [],
                binding.flags & ScreenModifier.option != 0 ? .option : [],
                binding.flags & ScreenModifier.control != 0 ? .control : [],
                binding.flags & ScreenModifier.shift != 0 ? .shift : []
            ]
            self.keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
        } else { self }
    }
}
