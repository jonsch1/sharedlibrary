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

    weak var navigation: LibraryNavigationModel?
    weak var channels: LibraryChannelModel?
    weak var lifecycle: LibraryLifecycleModel?

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

    func select(_ id: String, extending: Bool = false) async {
        navigation?.showingHighlights = false
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
        guard let entry = selectedEntry else {
            selectedText = ""
            return
        }
        if let voiceBriefID = entry.voiceBriefID,
           navigation?.selectedVoiceBriefID.isEmpty == false
        {
            navigation?.selectedVoiceBriefID = voiceBriefID
        }
        selectedVariant = entry.preferredVariant
        await loadSelectedText()
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
    }

    func selectInitialContent() {
        navigation?.showingHighlights = false
        navigation?.showingTrash = false
        #if os(macOS)
        navigation?.activeSection = .items
        navigation?.selectedTopic = "All"
        navigation?.selectedChannelDomain = "All"
        navigation?.selectedChannelSource = ""
        navigation?.selectedVoiceBriefID = ""
        navigation?.showingChannelSettings = false
        navigation?.showingVoiceBriefSettings = false
        clear()
        #else
        if session.projection.voiceBriefDefinitions.contains(where: {
            !session.projection.episodes(for: $0.id).isEmpty
        }) {
            navigation?.activeSection = .briefs
            navigation?.selectedVoiceBriefID = ""
            clear()
        } else {
            navigation?.activeSection = .items
            selectedID = session.projection.entries.first(where: \.isMainLibraryEntry)?.id ?? ""
            selectedIDs = selectedID.isEmpty ? [] : [selectedID]
            selectedVariant = selectedEntry?.preferredVariant ?? .concise
            selectedText = ""
        }
        #endif
    }

    func restoreSelection(preferredEntryID: String? = nil) async {
        if navigation?.showingHighlights == true {
            clear()
            return
        }
        let entryID = preferredEntryID ?? selectedID
        if (session.projection.entries + trashEntries).contains(where: { $0.id == entryID }) {
            await select(entryID)
            return
        }

        clear()
        #if os(macOS)
        let hasSelectedChannel = channels?.channels.contains(where: {
            $0.source == navigation?.selectedChannelSource
        }) ?? false
        if navigation?.selectedChannelSource != "new", !hasSelectedChannel
        {
            navigation?.selectedChannelSource = ""
            navigation?.showingChannelSettings = false
        }
        if navigation?.selectedVoiceBriefID != "new",
           !session.projection.voiceBriefDefinitions.contains(where: {
               $0.id == navigation?.selectedVoiceBriefID
           })
        {
            navigation?.selectedVoiceBriefID = ""
            navigation?.showingVoiceBriefSettings = false
        }
        #else
        switch navigation?.activeSection {
        case .items, .none:
            break
        case .channels:
            let hasSelectedChannel = channels?.channels.contains(where: {
                $0.source == navigation?.selectedChannelSource
            }) ?? false
            if navigation?.selectedChannelSource != "new", !hasSelectedChannel
            {
                navigation?.selectedChannelSource = channels?.channels.first?.source ?? ""
            }
        case .briefs:
            if navigation?.selectedVoiceBriefID != "new",
               !session.projection.voiceBriefDefinitions.contains(where: {
                   $0.id == navigation?.selectedVoiceBriefID
               })
            {
                navigation?.selectedVoiceBriefID =
                    session.projection.voiceBriefDefinitions.first?.id ?? ""
            }
        }
        #endif
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

    func loadSelectedText() async {
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
            let document = try await library.getDocument(
                entryID,
                includeDeleted: navigation?.showingTrash == true
            )
            guard selectedID == entryID, selectedVariant == variant else { return }
            selectedText = document.texts[variant] ?? ""
            await loadHighlights()
        } catch {
            session.errorMessage = error.localizedDescription
            selectedText = ""
        }
    }

    func selectVariant(_ variant: LibraryVariant) async {
        selectedVariant = variant
        await loadSelectedText()
    }

    func saveText(_ text: String, entryID: String, variant: LibraryVariant) async {
        guard let library = session.library, !entryID.isEmpty else { return }
        do {
            try await library.writeText(entryID: entryID, variant: variant, text: text)
            session.projection = try await library.loadLibraryIndex()
            if selectedID == entryID, selectedVariant == variant {
                selectedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            session.status = "Document saved"
            lifecycle?.requestSync()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func addHighlight(_ text: String) async {
        guard let library = session.library, !selectedID.isEmpty else { return }
        do {
            try await library.addHighlight(entryID: selectedID, variant: selectedVariant, text: text)
            try await refreshHighlights(from: library)
            session.status = "Added to Highlights"
            lifecycle?.requestSync()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func removeHighlight(_ text: String) async {
        guard let library = session.library else { return }
        do {
            guard try await library.removeHighlight(text) else { return }
            try await refreshHighlights(from: library)
            session.status = "Removed from Highlights"
            lifecycle?.requestSync()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func trash(entryID: String) async {
        guard let library = session.library else { return }
        let ids = selectedEntryIDs(fallback: entryID)
        guard !ids.isEmpty else { return }
        do {
            for id in ids { try await library.moveToTrash(entryID: id) }
            clear()
            if let lifecycle {
                await lifecycle.refreshLibrary()
            }
            session.status = ids.count == 1
                ? "The document and its summaries were moved to Trash"
                : "\(ids.count) documents and their summaries were moved to Trash"
            lifecycle?.requestSync()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }
}
