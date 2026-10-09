import SwiftUI
import BrieflyCore

#if os(iOS)
struct MobileXHighlightsScreen: View {
    @Bindable var model: LibraryModel
    let openTrash: () -> Void

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
                primary: MobileXHeaderAction(
                    icon: "trash",
                    label: "Trash",
                    identifier: "library.trash.open",
                    action: openTrash
                )
            )
        }
        .background { BrieflyAtmosphere().ignoresSafeArea() }
        .toolbar(.hidden, for: .navigationBar)
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

#endif
