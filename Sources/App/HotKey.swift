import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut (⌥Space by default). Carbon hot keys need no Accessibility permission.
@MainActor
final class HotKey {
    nonisolated(unsafe) private static var action: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey), action: @escaping @MainActor () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        register(keyCode: keyCode, modifiers: modifiers)
    }

    /// Swaps the shortcut for another.
    func register(keyCode: UInt32, modifiers: UInt32) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        let id = EventHotKeyID(signature: OSType(0x574D_414E), id: 1)   // "WMAN"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
