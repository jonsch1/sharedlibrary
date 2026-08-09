import SwiftUI

#if os(iOS)
struct MobileXHeaderAction {
    let icon: String
    let label: String
    var identifier: String? = nil
    let action: () -> Void
}

struct MobileXHeaderMenuItem {
    let title: String
    let icon: String
    var identifier: String? = nil
    let action: () -> Void
}

struct MobileXHeader: View {
    let title: String
    var showsLogo = false
    var search: MobileXHeaderAction? = nil
    var searchesTrailing = false
    var primary: MobileXHeaderAction? = nil
    var trailing: MobileXHeaderAction? = nil
    var menuItems: [MobileXHeaderMenuItem] = []

    var body: some View {
        ZStack {
            if !showsLogo {
                Text(title)
                    .font(.headline.weight(.bold))
            }

            HStack(spacing: 6) {
                if showsLogo {
                    BrieflyLogo()
                        .padding(.leading, 6)
                }

                if let search, !searchesTrailing {
                    headerButton(search)
                }

                Spacer()

                if let search, searchesTrailing {
                    headerButton(search)
                }

                if let trailing {
                    headerButton(trailing)
                }

                if let primary {
                    headerButton(primary)
                }

                if !menuItems.isEmpty {
                    Menu {
                        ForEach(Array(menuItems.enumerated()), id: \.offset) { _, item in
                            Button(action: item.action) {
                                Label(item.title, systemImage: item.icon)
                            }
                            .accessibilityIdentifier(
                                item.identifier ?? "header.menu.\(slug(item.title))"
                            )
                        }
                    } label: {
                        headerIcon("ellipsis")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("library.more")
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private func headerButton(_ action: MobileXHeaderAction) -> some View {
        Button(action: action.action) {
            headerIcon(action.icon)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.label)
        .accessibilityIdentifier(
            action.identifier ?? "header.\(slug(action.label))"
        )
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 42, height: 42)
            .background(Color.primary.opacity(0.06), in: Circle())
            .contentShape(Circle())
    }

    private func slug(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}

struct MobileXSearchField: View {
    @Binding var text: String
    let prompt: String
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.search)
                    .accessibilityIdentifier("library.search")
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 40)
            .background(Color.primary.opacity(0.07), in: Capsule())

            Button("Cancel", action: cancel)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .task { focused = true }
    }
}

#endif
