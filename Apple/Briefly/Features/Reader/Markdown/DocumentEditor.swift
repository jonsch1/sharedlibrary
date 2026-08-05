import AVFoundation
import AuthenticationServices
import BrieflyCore
import CloudKit
import CryptoKit
import Observation
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#elseif os(iOS)
import BackgroundTasks
import MediaPlayer
import UIKit
#endif

struct DocumentEditor: View {
    @Bindable var model: LibraryModel
    let entryID: String
    let variant: LibraryVariant
    let sourceText: String
    let highlightedPassages: [String]
    let isEditing: Bool
    @State private var draft: String
    @State private var pendingSave: Task<Void, Never>?

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
            if draft == oldValue { draft = newValue }
        }
        .onChange(of: draft) {
            guard model.session.canEdit, !model.navigation.showingTrash, isEditing, draft != sourceText else {
                return
            }
            pendingSave?.cancel()
            let text = draft
            pendingSave = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                await model.workflows.saveText(text, entryID: entryID, variant: variant)
            }
        }
    }
}
