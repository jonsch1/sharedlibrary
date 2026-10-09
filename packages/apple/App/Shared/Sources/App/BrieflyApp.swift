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
    @AppStorage(MacWorkspaceLayout.sidebarCollapsedKey) private var sidebarCollapsed = false
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
        .defaultSize(width: 1240, height: 860)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { post(.brieflyOpenSettings) }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(!model.lifecycle.isReady)
            }
            CommandGroup(replacing: .newItem) {
                Button("Capture…") { post(.brieflyOpenCaptureComposer) }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.lifecycle.isReady)
                Button("Capture Clipboard") { post(.brieflyCaptureClipboard) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Import file…") { post(.brieflyImportFile) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Refresh Library") { post(.brieflyRefreshLibrary) }
                    .keyboardShortcut("r", modifiers: .command)
            }
            // Listed ahead of the standard Find submenu so ⌘F reaches the library search.
            CommandGroup(before: .textEditing) {
                Button("Search Library") { post(.brieflyFocusSearch) }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!model.lifecycle.isReady)
            }
            CommandGroup(replacing: .sidebar) {
                Button(sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                    sidebarCollapsed.toggle()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
                Button("Back") { post(.brieflyNavigateBack) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(model.selection.selectedEntry == nil)
                Divider()
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

    #if os(macOS)
    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
    #endif
}
