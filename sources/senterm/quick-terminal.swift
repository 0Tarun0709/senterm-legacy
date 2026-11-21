import AppKit
import Carbon

@MainActor
final class QuickTerminal {
    private var handler: EventHandlerRef?
    private var key: EventHotKeyRef?
    var show: (() -> Void)?

    func setEnabled(_ enabled: Bool) {
        if let key { UnregisterEventHotKey(key); self.key = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        guard enabled else { return }

        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let target = GetApplicationEventTarget()
        guard InstallEventHandler(target, { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x53656e54, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let terminal = Unmanaged<QuickTerminal>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { terminal.show?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return }

        let result = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: 0x53656e54, id: 1), target, 0, &key)
        if result != noErr {
            setEnabled(false)
            let alert = NSAlert()
            alert.messageText = "quick terminal shortcut unavailable"
            alert.informativeText = "another app may already use control-option-t."
            alert.runModal()
        }
    }
}
