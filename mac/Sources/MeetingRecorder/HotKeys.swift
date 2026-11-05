import Carbon

/// System-wide shortcuts through Carbon, which needs no Accessibility permission.
enum HotKeys {
    nonisolated(unsafe) private static var actions: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false

    static let control = UInt32(controlKey)
    static let option = UInt32(optionKey)

    static func register(keyCode: Int, modifiers: UInt32, action: @escaping () -> Void) {
        installHandler()
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), modifiers, EventHotKeyID(signature: 0x4D52_4543, id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            let id = key.id
            DispatchQueue.main.async { HotKeys.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
