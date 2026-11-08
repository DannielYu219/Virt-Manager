import AppKit
import Carbon

/// A host-owned recovery path. Registration must succeed before immersive mode begins.
@MainActor
final class ImmersiveExitHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    func register(action: @escaping () -> Void) throws {
        unregister()
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x564D4458, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated {
                Unmanaged<ImmersiveExitHotKey>.fromOpaque(context).takeUnretainedValue().action?()
            }
            return noErr
        }
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                                                Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installStatus == noErr else {
            unregister()
            throw registrationError(installStatus)
        }
        let registerStatus = RegisterEventHotKey(UInt32(kVK_ANSI_Q), UInt32(cmdKey | optionKey | shiftKey),
                                                EventHotKeyID(signature: 0x564D4458, id: 1),
                                                GetApplicationEventTarget(), 0, &hotKey)
        guard registerStatus == noErr else {
            unregister()
            throw registrationError(registerStatus)
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        action = nil
    }

    private func registrationError(_ status: OSStatus) -> NSError {
        NSError(domain: "VirtManager.ImmersiveExit", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "无法注册恢复快捷键 ⌘⌥⇧Q（可能已被占用）。请释放快捷键后再进入沉浸模式。"
        ])
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
