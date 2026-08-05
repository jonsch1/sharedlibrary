import AVFoundation
import BrieflyCore
import CryptoKit
import Observation

@MainActor
@Observable
final class LibraryAudioModel {
    let session: LibrarySession

    var isGeneratingSpeech = false
    var isPreparingSpeech = false
    var isLocalSpeechReady = false
    var speechPreparationStatus = "Preparing local voice…"

    @ObservationIgnored
    private var localSpeechPreparation: Task<Void, Never>?

    init(session: LibrarySession) {
        self.session = session
    }

    func beginLocalSpeechPreparation() {
        guard !isPreparingSpeech, !isLocalSpeechReady, localSpeechPreparation == nil else {
            return
        }
        localSpeechPreparation = Task { @MainActor [weak self] in
            await self?.prepareLocalSpeech()
        }
    }

    func prepareLocalSpeech() async {
        guard !isPreparingSpeech, !isLocalSpeechReady else { return }
        isPreparingSpeech = true
        speechPreparationStatus = "Preparing local voice…"
        defer {
            isPreparingSpeech = false
            localSpeechPreparation = nil
        }
        do {
            try await LocalVoiceBriefSynthesizer.shared.prepare { [weak self] stage in
                Task { @MainActor in
                    guard let self else { return }
                    switch stage {
                    case .downloading(let fraction):
                        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
                        self.speechPreparationStatus = "Downloading local voice… \(percent)%"
                    case .loading:
                        self.speechPreparationStatus = "Loading local voice…"
                    case .ready:
                        self.speechPreparationStatus = "Local voice ready"
                    }
                }
            }
            isLocalSpeechReady = true
            speechPreparationStatus = "Local voice ready"
        } catch {
            isLocalSpeechReady = false
            speechPreparationStatus = "System voice will be used"
        }
    }

    func audioURL(for entryID: String) async -> URL? {
        do {
            guard let library = session.library else { return nil }
            return try await library.audioURL(entryID: entryID)
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    func audioPlaybackID(
        for entry: LibraryEntry,
        variant: LibraryVariant,
        text: String
    ) -> String {
        let key = "\(entry.id)\n\(variant.rawValue)\n\(text)"
        let digest = SHA256.hash(data: Data(key.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(entry.id):\(variant.rawValue):\(digest)"
    }

    func streamPlayableAudio(
        for entry: LibraryEntry,
        variant: LibraryVariant,
        text rawText: String,
        segmentReady: (URL) throws -> Void
    ) async -> Bool {
        if variant == .source, let original = await audioURL(for: entry.id) {
            do {
                try segmentReady(original)
                return true
            } catch {
                session.errorMessage = error.localizedDescription
                return false
            }
        }

        let segments = narrationSegments(from: rawText)
        guard !segments.isEmpty else {
            session.errorMessage = NativeLibraryError.emptySpeech.localizedDescription
            return false
        }
        guard !isGeneratingSpeech else { return false }

        isGeneratingSpeech = true
        defer { isGeneratingSpeech = false }
        let description = variant == .source
            ? "document"
            : "\(variant.title.lowercased()) summary"
        var useSystemVoice = !isLocalSpeechReady

        do {
            for (index, text) in segments.enumerated() {
                session.status = "Preparing \(description) audio \(index + 1)/\(segments.count)…"
                let localURL = try speechCacheURL(
                    entryID: entry.id,
                    variant: variant,
                    text: text,
                    engine: "kokoro-ane-v1"
                )
                if usableCachedAudio(at: localURL) {
                    try segmentReady(localURL)
                    continue
                }

                if !useSystemVoice {
                    do {
                        try await LocalVoiceBriefSynthesizer.shared.synthesize(text, to: localURL)
                        try segmentReady(localURL)
                        continue
                    } catch {
                        useSystemVoice = true
                    }
                }

                let systemURL = try speechCacheURL(
                    entryID: entry.id,
                    variant: variant,
                    text: text,
                    engine: "system-v1"
                )
                if !usableCachedAudio(at: systemURL) {
                    try? FileManager.default.removeItem(at: systemURL)
                    session.status = "Local voice unavailable; using system voice…"
                    try await synthesizeSystemVoiceBriefAudio(text, to: systemURL)
                }
                try segmentReady(systemURL)
            }
            session.status = useSystemVoice
                ? "Audio ready (system voice)"
                : "Audio ready (on-device voice)"
            return true
        } catch {
            session.errorMessage = error.localizedDescription
            return false
        }
    }

    func narrationSegments(from markdown: String) -> [String] {
        var paragraphs = [String]()
        var lines = [String]()

        func finishParagraph() {
            guard !lines.isEmpty else { return }
            let paragraph = spokenVoiceBriefText(lines.joined(separator: "\n"))
            if !paragraph.isEmpty { paragraphs.append(paragraph) }
            lines.removeAll(keepingCapacity: true)
        }

        for line in markdown.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                finishParagraph()
            } else {
                lines.append(line)
            }
        }
        finishParagraph()
        return paragraphs.flatMap { LocalVoiceBriefSynthesizer.segments(for: $0) }
    }

    private func speechCacheURL(
        entryID: String,
        variant: LibraryVariant,
        text: String,
        engine: String
    ) throws -> URL {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw NativeLibraryError.audioGenerationFailed
        }
        let directory = caches
            .appending(path: "Briefly", directoryHint: .isDirectory)
            .appending(path: "Speech", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = "\(engine)\n\(entryID)\n\(variant.rawValue)\n\(text)"
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: "\(digest).wav")
    }

    private func usableCachedAudio(at url: URL) -> Bool {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return (size ?? 0) > 44
    }
}
