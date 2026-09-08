import AppKit
import Carbon.HIToolbox

/// A single global hotkey registered via Carbon (needs no special permission).
/// The C event handler can't capture context, so live instances are looked up
/// through a static registry keyed by hotkey id.
@MainActor
final class HotKey {
    private let id: UInt32
    private var ref: EventHotKeyRef?
    private let handler: () -> Void

    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    private static let signature: OSType = 0x534E_4F53   // 'SNOS'

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        self.id = HotKey.nextID
        HotKey.nextID += 1

        HotKey.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: HotKey.signature, id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        self.ref = ref
        HotKey.registry[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        // deinit is nonisolated; hop to the main actor to touch the registry.
        let id = id
        Task { @MainActor in HotKey.registry[id] = nil }
    }

    fileprivate func fire() { handler() }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.registry[id]?.fire() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
