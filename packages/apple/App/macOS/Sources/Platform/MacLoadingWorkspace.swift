import SwiftUI

#if os(macOS)
struct MacXLoadingWorkspace: View {
    @AppStorage(MacWorkspaceLayout.sidebarCollapsedKey) private var sidebarCollapsed = false
    let status: String

    var body: some View {
        GeometryReader { proxy in
            workspace(MacWorkspaceLayout(windowWidth: proxy.size.width, sidebarCollapsed: sidebarCollapsed))
        }
        .background { BrieflyAtmosphere().ignoresSafeArea() }
        .ignoresSafeArea(.container, edges: .top)
    }

    private func workspace(_ layout: MacWorkspaceLayout) -> some View {
        HStack(alignment: .top, spacing: MacWorkspaceLayout.spacing) {
            VStack(alignment: .leading, spacing: 5) {
                // Mirrors the sidebar's logo row, which drops below the window controls.
                Color.clear
                    .frame(
                        height: layout.logoBelowWindowControls && !sidebarCollapsed
                            ? 42 + MacWorkspaceLayout.titlebarZoneBottom - 7
                            : 42
                    )
                    .accessibilityHidden(true)
                ForEach([
                    ("house", "Home"),
                    ("dot.radiowaves.left.and.right", "Channels"),
                    ("highlighter", "Highlights"),
                    ("trash", "Trash")
                ], id: \.1) { icon, title in
                    Group {
                        if sidebarCollapsed {
                            Image(systemName: icon)
                        } else {
                            Label(title, systemImage: icon)
                        }
                    }
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, sidebarCollapsed ? 0 : 12)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44,
                        alignment: sidebarCollapsed ? .center : .leading
                    )
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .frame(width: layout.sidebarWidth)

            VStack(spacing: 0) {
                HStack {
                    Text("Home").font(.title2.weight(.bold))
                    Spacer()
                }
                .padding(18)
                Divider()
                XLoadingState(
                    title: "Opening your library",
                    message: status
                )
            }
            .frame(width: layout.readerColumnWidth)
            .frame(maxHeight: .infinity)
        }
        .padding(.leading, layout.leadingOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#endif
