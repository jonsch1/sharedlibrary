import SwiftUI
import BrieflyCore

#if os(iOS)
struct MobileXLibraryScreen: View {
    enum Section: String, CaseIterable, Hashable {
        case highlights = "Highlights"
        case trash = "Trash"
    }

    @Bindable var model: LibraryModel
    let openSettings: (BrieflySettingsSection?) -> Void
    let openEntry: (LibraryEntry) -> Void
    @State private var section = Section.highlights
    @State private var showsAbout = false

    var body: some View {
        VStack(spacing: 0) {
            MobileXHeader(
                title: "Library",
                menuItems: [
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
                        title: "Account & Subscription",
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
            .mobileGlass(
                in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                interactive: false
            )
            .padding(.horizontal, 8)
            .padding(.top, 4)

            HStack(spacing: 8) {
                ForEach(Section.allCases, id: \.self) { item in
                    Button {
                        section = item
                        if item == .highlights { model.workflows.showHighlights() }
                        else { model.workflows.showTrash() }
                    } label: {
                        Text(item.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(section == item ? Color.primary : Color.primary.opacity(0.06), in: Capsule())
                            .foregroundStyle(section == item ? Color(uiColor: .systemBackground) : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider() }

            if section == .highlights {
                if model.selection.highlightsText.isEmpty {
                    XEmptyState(
                        icon: "highlighter",
                        title: "No highlights yet",
                        message: "Select a passage in any saved document, then choose Highlight."
                    )
                    .frame(maxWidth: 720, maxHeight: .infinity)
                } else {
                    ScrollView {
                        MarkdownArticle(model.selection.highlightsText)
                            .frame(maxWidth: 680, alignment: .leading)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 28)
                            .padding(.bottom, 80)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else if model.selection.trashEntries.isEmpty {
                XEmptyState(
                    icon: "trash",
                    title: "Trash is empty",
                    message: "Deleted notes remain available here."
                )
                .frame(maxWidth: 720, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.selection.trashEntries) { entry in
                            FeedEntryRow(entry: entry) { openEntry(entry) }
                        }
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 96)
                }
            }
        }
        .background { BrieflyAtmosphere().ignoresSafeArea() }
        .toolbar(.hidden, for: .navigationBar)
        .task { model.workflows.showHighlights() }
        .sheet(isPresented: $showsAbout) {
            MobileAboutFeedbackView()
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
