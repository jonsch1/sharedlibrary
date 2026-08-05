import BrieflyCore
import Observation

@MainActor
@Observable
final class LibraryVoiceBriefModel {
    let session: LibrarySession

    var isRunningVoiceBrief = false
    var voiceBriefGenerationProgress: VoiceBriefGenerationProgress?

    init(session: LibrarySession) {
        self.session = session
    }

    func voiceBrief(for id: String) -> LibraryVoiceBrief? {
        guard !id.isEmpty else { return nil }
        return session.projection.voiceBriefDefinitions.first { $0.id == id }
    }

    @discardableResult
    func beginGeneration(for brief: LibraryVoiceBrief) -> Bool {
        guard !isRunningVoiceBrief else { return false }
        isRunningVoiceBrief = true
        voiceBriefGenerationProgress = VoiceBriefGenerationProgress(
            voiceBriefID: brief.id,
            totalChannelCount: brief.sources.count
        )
        return true
    }

    func finishGeneration() {
        isRunningVoiceBrief = false
        voiceBriefGenerationProgress = nil
    }
}
