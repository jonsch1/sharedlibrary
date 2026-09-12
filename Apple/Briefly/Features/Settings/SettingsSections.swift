
enum BrieflySettingsSection: String, CaseIterable, Identifiable {
    case general
    case library
    case capture
    case account
    case topics
    case ai

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "Appearance"
        case .library: "Library & Sync"
        case .capture: "Capture"
        case .account: "Account"
        case .topics: "Topics"
        case .ai: "AI Processing"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .library: "folder"
        case .capture: "keyboard"
        case .account: "person.crop.circle"
        case .topics: "number"
        case .ai: "sparkles"
        }
    }
}
