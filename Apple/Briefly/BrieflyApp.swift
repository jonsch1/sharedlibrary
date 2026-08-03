import SwiftUI
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#endif

@main
struct BrieflyApp: App {
    @State private var model = LibraryModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(BrieflyAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("Briefly", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Capture Clipboard") {
                    NotificationCenter.default.post(
                        name: .brieflyCaptureClipboard,
                        object: nil
                    )
                }
                .keyboardShortcut("g", modifiers: .command)
                Button("Import PDF…") {
                    NotificationCenter.default.post(
                        name: .brieflyImportPDF,
                        object: nil
                    )
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Refresh Library") {
                    NotificationCenter.default.post(
                        name: .brieflyRefreshLibrary,
                        object: nil
                    )
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            BrieflyMenuBar(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.menuBarIcon)
                if let activity = model.menuBarActivity {
                    Text(activity)
                }
            }
            .accessibilityLabel(
                model.menuBarActivity.map { "Briefly, \($0)" } ?? "Briefly"
            )
        }
        .menuBarExtraStyle(.menu)
        #else
        WindowGroup("Briefly", id: "main") {
            ContentView(model: model)
        }
        #endif
    }
}

#if os(macOS)
private struct BrieflyMenuBar: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: LibraryModel

    var body: some View {
        Text(model.isWorking ? model.activityStatus : "Briefly is idle")

        Divider()

        Button("Open Briefly") {
            if let window = NSApp.windows.first(where: \.canBecomeMain) {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        if model.canEdit {
            Button("Capture Clipboard") {
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                Task { await model.capture(text) }
            }
        }

        Button("Sync Now") {
            Task { await model.sync() }
        }
        .disabled(model.isSyncing)

        Divider()

        Button("Quit Briefly") {
            NSApp.terminate(nil)
        }
    }
}

extension Notification.Name {
    static let brieflyCaptureClipboard = Self("BrieflyCaptureClipboard")
    static let brieflyCaptureShortcutChanged = Self("BrieflyCaptureShortcutChanged")
    static let brieflyCaptureShortcutRegistrationChanged =
        Self("BrieflyCaptureShortcutRegistrationChanged")
    static let brieflyImportPDF = Self("BrieflyImportPDF")
    static let brieflyRefreshLibrary = Self("BrieflyRefreshLibrary")
}

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
