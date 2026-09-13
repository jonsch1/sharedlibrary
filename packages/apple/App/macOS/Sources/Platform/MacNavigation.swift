import SwiftUI

#if os(macOS)
struct MacXNavigation: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    @Binding var showsCaptureComposer: Bool
    @Binding var selectedSettingsSection: BrieflySettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                BrieflyLogo()
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .padding(.bottom, 10)

            ForEach(LibrarySection.allCases) { section in
                Button {
                    showsSettings = false
                    Task { await model.workflows.show(section) }
                } label: {
                    navigationRow(
                        section.title,
                        icon: section.icon,
                        selected: model.navigation.activeSection == section &&
                            !model.navigation.showingHighlights && !model.navigation.showingTrash
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("navigation.\(section.rawValue)")
            }

            Button {
                showsSettings = false
                model.workflows.showHighlights()
            } label: {
                navigationRow(
                    "Highlights",
                    icon: "highlighter",
                    selected: model.navigation.showingHighlights
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("navigation.highlights")

            Button {
                showsSettings = false
                model.workflows.showTrash()
            } label: {
                navigationRow("Trash", icon: "trash", selected: model.navigation.showingTrash)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("navigation.trash")
            .modifier(EmptyTrashContextMenu(model: model))

            Button {
                switch model.navigation.activeSection {
                case .items:
                    showsCaptureComposer = true
                case .channels:
                    model.navigation.query = ""
                    model.workflows.showChannelSettings("new")
                }
            } label: {
                Label(primaryActionTitle, systemImage: primaryActionIcon)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 0))
            .accessibilityIdentifier(
                model.navigation.activeSection == .items ? "capture.open" : "navigation.primaryAction"
            )
            .padding(.top, 12)
            .padding(.horizontal, 4)

            if !model.settings.isProcessingConfigured {
                Button {
                    selectedSettingsSection = .ai
                    showsSettings = true
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI setup needed")
                                .font(.caption.weight(.semibold))
                            Text("Test your processing setup in Settings.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10), in: Rectangle())
                    .overlay { Rectangle().stroke(Color.orange.opacity(0.25)) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("settings.aiWarning")
            }

            Spacer(minLength: 18)

            Button {
                showsSettings = true
            } label: {
                navigationRow("Settings", icon: "gearshape", selected: showsSettings)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings.open")
        }
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity)
    }

    private var primaryActionTitle: String {
        switch model.navigation.activeSection {
        case .items: "Capture"
        case .channels: "Manage Channels"
        }
    }

    private var primaryActionIcon: String {
        switch model.navigation.activeSection {
        case .items: "plus"
        case .channels: "slider.horizontal.3"
        }
    }

    private func navigationRow(
        _ title: String,
        icon: String,
        selected: Bool
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: selected ? .semibold : .regular))
                .frame(width: 28)
            Text(title)
                .font(.system(size: 19, weight: selected ? .bold : .medium))
            Spacer()
        }
        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.82))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}

#endif
