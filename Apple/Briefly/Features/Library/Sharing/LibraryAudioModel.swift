import BrieflyCore
import CryptoKit
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

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
            try await LocalSpeechSynthesizer.shared.prepare { [weak self] stage in
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
            speechPreparationStatus = "Local voice unavailable"
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
        #if os(iOS)
        let backgroundActivity = SpeechBackgroundActivity()
        backgroundActivity.start()
        #endif
        defer {
            isGeneratingSpeech = false
            #if os(iOS)
            backgroundActivity.end()
            #endif
        }
        let description = variant == .source
            ? "document"
            : "\(variant.title.lowercased()) summary"
        guard isLocalSpeechReady else {
            session.errorMessage = "The on-device voice is unavailable. Try again after it finishes loading."
            return false
        }

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

                try await LocalSpeechSynthesizer.shared.synthesize(text, to: localURL)
                try segmentReady(localURL)
            }
            session.status = "Audio ready (on-device voice)"
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
            let paragraph = spokenText(lines.joined(separator: "\n"))
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
        return paragraphs.flatMap { LocalSpeechSynthesizer.segments(for: $0) }
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

#if os(iOS)
@MainActor
private final class SpeechBackgroundActivity {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func start() {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Briefly voice synthesis"
        ) { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
