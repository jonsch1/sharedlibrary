import Foundation
import Security
import SwiftUI

func randomAppleNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        return UUID().uuidString
    }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// A titled run of settings rows. Groups sit directly on the background and are
/// separated by spacing rather than panels or dividers.
struct SettingsGroup<Content: View>: View {
    let title: String?
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            content
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Icon, title, and optional detail on the leading edge with a control on the trailing edge.
struct SettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = .primary
    var iconTint: Color? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(iconTint ?? (tint == .primary ? Color.secondary : tint))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(tint)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        tint: Color = .primary,
        iconTint: Color? = nil
    ) {
        self.init(icon: icon, title: title, subtitle: subtitle, tint: tint, iconTint: iconTint) {
            EmptyView()
        }
    }
}

/// A whole-row button for one-off actions such as syncing or signing out.
struct SettingsActionRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var role: ButtonRole? = nil
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            SettingsRow(
                icon: icon,
                title: title,
                subtitle: subtitle,
                tint: role == .destructive ? .red : .primary
            ) {
                if isWorking {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Single-line and multi-line text inputs share the search field's square fill.
struct SettingsFieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(Color.primary.opacity(0.055), in: Rectangle())
    }
}

extension View {
    func settingsField() -> some View {
        modifier(SettingsFieldBackground())
    }
}

/// Help and legal pages hosted on the Briefly website.
struct SettingsWebLinks: View {
    private static let links: [(title: String, icon: String, path: String)] = [
        ("Feedback", "bubble.left.and.bubble.right", "feedback"),
        ("Privacy Policy", "hand.raised", "privacy"),
        ("Terms of Use", "doc.text", "terms"),
        ("Imprint", "building.columns", "imprint")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.links, id: \.path) { link in
                Link(destination: URL(string: "https://www.readbriefly.fyi/\(link.path)")!) {
                    SettingsRow(icon: link.icon, title: link.title) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens in your browser")
            }
        }
    }
}
