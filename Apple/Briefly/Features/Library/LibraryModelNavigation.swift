import BrieflyCore
import Observation

@MainActor
@Observable
final class LibraryNavigationModel {
    let session: LibrarySession
    let selection: LibrarySelectionModel

    var activeSection = LibrarySection.briefs
    var selectedVoiceBriefID = ""
    var selectedChannelSource = ""
    var showingVoiceBriefSettings = false
    var showingChannelSettings = false
    var showingHighlights = false
    var showingTrash = false
    var query = ""
    var selectedTopic = "All"
    var selectedChannelDomain = "All"

    weak var channels: LibraryChannelModel?

    init(session: LibrarySession, selection: LibrarySelectionModel) {
        self.session = session
        self.selection = selection
    }

    var homeEntries: [LibraryEntry] {
        session.projection.entries.filter(\.isMainLibraryEntry)
    }

    var filteredEntries: [LibraryEntry] {
        let entries = showingTrash ? selection.trashEntries : homeEntries
        return entries.filter {
            (selectedTopic.isEmpty || selectedTopic == "All" ||
                $0.topicNames.contains(selectedTopic)) && $0.matches(query)
        }
    }

    func show(_ section: LibrarySection) async {
        activeSection = section
        showingHighlights = false
        showingTrash = false
        query = ""
        selection.clear()
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
            await channels?.loadChannels()
        case .briefs:
            selectedVoiceBriefID = ""
            showingVoiceBriefSettings = false
        }
    }

    func selectVoiceBrief(_ id: String) {
        showingHighlights = false
        showingTrash = false
        showingVoiceBriefSettings = false
        selection.clear()
        selectedVoiceBriefID = id
    }

    func selectChannel(_ source: String) {
        showingHighlights = false
        showingTrash = false
        showingChannelSettings = false
        selection.clear()
        selectedChannelSource = source
    }

    func showVoiceBriefSettings(_ id: String) {
        selectVoiceBrief(id)
        showingVoiceBriefSettings = true
        Task { await channels?.loadChannels() }
    }

    func showChannelSettings(_ source: String) {
        selectChannel(source)
        showingChannelSettings = true
        Task { await channels?.loadChannels() }
    }

    func showChannelDomain(_ domain: String) {
        selectedChannelDomain = domain
        selectedChannelSource = ""
        showingChannelSettings = false
        selection.clear()
    }

    func showHighlights() {
        activeSection = .items
        selection.clear()
        showingTrash = false
        showingHighlights = true
        Task { await selection.loadHighlights() }
    }

    func showInbox() {
        activeSection = .items
        selectedTopic = "All"
        showingHighlights = false
        showingTrash = false
        selection.clear()
    }

    func showTrash() {
        activeSection = .items
        selectedTopic = "All"
        showingHighlights = false
        showingTrash = true
        selection.clear()
        Task { await selection.loadTrash() }
    }

    func showTopic(_ topic: String) async {
        selectedTopic = topic
        showingHighlights = false
        showingTrash = false
        selection.clear()
    }

    func navigateBack() {
        if !selection.selectedID.isEmpty {
            selection.clear()
        } else if activeSection == .channels {
            selectedChannelSource = ""
            showingChannelSettings = false
        } else if activeSection == .briefs {
            if showingVoiceBriefSettings {
                showingVoiceBriefSettings = false
                if selectedVoiceBriefID == "new" { selectedVoiceBriefID = "" }
            } else {
                selectedVoiceBriefID = ""
            }
        }
    }

    func trashSelected() async {
        await selection.trash(entryID: selection.selectedID)
    }

    func clearError() {
        session.errorMessage = nil
    }
}
