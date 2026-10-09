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
    /// The traffic lights (at their system position) and the sidebar toggle
    /// beside them occupy the window's top-leading corner up to this x and y.
    /// Nothing else is drawn there.
    static let titlebarZoneEnd: CGFloat = 124
    static let titlebarZoneBottom: CGFloat = 44
    /// Leading inset of the sidebar's icon column, shared by the logo and nav rows.
    static let sidebarRowPadding: CGFloat = 12

    let sidebarWidth: CGFloat
    let readerColumnWidth: CGFloat
    /// Everything from the reading column's leading edge to the window's trailing edge.
    /// Scroll views span this so their scrollers sit at the window edge.
    let contentAreaWidth: CGFloat
    let settingsWidth: CGFloat
    let settingsIndexWidth: CGFloat
    /// Distance from the window's leading edge to the sidebar.
    let leadingOffset: CGFloat
    /// True when the sidebar's top row would run into the titlebar zone, so the
    /// expanded sidebar drops its logo below the window controls.
    let logoBelowWindowControls: Bool

    static func sidebarWidth(collapsed: Bool) -> CGFloat {
        collapsed ? 56 : 220
    }

    init(windowWidth: CGFloat, sidebarCollapsed: Bool) {
        sidebarWidth = Self.sidebarWidth(collapsed: sidebarCollapsed)
        let sidebarSpan = sidebarWidth + Self.spacing
        // The content column must clear both the sidebar and the titlebar zone, which
        // matters for the narrow collapsed strip.
        let minimumContentStart = max(Self.outerPadding + sidebarSpan, Self.titlebarZoneEnd)
        readerColumnWidth = max(
            0,
            min(Self.readerWidth, windowWidth - minimumContentStart - Self.outerPadding)
        )
        // Center the reading column in the window; only shift it right when the
        // sidebar or window controls would otherwise be in the way.
        let contentStart = max(
            ((windowWidth - readerColumnWidth) / 2).rounded(),
            minimumContentStart
        )
        leadingOffset = contentStart - sidebarSpan
        contentAreaWidth = max(0, windowWidth - contentStart)
        settingsWidth = max(0, min(Self.maximumSettingsWidth, windowWidth - Self.outerPadding - contentStart))
        settingsIndexWidth = min(220, max(170, (settingsWidth * 0.25).rounded()))
        logoBelowWindowControls = leadingOffset + Self.sidebarRowPadding < Self.titlebarZoneEnd
    }
}

/// Shows or hides the sidebar from the titlebar, just right of the traffic lights.
extension EnvironmentValues {
    /// Width of the reading column inside the full-width content area, or `nil`
    /// outside the main workspace.
    @Entry var readingColumnWidth: CGFloat? = nil
}

extension View {
    /// Pins content to the reading column at the leading edge of the content area,
    /// leaving the rest of the width (and the scroller) to the enclosing scroll view.
    func readingColumn() -> some View {
        modifier(ReadingColumn())
    }
}

private struct ReadingColumn: ViewModifier {
    @Environment(\.readingColumnWidth) private var width

    func body(content: Content) -> some View {
        if let width {
            content
                .frame(width: width)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
        }
    }
}

struct MacXNavigation: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    @Binding var showsCaptureComposer: Bool
    @Binding var selectedSettingsSection: BrieflySettingsSection
    @Binding var collapsed: Bool
    var logoBelowWindowControls = false

    var body: some View {
        if collapsed {
            compactBody
        } else {
            expandedBody
        }
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Drops below the traffic lights rather than shifting sideways, so the
            // wordmark always lines up with the nav icons.
            if logoBelowWindowControls {
                Color.clear
                    .frame(height: MacWorkspaceLayout.titlebarZoneBottom - 12)
                    .accessibilityHidden(true)
            }
            Button {
                showsSettings = false
                Task { await model.workflows.show(.items) }
            } label: {
                BrieflyLogo()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Briefly, Home")
            .help("Home")
            .padding(.leading, MacWorkspaceLayout.sidebarRowPadding)
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
        .padding(.horizontal, MacWorkspaceLayout.sidebarRowPadding)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}

#endif
