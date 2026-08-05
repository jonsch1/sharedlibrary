import AVFoundation
import BrieflyCore
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct AudioPlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    @Bindable var audioPlayer: NativeAudioPlayer

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Listen")
                    .font(.headline)
                Spacer()
                if audioPlayer.isPlaying {
                    Text("Now playing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            Divider()
            #endif

            ScrollView {
                MarkdownArticle(text)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            playbackControls
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 18)
        }
        .background(playerBackground.ignoresSafeArea())
        #if os(iOS)
        .presentationBackground(playerBackground)
        .presentationCornerRadius(32)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 560, idealWidth: 680, minHeight: 620, idealHeight: 760)
        #endif
    }

    private var playbackControls: some View {
        VStack(spacing: 15) {
            VStack(spacing: 3) {
                Slider(
                    value: Binding(
                        get: { audioPlayer.currentTime },
                        set: audioPlayer.seek
                    ),
                    in: 0...max(1, audioPlayer.duration)
                )
                .tint(.primary)
                .accessibilityLabel("Playback position")

                HStack {
                    Text(audioTime(audioPlayer.currentTime))
                    Spacer()
                    Text("-\(audioTime(max(0, audioPlayer.duration - audioPlayer.currentTime)))")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                Menu {
                    ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                        Button {
                            audioPlayer.setRate(speed)
                        } label: {
                            HStack {
                                Text("\(speed.formatted())×")
                                if speed == audioPlayer.rate {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text("\(audioPlayer.rate.formatted())×")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Playback speed")

                Button {
                    audioPlayer.skip(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 27, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Skip back 15 seconds")

                Button {
                    audioPlayer.isPlaying
                        ? audioPlayer.pause()
                        : audioPlayer.resume()
                } label: {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 42, weight: .medium))
                        .frame(width: 60, height: 60)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(audioPlayer.isPlaying ? "Pause audio" : "Play audio")

                Button {
                    audioPlayer.skip(by: 30)
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 27, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Skip forward 30 seconds")

                Menu {
                    Button {
                        audioPlayer.setSleepTimer(minutes: nil)
                    } label: {
                        HStack {
                            Text("Off")
                            if audioPlayer.sleepTimerMinutes == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                        Button {
                            audioPlayer.setSleepTimer(minutes: minutes)
                        } label: {
                            HStack {
                                Text(minutes == 60 ? "1 hour" : "\(minutes) minutes")
                                if audioPlayer.sleepTimerMinutes == minutes {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(
                        systemName: audioPlayer.sleepTimerMinutes == nil
                            ? "moon.zzz"
                            : "moon.zzz.fill"
                    )
                    .font(.system(size: 22, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(
                    audioPlayer.sleepTimerMinutes.map {
                        "Sleep timer, \($0) minutes"
                    } ?? "Sleep timer"
                )
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                Slider(
                    value: Binding(
                        get: { audioPlayer.volume },
                        set: audioPlayer.setVolume
                    ),
                    in: 0...1
                )
                .tint(.primary)
                .accessibilityLabel("Volume")
                Image(systemName: "speaker.wave.3.fill")
            }
            .font(.caption)
        }
    }

    private var playerBackground: Color {
        readerBackground
    }
}
