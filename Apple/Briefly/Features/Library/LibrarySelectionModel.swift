import BrieflyCore
import Observation

@MainActor
@Observable
final class LibrarySelectionModel {
    let session: LibrarySession

    var selectedID = ""
    var selectedIDs = Set<String>()
    var selectedVariant = LibraryVariant.concise
    var selectedText = ""
    var isLoadingText = false
    var trashEntries = [LibraryEntry]()
    var highlightsText = ""
    var hasLoadedTrash = false
    var hasLoadedHighlights = false

    private var selectedEntryIsInTrash = false

    init(session: LibrarySession) {
        self.session = session
    }

    var selectedEntry: LibraryEntry? {
        (session.projection.entries + trashEntries).first { $0.id == selectedID }
    }

    var highlightCount: Int {
        highlightsText.components(separatedBy: .newlines).count { $0.hasPrefix("## ") }
    }

    var loadedHighlightCount: Int? {
        hasLoadedHighlights ? highlightCount : nil
    }

    var loadedTrashCount: Int? {
        hasLoadedTrash ? trashEntries.count : nil
    }

    @discardableResult
    func select(
        _ id: String,
        extending: Bool = false,
        includeDeleted: Bool = false
    ) async -> LibraryEntry? {
        if extending {
            if selectedIDs.remove(id) != nil {
                if selectedID == id {
                    selectedID = selectedEntryIDs(fallback: "").last ?? ""
                }
            } else {
                selectedIDs.insert(id)
                selectedID = id
            }
        } else {
            selectedID = id
            selectedIDs = id.isEmpty ? [] : [id]
        }
        selectedEntryIsInTrash = includeDeleted && !id.isEmpty
        guard let entry = selectedEntry else {
            selectedText = ""
            return nil
        }
        selectedVariant = entry.preferredVariant
        await loadSelectedText(includeDeleted: includeDeleted)
        return entry
    }

    func selectedEntryIDs(fallback: String) -> [String] {
        let ids = !fallback.isEmpty && !selectedIDs.contains(fallback)
            ? Set([fallback])
            : selectedIDs
        return session.projection.entries.compactMap { ids.contains($0.id) ? $0.id : nil }
    }

    func selectionCount(for entryID: String) -> Int {
        selectedIDs.contains(entryID) ? selectedIDs.count : 1
    }

    func clear() {
        selectedID = ""
        selectedIDs = []
        selectedText = ""
        selectedEntryIsInTrash = false
    }

    @discardableResult
    func selectInitialContent() -> LibrarySection {
        selectedEntryIsInTrash = false
        #if os(macOS)
        clear()
        return .items
        #else
        selectedID = session.projection.entries.first(where: \.isMainLibraryEntry)?.id ?? ""
        selectedIDs = selectedID.isEmpty ? [] : [selectedID]
        selectedVariant = selectedEntry?.preferredVariant ?? .concise
        selectedText = ""
        return .items
        #endif
    }

    @discardableResult
    func restoreSelection(preferredEntryID: String? = nil) async -> Bool {
        let entryID = preferredEntryID ?? selectedID
        guard (session.projection.entries + trashEntries).contains(where: { $0.id == entryID }) else {
            clear()
            return false
        }
        await select(entryID, includeDeleted: selectedEntryIsInTrash)
        return true
    }

    func refreshTrash(from store: SQLiteLibraryStore) async throws {
        trashEntries = try await store.loadTrashIndex().filter(\.isMainLibraryEntry)
        hasLoadedTrash = true
    }

    func loadTrash() async {
        guard let library = session.library, !hasLoadedTrash else { return }
        do {
            try await refreshTrash(from: library)
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func refreshHighlights(from store: SQLiteLibraryStore) async throws {
        highlightsText = try await store.loadHighlights()
        hasLoadedHighlights = true
    }

    func loadHighlights() async {
        guard let library = session.library, !hasLoadedHighlights else { return }
        do {
            try await refreshHighlights(from: library)
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func loadSelectedText(includeDeleted: Bool = false) async {
        guard
            let entry = selectedEntry,
            let reference = entry.text(for: selectedVariant)
        else {
            selectedText = ""
            return
        }
        guard let library = session.library else {
            selectedText = reference.text ?? ""
            return
        }
        let entryID = entry.id
        let variant = selectedVariant
        isLoadingText = true
        defer { isLoadingText = false }
        do {
            let document = try await library.getDocument(entryID, includeDeleted: includeDeleted)
            guard selectedID == entryID, selectedVariant == variant else { return }
            selectedText = document.texts[variant] ?? ""
            await loadHighlights()
        } catch {
            session.errorMessage = error.localizedDescription
            selectedText = ""
        }
    }

    func selectVariant(_ variant: LibraryVariant, includeDeleted: Bool? = nil) async {
        if let includeDeleted {
            selectedEntryIsInTrash = includeDeleted
        }
        selectedVariant = variant
        await loadSelectedText(includeDeleted: selectedEntryIsInTrash)
    }

    @discardableResult
    func saveText(_ text: String, entryID: String, variant: LibraryVariant) async -> Bool {
        guard let library = session.library, !entryID.isEmpty else { return false }
        do {
            try await library.writeText(entryID: entryID, variant: variant, text: text)
            session.projection = try await library.loadLibraryIndex()
            if selectedID == entryID, selectedVariant == variant {
                selectedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            session.status = "Document saved"
            return true
        } catch {
            session.errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addHighlight(_ text: String) async -> Bool {
        guard let library = session.library, !selectedID.isEmpty else { return false }
        do {
            try await library.addHighlight(entryID: selectedID, variant: selectedVariant, text: text)
            try await refreshHighlights(from: library)
            session.status = "Added to Highlights"
            return true
        } catch {
            session.errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func removeHighlight(_ text: String) async -> Bool {
        guard let library = session.library else { return false }
        do {
            guard try await library.removeHighlight(text) else { return false }
            try await refreshHighlights(from: library)
            session.status = "Removed from Highlights"
            return true
        } catch {
            session.errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func trash(entryID: String) async -> Int {
        guard let library = session.library else { return 0 }
        let ids = selectedEntryIDs(fallback: entryID)
        guard !ids.isEmpty else { return 0 }
        do {
            for id in ids { try await library.moveToTrash(entryID: id) }
            clear()
            session.status = ids.count == 1
                ? "The document and its summaries were moved to Trash"
                : "\(ids.count) documents and their summaries were moved to Trash"
            return ids.count
        } catch {
            session.errorMessage = error.localizedDescription
            return 0
        }
    }
}
