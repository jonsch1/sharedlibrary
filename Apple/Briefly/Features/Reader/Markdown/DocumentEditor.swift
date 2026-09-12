import SwiftUI
import BrieflyCore

struct DocumentEditor: View {
    @Bindable var model: LibraryModel
    let entryID: String
    let variant: LibraryVariant
    let sourceText: String
    let highlightedPassages: [String]
    let isEditing: Bool
    @State private var draft: String
    @State private var pendingSave: Task<Void, Never>?
    @State private var savesInProgress = 0
    @State private var saveGeneration = 0

    init(
        model: LibraryModel,
        entryID: String,
        variant: LibraryVariant,
        sourceText: String,
        highlightedPassages: [String],
        isEditing: Bool
    ) {
        self.model = model
        self.entryID = entryID
        self.variant = variant
        self.sourceText = sourceText
        self.highlightedPassages = highlightedPassages
        self.isEditing = isEditing
        _draft = State(initialValue: sourceText)
    }

    var body: some View {
        EditableDocumentTextView(
            text: $draft,
            isEditable: model.session.canEdit && !model.navigation.showingTrash && isEditing,
            highlightedPassages: highlightedPassages,
            onHighlight: model.session.canEdit && !model.navigation.showingTrash ? { text in
                Task { await model.workflows.addHighlight(text) }
            } : nil,
            onRemoveHighlight: model.session.canEdit && !model.navigation.showingTrash ? { text in
                Task { await model.workflows.removeHighlight(text) }
            } : nil
        )
        .onChange(of: sourceText) { oldValue, newValue in
            if draft == oldValue, pendingSave == nil, savesInProgress == 0 {
                draft = newValue
            }
        }
        .onChange(of: draft) {
            pendingSave?.cancel()
            pendingSave = nil
            saveGeneration += 1
            guard model.session.canEdit, !model.navigation.showingTrash, isEditing,
                  draft != sourceText || savesInProgress > 0 else {
                return
            }
            let text = draft
            let generation = saveGeneration
            pendingSave = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                savesInProgress += 1
                await model.workflows.saveText(text, entryID: entryID, variant: variant)
                savesInProgress -= 1
                if saveGeneration == generation { pendingSave = nil }
            }
        }
    }
}
