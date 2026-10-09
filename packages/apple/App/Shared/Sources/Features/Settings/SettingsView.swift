import Foundation
import SwiftUI

#if os(iOS)
/// The Settings tab on iPhone and iPad. The Mac shows the same sections in
/// `MacXSettingsWorkspace` inside the main window.
struct SettingsView: View {
    @Bindable var model: LibraryModel
    @Binding var path: [BrieflySettingsSection]

    var body: some View {
        NavigationStack(path: $path) {
            SettingsIndex(model: model)
                .settingsScreen(title: "Settings")
                .navigationDestination(for: BrieflySettingsSection.self) { section in
                    ScrollView {
                        SettingsSectionContent(section: section, model: model)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, 120)
                    }
                    .settingsScreen(title: section.title)
                }
        }
        .task {
            await model.account.refreshAccount()
        }
    }
}

private extension View {
    func settingsScreen(title: String) -> some View {
        self
            .scrollIndicators(.hidden)
            .background { BrieflyAtmosphere().ignoresSafeArea() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
