import SwiftUI
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#endif

@main
struct BrieflyApp: App {
    @State private var model: LibraryModel
    #if os(macOS)
    @NSApplicationDelegateAdaptor(BrieflyAppDelegate.self) private var appDelegate
    #endif

    init() {
        let environment = AppEnvironment.current()
        _model = State(initialValue: LibraryModel(environment: environment))
    }

    var body: some Scene {
        #if os(macOS)
        Window("Briefly", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1500, height: 900)
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
                .disabled(model.account.account.entitled != true)
                Button("Import PDF…") {
                    NotificationCenter.default.post(
                        name: .brieflyImportPDF,
                        object: nil
                    )
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.account.account.entitled != true)
                Divider()
                Button("Refresh Library") {
                    NotificationCenter.default.post(
                        name: .brieflyRefreshLibrary,
                        object: nil
                    )
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.account.account.entitled != true)
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
