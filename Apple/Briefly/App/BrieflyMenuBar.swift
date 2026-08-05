import SwiftUI
#if os(macOS)
import AppKit
#endif
#if os(macOS)
struct BrieflyMenuBar: View {
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

        if model.session.canEdit {
            Button("Capture Clipboard") {
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                Task { await model.processing.capture(text) }
            }
        }

        Button("Sync Now") {
            Task { await model.lifecycle.sync() }
        }
        .disabled(model.lifecycle.isSyncing)

        Divider()

        Button("Quit Briefly") {
            NSApp.terminate(nil)
        }
    }
}

#endif
