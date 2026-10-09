import SwiftUI
import BrieflyCore

#if os(iOS)
struct MobileXDetail: View {
    @Bindable var model: LibraryModel
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?

    var body: some View {
        LibraryDetail(
            model: model,
            audioPlayer: audioPlayer,
            audioEntry: $audioEntry
        )
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Plays the open item, or reopens the player once this item's audio is current.
struct MobileReaderPlayButton: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?

    private var isCurrentPlayback: Bool {
        audioPlayer.currentEntryID == entry.id &&
            audioPlayer.isCurrentPlayback(
                model.audio.audioPlaybackID(
                    for: entry,
                    variant: model.selection.selectedVariant,
                    text: model.selection.selectedText
                )
            )
    }

    var body: some View {
        Button(action: play) {
            ZStack {
                Circle().fill(Color.accentColor)
                if isCurrentPlayback && audioPlayer.isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                } else if model.audio.isGeneratingSpeech && !isCurrentPlayback {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCurrentPlayback ? "Open audio player" : "Play audio")
        .accessibilityIdentifier("reader.play")
        .disabled(
            !isCurrentPlayback &&
                (model.audio.isGeneratingSpeech || model.selection.selectedText.isEmpty)
        )
    }

    private func play() {
        if isCurrentPlayback {
            audioEntry = entry
            return
        }
        let variant = model.selection.selectedVariant
        let text = model.selection.selectedText
        Task {
            await audioPlayer.play(entry, variant: variant, text: text, model: model) {
                audioEntry = entry
            }
        }
    }
}

#endif
