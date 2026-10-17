import AppKit
import Carbon.HIToolbox

enum HotKeyAction: UInt32 {
    case captureArea = 1
    case repeatCapture
    case toggleRecording
    case scrollingCapture
}

struct HotKeyBinding {
    let action: HotKeyAction
    let title: String
    let keyCode: Int
    let character: String
    let modifiers: NSEvent.ModifierFlags

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
}

/// The single place to change shortcuts; menu items and registration both read it.
let hotKeyTable: [HotKeyBinding] = [
    HotKeyBinding(action: .captureArea, title: "Capture Area", keyCode: kVK_ANSI_2, character: "2", modifiers: [.command, .shift]),
    HotKeyBinding(action: .repeatCapture, title: "Repeat Last Capture", keyCode: kVK_ANSI_1, character: "1", modifiers: [.command, .shift]),
    HotKeyBinding(action: .scrollingCapture, title: "Scrolling Capture", keyCode: kVK_ANSI_8, character: "8", modifiers: [.command, .shift]),
    HotKeyBinding(action: .toggleRecording, title: "Record…", keyCode: kVK_ANSI_7, character: "7", modifiers: [.command, .shift]),
]

@MainActor
final class HotKeys {
    private static var handler: ((HotKeyAction) -> Void)?
    private var refs: [EventHotKeyRef] = []

    init(handler: @escaping (HotKeyAction) -> Void) {
        Self.handler = handler

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Task { @MainActor in
                if let action = HotKeyAction(rawValue: id.id) { HotKeys.handler?(action) }
            }
            return noErr
        }, 1, &spec, nil, nil)

        for b in hotKeyTable {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5347_5242), id: b.action.rawValue)
            let status = RegisterEventHotKey(UInt32(b.keyCode), b.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
            else { NSLog("Screengrab: failed to register hotkey for \(b.action) (\(status))") }
        }
    }
}
