import Foundation
#if os(macOS)
import AppKit
import Carbon.HIToolbox

final class BrieflyAppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var event = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .brieflyCaptureClipboard,
                        object: nil
                    )
                }
                return noErr
            },
            1,
            &event,
            nil,
            &eventHandler
        )
        register(CaptureShortcut.load())
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutChanged),
            name: .brieflyCaptureShortcutChanged,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func shortcutChanged() {
        register(CaptureShortcut.load())
    }

    private func register(_ shortcut: CaptureShortcut) {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: 0x4252_464C, id: 1),
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        UserDefaults.standard.set(
            status == noErr,
            forKey: "BrieflyCaptureShortcutRegistered"
        )
        NotificationCenter.default.post(
            name: .brieflyCaptureShortcutRegistrationChanged,
            object: status == noErr
        )
    }
}

#endif
