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

                Text("Briefly \(appVersion)")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let release = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(release) (\($0))" } ?? release
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
