import SwiftUI

extension SettingsView {
    var filteredSettingsSections: [BrieflySettingsSection] {
        guard !settingsQuery.isEmpty else { return availableSections }
        return availableSections.filter {
            $0.title.localizedCaseInsensitiveContains(settingsQuery)
        }
    }

    func settingsNavigationRow(_ section: BrieflySettingsSection) -> some View {
        let selected = selectedSection == section
        return HStack(spacing: 12) {
            Image(systemName: section.icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.callout.weight(.medium))
                Text(settingsSubtitle(section))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .background(selected ? Color.primary.opacity(0.055) : .clear)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(selected ? Color.accentColor : .clear)
                .frame(width: 3)
        }
        .contentShape(Rectangle())
    }

    func settingsSubtitle(_ section: BrieflySettingsSection) -> String {
        switch section {
        case .general: "Color scheme and display"
        case .library: "Storage, refresh, and iCloud"
        case .capture: "Shortcut, imports, and media"
        case .account: "Sign-in and subscription"
        case .personalization: "Your context"
        case .topics: "Reusable library topics"
        case .ai: "Provider, command, and prompt"
        }
    }

}
