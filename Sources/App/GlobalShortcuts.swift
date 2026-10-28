import AppKit
import Carbon

/// Carbon hotkeys do not require Accessibility or Input Monitoring permissions.
@MainActor
final class GlobalShortcuts {
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    var onPressed: ((ShortcutAction) -> Void)?
    func register(_ bindings: [String: KeyBinding]) -> [ShortcutAction] {
        stop()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            guard id.signature == 0x54524E53 else { return OSStatus(eventNotHandledErr) }
            let hotkeys = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                let index = Int(id.id) - 1
                if ShortcutAction.globals.indices.contains(index) { hotkeys.onPressed?(ShortcutAction.globals[index]) }
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return ShortcutAction.globals.filter { bindings[$0.rawValue] != nil } }
        var failed: [ShortcutAction] = []
        for (index, action) in ShortcutAction.globals.enumerated() {
            guard let binding = bindings[action.rawValue] else { continue }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(binding.keyCode), binding.carbonFlags, EventHotKeyID(signature: 0x54524E53, id: UInt32(index + 1)), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { refs.append(ref) } else { failed.append(action) }
        }
        return failed
    }
    func stop() {
        refs.forEach { UnregisterEventHotKey($0) }; refs = []
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
