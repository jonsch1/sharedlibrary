import BrieflyCore
import Observation

@MainActor
@Observable
final class LibraryNavigationModel {
    let session: LibrarySession

    var activeSection = LibrarySection.items
    var selectedChannelSource = ""
    var showingChannelSettings = false
    var showingHighlights = false
    var showingTrash = false
    var query = ""
    var selectedTopic = "All"
    var selectedChannelDomain = "All"

    init(session: LibrarySession) {
        self.session = session
    }

    var homeEntries: [LibraryEntry] {
        session.projection.entries.filter(\.isMainLibraryEntry)
    }

    var filteredEntries: [LibraryEntry] {
        filteredEntries(from: homeEntries)
    }

    func filteredEntries(trashEntries: [LibraryEntry]) -> [LibraryEntry] {
        filteredEntries(from: showingTrash ? trashEntries : homeEntries)
    }

    func show(_ section: LibrarySection) {
        activeSection = section
        showingHighlights = false
        showingTrash = false
        query = ""
        switch section {
        case .items:
            #if os(iOS)
            selectedTopic = ""
            #else
            selectedTopic = "All"
            #endif
        case .channels:
            selectedChannelDomain = "All"
            selectedChannelSource = ""
            showingChannelSettings = false
        }
    }

    func selectChannel(_ source: String) {
        activeSection = .channels
        showingHighlights = false
        showingTrash = false
        showingChannelSettings = false
        selectedChannelSource = source
    }

    func showChannelSettings(_ source: String) {
        selectChannel(source)
        showingChannelSettings = true
    }

    func showChannelDomain(_ domain: String) {
        selectedChannelDomain = domain
        selectedChannelSource = ""
        showingChannelSettings = false
    }

    func showHighlights() {
        activeSection = .items
        showingTrash = false
        showingHighlights = true
    }

    func showInbox() {
        activeSection = .items
        selectedTopic = "All"
        showingHighlights = false
        showingTrash = false
    }

    func showTrash() {
        activeSection = .items
        selectedTopic = "All"
        showingHighlights = false
        showingTrash = true
    }

    func showTopic(_ topic: String) {
        selectedTopic = topic
        showingHighlights = false
        showingTrash = false
    }

    func navigateBack(hasSelection: Bool) {
        if hasSelection {
            return
        }
        if activeSection == .channels {
            selectedChannelSource = ""
            showingChannelSettings = false
        }
    }

    private func filteredEntries(from entries: [LibraryEntry]) -> [LibraryEntry] {
        entries.filter {
            (selectedTopic.isEmpty || selectedTopic == "All" ||
                $0.topicNames.contains(selectedTopic)) && $0.matches(query)
        }
    }
}
