import AVFoundation
import MediaPlayer
import SwiftUI

struct SpeechQueueItem: Identifiable, Equatable {
    let id = UUID()
    var entryID: String
    var title: String
    var variant: CloudLibraryVariant
    var text: String
}

@MainActor
final class SpeechPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var currentItem: SpeechQueueItem?
    @Published private(set) var queue: [SpeechQueueItem] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var progress = 0.0
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    private let synthesizer = AVSpeechSynthesizer()
    private var chunks: [String] = []
    private var chunkIndex = 0
    private var completedCharacterCount = 0
    private var totalCharacterCount = 0
    private var isStopping = false

    override init() {
        super.init()
        synthesizer.delegate = self
        configureRemoteCommands()
    }

    func play(_ entry: MobileLibraryEntry, variant: CloudLibraryVariant) {
        guard let text = entry.texts[variant], !text.isEmpty else { return }
        stop(clearQueue: true)
        start(SpeechQueueItem(
            entryID: entry.id,
            title: entry.title,
            variant: variant,
            text: text
        ))
    }

    func enqueue(_ entry: MobileLibraryEntry, variant: CloudLibraryVariant) {
        guard let text = entry.texts[variant], !text.isEmpty else { return }
        let item = SpeechQueueItem(
            entryID: entry.id,
            title: entry.title,
            variant: variant,
            text: text
        )
        if currentItem == nil {
            start(item)
        } else {
            queue.append(item)
            updateNowPlaying()
        }
    }

    func togglePlayback() {
        if synthesizer.isPaused {
            _ = synthesizer.continueSpeaking()
            isPlaying = true
        } else if synthesizer.isSpeaking {
            _ = synthesizer.pauseSpeaking(at: .word)
            isPlaying = false
        } else if currentItem == nil, let next = queue.first {
            queue.removeFirst()
            start(next)
        }
        updateNowPlaying()
    }

    func playNext() {
        guard !queue.isEmpty else {
            stop(clearQueue: false)
            return
        }
        isStopping = true
        synthesizer.stopSpeaking(at: .immediate)
        isStopping = false
        let next = queue.removeFirst()
        start(next)
    }

    func removeFromQueue(at offsets: IndexSet) {
        queue.remove(atOffsets: offsets)
        updateNowPlaying()
    }

    func moveQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        updateNowPlaying()
    }

    func stop(clearQueue: Bool = false) {
        isStopping = true
        synthesizer.stopSpeaking(at: .immediate)
        isStopping = false
        currentItem = nil
        chunks = []
        chunkIndex = 0
        progress = 0
        isPlaying = false
        if clearQueue {
            queue.removeAll()
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self, totalCharacterCount > 0 else { return }
            progress = min(
                1,
                Double(completedCharacterCount + characterRange.location)
                    / Double(totalCharacterCount)
            )
            updateNowPlaying()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self, !isStopping else { return }
            completedCharacterCount += utterance.speechString.count
            if chunkIndex + 1 < chunks.count {
                chunkIndex += 1
                speakCurrentChunk()
            } else if !queue.isEmpty {
                let next = queue.removeFirst()
                start(next)
            } else {
                currentItem = nil
                isPlaying = false
                progress = 1
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
        }
    }

    private func start(_ item: SpeechQueueItem) {
        configureAudioSession()
        currentItem = item
        chunks = Self.chunks(from: Self.spokenText(from: item.text))
        chunkIndex = 0
        completedCharacterCount = 0
        totalCharacterCount = chunks.reduce(0) { $0 + $1.count }
        progress = 0
        guard !chunks.isEmpty else {
            currentItem = nil
            isPlaying = false
            return
        }
        speakCurrentChunk()
    }

    private func speakCurrentChunk() {
        guard chunks.indices.contains(chunkIndex) else { return }
        let utterance = AVSpeechUtterance(string: chunks[chunkIndex])
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.15
        synthesizer.speak(utterance)
        isPlaying = true
        updateNowPlaying()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            // The synthesizer can still report a useful playback error through the system.
        }
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard self?.isPlaying == true else { return }
                self?.togglePlayback()
            }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let currentItem else { return }
        let duration = Double(totalCharacterCount) / 12.5
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentItem.title,
            MPMediaItemPropertyArtist: "Shared Library · \(currentItem.variant.title)",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: duration * progress,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count + 1,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: 0
        ]
    }

    private static func spokenText(from markdown: String) -> String {
        markdown
            .replacingOccurrences(
                of: #"\[([^\]]+)\]\([^)]+\)"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?m)^\s{0,3}#{1,6}\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func chunks(from text: String, maximumLength: Int = 1_800) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        var output: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                output.append(trimmed)
            }
            current = ""
        }

        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if current.count + trimmed.count + 2 <= maximumLength {
                current += current.isEmpty ? trimmed : "\n\n\(trimmed)"
                continue
            }
            flush()
            if trimmed.count <= maximumLength {
                current = trimmed
            } else {
                var start = trimmed.startIndex
                while start < trimmed.endIndex {
                    let end = trimmed.index(
                        start,
                        offsetBy: maximumLength,
                        limitedBy: trimmed.endIndex
                    ) ?? trimmed.endIndex
                    output.append(String(trimmed[start..<end]))
                    start = end
                }
            }
        }
        flush()
        return output
    }
}
