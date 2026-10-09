import Foundation
import SwiftUI

#if os(iOS)
/// Full-screen settings on iPhone and iPad. The Mac shows the same sections in
/// `MacXSettingsWorkspace` inside the main window.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    @State private var path: [BrieflySettingsSection]

    init(model: LibraryModel, initialSection: BrieflySettingsSection? = nil) {
        self.model = model
        _path = State(initialValue: initialSection.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            SettingsIndex(model: model)
                .settingsScreen(title: "Settings", dismiss: dismiss)
                .navigationDestination(for: BrieflySettingsSection.self) { section in
                    ScrollView {
                        SettingsSectionContent(section: section, model: model)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, 40)
                    }
                    .settingsScreen(title: section.title, dismiss: dismiss)
                }
        }
        .task {
            await model.account.refreshAccount()
        }
    }
}

private extension View {
    func settingsScreen(title: String, dismiss: DismissAction) -> some View {
        self
            .scrollIndicators(.hidden)
            .background { BrieflyAtmosphere().ignoresSafeArea() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
    }
}
#endif
