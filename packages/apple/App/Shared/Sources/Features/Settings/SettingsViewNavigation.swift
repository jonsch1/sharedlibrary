import SwiftUI

#if os(iOS)
/// The iOS settings root: one row per section, then help and legal links.
struct SettingsIndex: View {
    @Bindable var model: LibraryModel
    @AppStorage("BrieflyAppearance") private var appearance = "system"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                SettingsGroup(title: nil) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(BrieflySettingsSection.available) { section in
                            NavigationLink(value: section) {
                                SettingsRow(
                                    icon: section.icon,
                                    title: section.title,
                                    subtitle: section.summary
                                ) {
                                    if let value = value(for: section) {
                                        Text(value)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                SettingsGroup(title: "Help & legal") {
                    SettingsWebLinks()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
    }

    private func value(for section: BrieflySettingsSection) -> String? {
        switch section {
        case .account: model.account.account.authenticated ? "Signed in" : nil
        case .general: appearance == "system" ? "System" : appearance.capitalized
        default: nil
        }
    }
}
#endif
