
enum BrieflySettingsSection: String, CaseIterable, Identifiable {
    case account
    case general
    case library
    case topics
    case capture
    case ai
    case agents

    var id: Self { self }

    /// Capture shortcuts, AI processing, and assistant connections run on the Mac only.
    static var available: [BrieflySettingsSection] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { ![.capture, .ai, .agents].contains($0) }
        #endif
    }

    var title: String {
        switch self {
        case .general: "Appearance"
        case .library: "Library & Sync"
        case .capture: "Capture"
        case .account: "Account"
        case .topics: "Topics"
        case .ai: "AI Processing"
        case .agents: "Connect your AI"
        }
    }

    var summary: String {
        switch self {
        case .general: "Theme and background images."
        case .library: "iCloud sync, refresh, and export."
        case .capture: "Save from anywhere on your Mac."
        case .account: "Sign in to share items with public links."
        case .topics: "The topics Briefly files new items under."
        case .ai: "Connect OpenRouter and shape your summaries."
        case .agents: "Use your library from Claude, Codex, and other assistants."
        }
    }

    var icon: String {
        switch self {
        case .general: "circle.lefthalf.filled"
        case .library: "icloud"
        case .capture: "keyboard"
        case .account: "person.crop.circle"
        case .topics: "number"
        case .ai: "sparkles"
        case .agents: "point.3.connected.trianglepath.dotted"
        }
    }
}
