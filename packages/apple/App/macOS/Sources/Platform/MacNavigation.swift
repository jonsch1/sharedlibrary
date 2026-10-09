import SwiftUI

#if os(macOS)
/// Column geometry for the main window. The reading column is centered in the window
/// with the sidebar beside it, rather than at the window edge. Settings starts where
/// the reading column does and may
/// extend further right, so opening it never moves the sidebar.
struct MacWorkspaceLayout {
    static let sidebarCollapsedKey = "BrieflySidebarCollapsed"
    static let minimumWindowSize = CGSize(width: 760, height: 600)
    static let outerPadding: CGFloat = 20
    static let spacing: CGFloat = 24
    static let readerWidth: CGFloat = 680
    static let maximumSettingsWidth: CGFloat = 1_014
    /// WindowControlPositioner moves the traffic lights to end around x = 76;
    /// the sidebar logo must start to the right of this.
    private static let windowControlsEnd: CGFloat = 84
    private static let logoPadding: CGFloat = 12

    let sidebarWidth: CGFloat
    let readerColumnWidth: CGFloat
    let settingsWidth: CGFloat
    let settingsIndexWidth: CGFloat
    /// Distance from the window's leading edge to the sidebar.
    let leadingOffset: CGFloat
    /// Extra leading space the expanded sidebar header needs to clear the traffic lights.
    let windowControlsInset: CGFloat

    static func sidebarWidth(collapsed: Bool) -> CGFloat {
        collapsed ? 56 : 220
    }

    init(windowWidth: CGFloat, sidebarCollapsed: Bool) {
        sidebarWidth = Self.sidebarWidth(collapsed: sidebarCollapsed)
        let sidebarSpan = sidebarWidth + Self.spacing
        readerColumnWidth = max(0, min(Self.readerWidth, windowWidth - Self.outerPadding * 2 - sidebarSpan))
        // Center the reading column in the window; only shift it right when the
        // sidebar would otherwise run past the leading padding.
        let contentStart = max(
            ((windowWidth - readerColumnWidth) / 2).rounded(),
            Self.outerPadding + sidebarSpan
        )
        leadingOffset = contentStart - sidebarSpan
        settingsWidth = max(0, min(Self.maximumSettingsWidth, windowWidth - Self.outerPadding - contentStart))
        settingsIndexWidth = min(220, max(170, (settingsWidth * 0.25).rounded()))
        windowControlsInset = max(0, Self.windowControlsEnd - leadingOffset - Self.logoPadding)
    }
}

struct MacXNavigation: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    @Binding var showsCaptureComposer: Bool
    @Binding var selectedSettingsSection: BrieflySettingsSection
    @Binding var collapsed: Bool
    var windowControlsInset: CGFloat = 0

    var body: some View {
        if collapsed {
            compactBody
        } else {
            expandedBody
        }
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 2) {
                BrieflyLogo()
                Spacer(minLength: 8)
                sidebarToggle
            }
            .padding(.leading, 12 + windowControlsInset)
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

            Button(action: primaryAction) {
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
                            Text(model.settings.isOpenRouterConnected ? "Check your OpenRouter connection in Settings." : "Connect OpenRouter to create summaries.")
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

    /// Icon-only rail used while the sidebar is collapsed.
    private var compactBody: some View {
        VStack(spacing: 5) {
            Color.clear
                .frame(height: 42)
                .padding(.bottom, 10)
                .accessibilityHidden(true)

            sidebarToggle

            ForEach(LibrarySection.allCases) { section in
                compactButton(
                    section.title,
                    icon: section.icon,
                    selected: model.navigation.activeSection == section &&
                        !model.navigation.showingHighlights && !model.navigation.showingTrash
                ) {
                    showsSettings = false
                    Task { await model.workflows.show(section) }
                }
                .accessibilityIdentifier("navigation.\(section.rawValue)")
            }
            compactButton(
                "Highlights",
                icon: "highlighter",
                selected: model.navigation.showingHighlights
            ) {
                showsSettings = false
                model.workflows.showHighlights()
            }
            .accessibilityIdentifier("navigation.highlights")
            compactButton(
                "Trash",
                icon: "trash",
                selected: model.navigation.showingTrash
            ) {
                showsSettings = false
                model.workflows.showTrash()
            }
            .accessibilityIdentifier("navigation.trash")
            .modifier(EmptyTrashContextMenu(model: model))

            Button(action: primaryAction) {
                Image(systemName: primaryActionIcon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor, in: Rectangle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(primaryActionTitle)
            .accessibilityLabel(primaryActionTitle)
            .accessibilityIdentifier(
                model.navigation.activeSection == .items ? "capture.open" : "navigation.primaryAction"
            )
            .padding(.top, 12)

            if !model.settings.isProcessingConfigured {
                compactButton(
                    "AI setup needed",
                    icon: "exclamationmark.triangle.fill",
                    selected: false,
                    tint: .orange
                ) {
                    selectedSettingsSection = .ai
                    showsSettings = true
                }
                .accessibilityIdentifier("settings.aiWarning")
            }

            Spacer(minLength: 18)

            compactButton("Settings", icon: "gearshape", selected: showsSettings) {
                showsSettings = true
            }
            .accessibilityIdentifier("settings.open")
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarToggle: some View {
        let title = collapsed ? "Show Sidebar" : "Hide Sidebar"
        return Button { collapsed.toggle() } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) (⌃⌘S)")
        .accessibilityLabel(title)
    }

    private func compactButton(
        _ title: String,
        icon: String,
        selected: Bool,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: selected ? .semibold : .regular))
                .foregroundStyle(tint ?? (selected ? Color.primary : Color.primary.opacity(0.72)))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func primaryAction() {
        switch model.navigation.activeSection {
        case .items:
            showsCaptureComposer = true
        case .channels:
            model.navigation.query = ""
            model.workflows.showChannelSettings("new")
        }
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
