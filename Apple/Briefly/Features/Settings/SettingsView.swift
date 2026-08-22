import Foundation
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("BrieflyAppearance") var appearance = "system"
    #if os(macOS)
    @State var captureShortcut = CaptureShortcut.load()
    @State var shortcutRegistered = UserDefaults.standard.bool(
        forKey: "BrieflyCaptureShortcutRegistered"
    )
    #endif
    @Bindable var model: LibraryModel
    var initialSection: BrieflySettingsSection? = nil
    @State var appleSignInNonce = ""
    @State var settingsQuery = ""
    @State var showingAccountDeletionConfirmation = false
    #if os(iOS)
    @State var selectedSection: BrieflySettingsSection?
    #else
    @State var selectedSection: BrieflySettingsSection? = .general
    #endif

    var availableSections: [BrieflySettingsSection] {
        #if os(iOS)
        BrieflySettingsSection.allCases.filter { $0 != .capture }
        #else
        BrieflySettingsSection.allCases
        #endif
    }

    func settingsRow(
        _ section: BrieflySettingsSection,
        value: String? = nil
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: section.icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 24)
            Text(section.title)
            Spacer()
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .tag(section)
    }

    func externalSettingsRow(
        _ title: String,
        icon: String,
        destination: String
    ) -> some View {
        Link(destination: URL(string: destination)!) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 24)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityHint("Opens in your browser")
    }

}
