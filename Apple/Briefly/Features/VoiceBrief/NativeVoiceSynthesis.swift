import AVFoundation
import Foundation

@MainActor
func synthesizeSystemVoiceBriefAudio(_ text: String, to url: URL) async throws {
    guard !text.isEmpty else { throw NativeLibraryError.emptySpeech }
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        var file: AVAudioFile?
        var finished = false
        synthesizer.write(utterance) { [synthesizer] buffer in
            guard !finished else { return }
            _ = synthesizer
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                finished = true
                continuation.resume(throwing: NativeLibraryError.audioGenerationFailed)
                return
            }
            if pcm.frameLength == 0 {
                finished = true
                if file == nil {
                    continuation.resume(throwing: NativeLibraryError.audioGenerationFailed)
                } else {
                    file = nil
                    continuation.resume()
                }
                return
            }
            do {
                if file == nil {
                    file = try AVAudioFile(
                        forWriting: url,
                        settings: pcm.format.settings
                    )
                }
                try file?.write(from: pcm)
            } catch {
                finished = true
                synthesizer.stopSpeaking(at: .immediate)
                continuation.resume(throwing: error)
            }
        }
    }
}
