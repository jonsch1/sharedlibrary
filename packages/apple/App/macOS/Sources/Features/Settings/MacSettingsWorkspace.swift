import SwiftUI

#if os(macOS)
/// Settings inside the main window: a short section index beside the selected
/// section, both drawn directly on the window background.
struct MacXSettingsWorkspace: View {
    @Bindable var model: LibraryModel
    @Binding var selectedSection: BrieflySettingsSection
    let indexWidth: CGFloat
    /// Width the index and detail content occupy; the detail scroll view extends past
    /// it to the window edge.
    let contentWidth: CGFloat

    private var detailWidth: CGFloat {
        max(0, contentWidth - indexWidth)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            settingsIndex
                .frame(width: indexWidth)

            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task {
            await model.account.refreshAccount()
        }
    }

    private var settingsIndex: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.title2.weight(.bold))
                    .padding(.horizontal, 12)
                    .frame(height: 40, alignment: .leading)
                    .padding(.bottom, 12)

                ForEach(BrieflySettingsSection.available) { section in
                    Button { selectedSection = section } label: {
                        indexRow(section.title, icon: section.icon, selected: selectedSection == section)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                }

                SettingsWebLinks()
                    .padding(.horizontal, 12)
                    .padding(.top, 28)
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var settingsDetail: some View {
        ScrollView {
            SettingsSectionContent(section: selectedSection, model: model)
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 40)
                .frame(width: detailWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(selectedSection)
        }
        .fadingHeaderBar {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedSection.title)
                    .font(.title2.weight(.bold))
                    .frame(height: 40, alignment: .leading)
                Text(selectedSection.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(width: detailWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func indexRow(_ title: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .frame(width: 22)
            Text(title)
                .font(.system(size: 15, weight: selected ? .bold : .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.72))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(selected ? Color.primary.opacity(0.055) : .clear, in: Rectangle())
        .contentShape(Rectangle())
    }
}
#endif
