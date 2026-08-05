import Foundation
#if os(macOS)
import AppKit
import Carbon.HIToolbox

struct CaptureShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    static let defaultValue = Self(
        keyCode: UInt32(kVK_ANSI_G),
        modifiers: UInt32(cmdKey),
        label: "⌘G"
    )
    private static let key = "BrieflyCaptureShortcut"

    static func load() -> Self {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let value = try? JSONDecoder().decode(Self.self, from: data)
        else {
            return defaultValue
        }
        return value
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard
            flags.contains(.command) ||
                flags.contains(.control) ||
                flags.contains(.option)
        else {
            return nil
        }
        var carbonModifiers: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
            symbols += "⌃"
        }
        if flags.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
            symbols += "⌥"
        }
        if flags.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
            symbols += "⇧"
        }
        if flags.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
            symbols += "⌘"
        }
        let names: [UInt16: String] = [
            UInt16(kVK_Space): "Space",
            UInt16(kVK_Tab): "Tab",
            UInt16(kVK_Delete): "⌫",
            UInt16(kVK_ForwardDelete): "⌦",
            UInt16(kVK_Return): "↩",
            UInt16(kVK_Escape): "Esc",
            UInt16(kVK_LeftArrow): "←",
            UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑",
            UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_Home): "Home",
            UInt16(kVK_End): "End",
            UInt16(kVK_PageUp): "Page Up",
            UInt16(kVK_PageDown): "Page Down",
            UInt16(kVK_F1): "F1",
            UInt16(kVK_F2): "F2",
            UInt16(kVK_F3): "F3",
            UInt16(kVK_F4): "F4",
            UInt16(kVK_F5): "F5",
            UInt16(kVK_F6): "F6",
            UInt16(kVK_F7): "F7",
            UInt16(kVK_F8): "F8",
            UInt16(kVK_F9): "F9",
            UInt16(kVK_F10): "F10",
            UInt16(kVK_F11): "F11",
            UInt16(kVK_F12): "F12",
            UInt16(kVK_F13): "F13",
            UInt16(kVK_F14): "F14",
            UInt16(kVK_F15): "F15",
            UInt16(kVK_F16): "F16",
            UInt16(kVK_F17): "F17",
            UInt16(kVK_F18): "F18",
            UInt16(kVK_F19): "F19",
            UInt16(kVK_F20): "F20"
        ]
        let keyName = names[event.keyCode] ??
            event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
        guard let keyName, !keyName.isEmpty, keyName.count <= 8 else { return nil }
        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers,
            label: symbols + keyName
        )
    }
}

#endif
