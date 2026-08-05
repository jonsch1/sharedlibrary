import FluidAudio
import Foundation

enum LocalVoicePreparation: Sendable {
    case downloading(Double)
    case loading
    case ready
}

actor LocalVoiceBriefSynthesizer {
    static let shared = LocalVoiceBriefSynthesizer()

    private static let preferredChunkLength = 300
    private static let maximumPhonemeLength = 500
    private static let pauseMilliseconds = 120

    private let manager = KokoroAneManager()
    private var isInitialized = false
    private var preparationTask: Task<Void, Error>?

    func prepare(
        progress: (@Sendable (LocalVoicePreparation) -> Void)? = nil
    ) async throws {
        #if arch(arm64) && !targetEnvironment(simulator)
        guard !Self.hasKnownBNNSCrashRisk else {
            throw LocalVoiceError.unsafeOperatingSystem
        }
        if isInitialized {
            progress?(.ready)
            return
        }
        if let preparationTask {
            try await preparationTask.value
            return
        }

        let manager = manager
        let task = Task {
            try await KokoroAneResourceDownloader.ensureModels { snapshot in
                progress?(.downloading(snapshot.fractionCompleted * 0.75))
            }
            try await KokoroAneResourceDownloader.ensureG2PAssets { snapshot in
                progress?(.downloading(0.75 + snapshot.fractionCompleted * 0.2))
            }
            progress?(.loading)
            try await manager.initialize()
            guard await manager.isAvailable() else {
                throw LocalVoiceError.modelUnavailable
            }
            progress?(.ready)
        }
        preparationTask = task
        do {
            try await task.value
            isInitialized = true
            preparationTask = nil
        } catch {
            preparationTask = nil
            throw error
        }
        #else
        throw LocalVoiceError.unsupportedEnvironment
        #endif
    }

    func isReady() -> Bool {
        isInitialized
    }

    nonisolated static func segments(for text: String) -> [String] {
        textChunks(text, maximumLength: preferredChunkLength)
    }

    func synthesize(_ rawText: String, to outputURL: URL) async throws {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalVoiceError.emptyText }

        #if arch(arm64) && !targetEnvironment(simulator)
        try await prepare()
        let phonemeChunks = try await resolvePhonemeChunks(for: text)
        var pcm = Data()
        var sampleRate: Int?

        for phonemes in phonemeChunks {
            try Task.checkCancellation()
            let result = try await manager.synthesizeFromPhonemesDetailed(phonemes)
            if let sampleRate, sampleRate != result.sampleRate {
                throw LocalVoiceError.inconsistentSampleRate
            }
            sampleRate = result.sampleRate
            if !pcm.isEmpty {
                pcm.append(Self.silence(sampleRate: result.sampleRate))
            }
            pcm.append(Self.pcm16Data(from: result.samples))
        }

        guard let sampleRate, !pcm.isEmpty else {
            throw LocalVoiceError.noAudio
        }
        try Self.wavData(pcm: pcm, sampleRate: sampleRate).write(
            to: outputURL,
            options: .atomic
        )
        #else
        throw LocalVoiceError.unsupportedProcessor
        #endif
    }

    private func resolvePhonemeChunks(for text: String) async throws -> [String] {
        var pending = Self.textChunks(
            text,
            maximumLength: Self.preferredChunkLength
        )
        var resolved = [String]()
        var index = 0

        while index < pending.count {
            try Task.checkCancellation()
            let segment = pending[index]
            let phonemes = try await manager.phonemes(for: segment)
            if phonemes.count <= Self.maximumPhonemeLength {
                resolved.append(phonemes)
                index += 1
                continue
            }

            let smallerChunks = Self.textChunks(
                segment,
                maximumLength: max(8, segment.count / 2)
            )
            guard smallerChunks.count > 1 else {
                throw LocalVoiceError.textCannotBeChunked
            }
            pending.replaceSubrange(index...index, with: smallerChunks)
        }

        return resolved
    }

    private static var hasKnownBNNSCrashRisk: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion == 26 && (4...5).contains(version.minorVersion)
    }

    private static func textChunks(
        _ text: String,
        maximumLength: Int
    ) -> [String] {
        var remainder = text[...]
        var chunks = [String]()

        while remainder.count > maximumLength {
            let end = remainder.index(
                remainder.startIndex,
                offsetBy: maximumLength
            )
            let window = remainder[..<end]
            let searchStart = window.index(
                window.startIndex,
                offsetBy: maximumLength / 2
            )
            let searchWindow = window[searchStart...]
            let sentenceBreaks: Set<Character> = [".", "!", "?", ";", ":", "\n"]

            let splitIndex: String.Index
            if let punctuation = searchWindow.lastIndex(where: {
                sentenceBreaks.contains($0)
            }) {
                splitIndex = remainder.index(after: punctuation)
            } else if let whitespace = searchWindow.lastIndex(where: {
                $0.isWhitespace
            }) {
                splitIndex = whitespace
            } else {
                splitIndex = end
            }

            let chunk = String(remainder[..<splitIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            remainder = remainder[splitIndex...]
            while remainder.first?.isWhitespace == true {
                remainder = remainder.dropFirst()
            }
        }

        let finalChunk = String(remainder)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalChunk.isEmpty { chunks.append(finalChunk) }
        return chunks
    }

    private static func pcm16Data(from samples: [Float]) -> Data {
        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        let scale = peak > 0 ? 1 / peak : 1
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.count)

        for sample in samples {
            let normalized = max(-1, min(1, sample * scale))
            pcm.append(Int16(normalized * Float(Int16.max)).littleEndian)
        }

        return pcm.withUnsafeBytes { Data($0) }
    }

    private static func silence(sampleRate: Int) -> Data {
        Data(count: sampleRate * 2 * pauseMilliseconds / 1_000)
    }

    private static func wavData(pcm: Data, sampleRate: Int) throws -> Data {
        guard pcm.count <= Int(UInt32.max) - 36,
              let rate = UInt32(exactly: sampleRate)
        else {
            throw LocalVoiceError.audioTooLarge
        }

        var wav = Data()
        wav.reserveCapacity(44 + pcm.count)
        wav.append(contentsOf: Data("RIFF".utf8))
        appendLittleEndian(UInt32(36 + pcm.count), to: &wav)
        wav.append(contentsOf: Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(rate, to: &wav)
        appendLittleEndian(rate * 2, to: &wav)
        appendLittleEndian(UInt16(2), to: &wav)
        appendLittleEndian(UInt16(16), to: &wav)
        wav.append(contentsOf: Data("data".utf8))
        appendLittleEndian(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        return wav
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private enum LocalVoiceError: LocalizedError {
    case audioTooLarge
    case emptyText
    case inconsistentSampleRate
    case modelUnavailable
    case noAudio
    case textCannotBeChunked
    case unsafeOperatingSystem
    case unsupportedEnvironment
    case unsupportedProcessor

    var errorDescription: String? {
        switch self {
        case .audioTooLarge:
            "The local voice brief is too large to save as a WAV file."
        case .emptyText:
            "The voice brief does not contain text to speak."
        case .inconsistentSampleRate:
            "The local voice returned incompatible audio chunks."
        case .modelUnavailable:
            "The local voice model could not be loaded."
        case .noAudio:
            "The local voice did not create any audio."
        case .textCannotBeChunked:
            "Part of the voice brief is too long for the local voice model."
        case .unsafeOperatingSystem:
            "This OS version has a known Neural Engine speech crash."
        case .unsupportedEnvironment:
            "The local voice requires a physical Apple device."
        case .unsupportedProcessor:
            "The local voice requires Apple silicon."
        }
    }
}
