import Foundation
import SwiftUI
import BrieflyCore

struct EntryContextMenu: ViewModifier {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @State private var confirmsTrash = false

    func body(content: Content) -> some View {
        content.contextMenu {
            if let source = entry.sourceURL, let url = URL(string: source) {
                Link(destination: url) {
                    Label("Open original", systemImage: "arrow.up.right")
                }
            }
            if model.session.canEdit {
                #if os(macOS)
                if entry.captureRequest == nil || entry.captureRequest?.state == .ready {
                    Button {
                        Task {
                            await model.workflows.select(entry.id)
                            await model.workflows.processSelected()
                        }
                    } label: {
                        Label("Regenerate summaries", systemImage: "sparkles")
                    }
                    .disabled(model.isProcessing)
                    Divider()
                }
                #endif
                Button(role: .destructive) {
                    confirmsTrash = true
                } label: {
                    Label(
                        model.selection.selectionCount(for: entry.id) > 1
                            ? "Move Items to Trash"
                            : "Move to Trash",
                        systemImage: "trash"
                    )
                }
            }
        }
        .confirmationDialog(
            model.selection.selectionCount(for: entry.id) > 1
                ? "Move \(model.selection.selectionCount(for: entry.id)) items to Trash?"
                : "Move this item to Trash?",
            isPresented: $confirmsTrash
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.workflows.trash(entryID: entry.id) }
            }
        }
    }
}

struct TrashItemContextMenu: ViewModifier {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @State private var confirmsDeletion = false

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Delete Permanently…", systemImage: "trash.slash", role: .destructive) {
                confirmsDeletion = true
            }
            .disabled(!model.session.canEdit)
        }
        .confirmationDialog("Delete this item permanently?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                Task { await model.workflows.permanentlyDelete(entryID: entry.id) }
            }
        } message: {
            Text("“\(entry.title)” and its attachments will be deleted from your library and synced devices. This cannot be undone.")
        }
    }
}

struct EmptyTrashContextMenu: ViewModifier {
    @Bindable var model: LibraryModel
    @State private var confirmsDeletion = false

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Empty Trash…", systemImage: "trash.slash", role: .destructive) { confirmsDeletion = true }
                .disabled(!model.session.canEdit || model.selection.loadedTrashCount == 0)
        }
        .emptyTrashConfirmation(model: model, isPresented: $confirmsDeletion)
    }
}

struct EmptyTrashButton: View {
    @Bindable var model: LibraryModel
    @State private var confirmsDeletion = false

    var body: some View {
        Button("Empty Trash…", systemImage: "trash.slash", role: .destructive) { confirmsDeletion = true }
            .disabled(!model.session.canEdit || model.selection.trashEntries.isEmpty)
            .emptyTrashConfirmation(model: model, isPresented: $confirmsDeletion)
    }
}

private extension View {
    func emptyTrashConfirmation(model: LibraryModel, isPresented: Binding<Bool>) -> some View {
        confirmationDialog("Empty Trash?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) {
                Task { await model.workflows.emptyTrash() }
            }
        } message: {
            Text("All items in Trash and their attachments will be deleted from your library and synced devices. This cannot be undone.")
        }
    }
}
