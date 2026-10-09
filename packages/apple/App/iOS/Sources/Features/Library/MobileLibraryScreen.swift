import SwiftUI
import BrieflyCore

#if os(iOS)
struct MobileXHighlightsScreen: View {
    @Bindable var model: LibraryModel
    let openSettings: (BrieflySettingsSection?) -> Void
    let openTrash: () -> Void
    @State private var showsAbout = false

    var body: some View {
        Group {
            if model.selection.highlightsText.isEmpty {
                XEmptyState(
                    icon: "highlighter",
                    title: "No highlights yet",
                    message: "Select a passage in any item, then choose Highlight."
                )
                .frame(maxWidth: 720, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    MarkdownArticle(model.selection.highlightsText)
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .mobileHeaderBar {
            MobileXHeader(
                title: "Highlights",
                menuItems: [
                    MobileXHeaderMenuItem(
                        title: "Trash",
                        icon: "trash",
                        identifier: "library.trash.open",
                        action: openTrash
                    ),
                    MobileXHeaderMenuItem(
                        title: "Settings",
                        icon: "gearshape",
                        identifier: "settings.open",
                        action: { openSettings(nil) }
                    ),
                    MobileXHeaderMenuItem(
                        title: "Appearance",
                        icon: "circle.lefthalf.filled",
                        action: { openSettings(.general) }
                    ),
                    MobileXHeaderMenuItem(
                        title: "Account",
                        icon: "person.crop.circle",
                        action: { openSettings(.account) }
                    ),
                    MobileXHeaderMenuItem(
                        title: "About & Feedback",
                        icon: "info.circle",
                        action: { showsAbout = true }
                    )
                ]
            )
        }
        .background { BrieflyAtmosphere().ignoresSafeArea() }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsAbout) {
            MobileAboutFeedbackView()
        }
    }
}

struct MobileXTrashScreen: View {
    @Bindable var model: LibraryModel
    let openEntry: (LibraryEntry) -> Void

    var body: some View {
        Group {
            if model.selection.trashEntries.isEmpty {
                XEmptyState(
                    icon: "trash",
                    title: "Trash is empty",
                    message: "Deleted items stay here until you empty the trash."
                )
                .frame(maxWidth: 720, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.selection.trashEntries) { entry in
                            FeedEntryRow(entry: entry) { openEntry(entry) }
                                .modifier(TrashItemContextMenu(model: model, entry: entry))
                        }
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background { BrieflyAtmosphere().ignoresSafeArea() }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EmptyTrashButton(model: model)
            }
        }
    }
}

private struct MobileAboutFeedbackView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary
        let release = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(release) (\($0))" } ?? release
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("About Briefly") {
                    LabeledContent("Version", value: version)
                    Text("Briefly turns saved material into a focused personal reading library.")
                        .foregroundStyle(.secondary)
                }

                Section("Help") {
                    Link(
                        "Send feedback",
                        destination: URL(string: "https://www.readbriefly.fyi/feedback")!
                    )
                }

                Section("Legal") {
                    Link(
                        "Privacy Policy",
                        destination: URL(string: "https://www.readbriefly.fyi/privacy")!
                    )
                    Link(
                        "Terms of Use",
                        destination: URL(string: "https://www.readbriefly.fyi/terms")!
                    )
                    Link(
                        "Imprint",
                        destination: URL(string: "https://www.readbriefly.fyi/imprint")!
                    )
                }
            }
            .navigationTitle("About & Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#endif
