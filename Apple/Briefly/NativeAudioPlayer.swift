import AVFoundation
import AuthenticationServices
import BrieflyCore
import CloudKit
import CryptoKit
import Observation
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#elseif os(iOS)
import BackgroundTasks
import MediaPlayer
import UIKit
#endif

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

@Observable
final class NativeAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private struct Segment {
        let url: URL
        let duration: Double
    }

    private var player: AVAudioPlayer?
    private var currentURL: URL?
    private var currentTitle: String?
    private var currentPlaybackID: String?
    private var positionKey: String?
    private var segments = [Segment]()
    private var segmentIndex = 0
    private var segmentStartTime = 0.0
    private var resumeTarget: Double?
    private var streamIsFinished = true
    private var shouldPlay = false
    private var timer: Timer?
    private var sleepTimer: Timer?
    #if os(iOS)
    private var remoteCommandTargets = [(MPRemoteCommand, Any)]()
    #endif
    private(set) var currentEntryID: String?
    var isPlaying = false
    var currentTime = 0.0
    var duration = 0.0
    var sleepTimerMinutes: Int?
    var rate = UserDefaults.standard.double(forKey: "BrieflyAudioRate").nonzero ?? 1
    var volume = UserDefaults.standard.object(forKey: "BrieflyAudioVolume") == nil
        ? 1
        : UserDefaults.standard.double(forKey: "BrieflyAudioVolume")

    override init() {
        super.init()
        #if os(iOS)
        configureRemoteCommands()
        #endif
    }

    deinit {
        #if os(iOS)
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
        #endif
    }

    @discardableResult
    func startStream(
        entryID: String,
        title: String,
        playbackID: String,
        positionID: String
    ) throws -> Bool {
        if currentPlaybackID == playbackID {
            shouldPlay = true
            resume()
            return false
        }
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif
        currentEntryID = entryID
        currentTitle = title
        currentPlaybackID = playbackID
        let key = "BrieflyAudioPosition.\(positionID)"
        positionKey = key
        let saved = UserDefaults.standard.double(forKey: key)
        resumeTarget = saved > 0 ? saved : nil
        streamIsFinished = false
        shouldPlay = true
        #if os(iOS)
        setRemoteCommandsEnabled(true)
        #endif
        return true
    }

    func appendSegment(_ url: URL, playbackID: String) throws {
        guard currentPlaybackID == playbackID else { return }
        let probe = try AVAudioPlayer(contentsOf: url)
        guard probe.duration > 0 else {
            throw NativeLibraryError.audioGenerationFailed
        }
        segments.append(Segment(url: url, duration: probe.duration))
        duration = segments.reduce(0) { $0 + $1.duration }
        if player == nil {
            try startNextSegmentIfAvailable()
        }
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
    }

    func isCurrentPlayback(_ playbackID: String) -> Bool {
        currentPlaybackID == playbackID
    }

    func finishStream(playbackID: String) {
        guard currentPlaybackID == playbackID else { return }
        streamIsFinished = true
        if player == nil {
            do {
                try startNextSegmentIfAvailable()
            } catch {
                completePlayback(removeSavedPosition: false)
            }
        }
    }

    func seek(_ time: Double) {
        guard !segments.isEmpty else { return }
        let target = min(max(0, time), duration)
        player?.stop()
        player = nil
        currentURL = nil
        segmentIndex = 0
        segmentStartTime = 0
        resumeTarget = target
        do {
            try startNextSegmentIfAvailable()
        } catch {
            completePlayback(removeSavedPosition: false)
        }
        savePosition()
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
    }

    func skip(by seconds: Double) {
        seek(currentTime + seconds)
    }

    func pause() {
        shouldPlay = false
        guard let player else {
            isPlaying = false
            return
        }
        player.pause()
        isPlaying = false
        savePosition()
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
    }

    func resume() {
        shouldPlay = true
        guard let player else {
            try? startNextSegmentIfAvailable()
            return
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        guard player.play() else {
            isPlaying = false
            return
        }
        isPlaying = true
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
        startTimer()
    }

    func setRate(_ value: Double) {
        rate = value
        player?.rate = Float(value)
        UserDefaults.standard.set(value, forKey: "BrieflyAudioRate")
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
    }

    func setVolume(_ value: Double) {
        volume = value
        player?.volume = Float(value)
        UserDefaults.standard.set(value, forKey: "BrieflyAudioVolume")
    }

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerMinutes = minutes
        guard let minutes else { return }
        sleepTimer = Timer.scheduledTimer(
            withTimeInterval: Double(minutes * 60),
            repeats: false
        ) { [weak self] _ in
            self?.pause()
            self?.sleepTimer = nil
            self?.sleepTimerMinutes = nil
        }
    }

    func stop() {
        savePosition()
        timer?.invalidate()
        timer = nil
        setSleepTimer(minutes: nil)
        player?.stop()
        player = nil
        currentURL = nil
        currentEntryID = nil
        currentTitle = nil
        currentPlaybackID = nil
        positionKey = nil
        segments.removeAll()
        segmentIndex = 0
        segmentStartTime = 0
        resumeTarget = nil
        streamIsFinished = true
        shouldPlay = false
        isPlaying = false
        currentTime = 0
        duration = 0
        #if os(iOS)
        setRemoteCommandsEnabled(false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        segmentStartTime += segments[segmentIndex].duration
        segmentIndex += 1
        self.player = nil
        currentURL = nil
        do {
            try startNextSegmentIfAvailable()
        } catch {
            completePlayback(removeSavedPosition: false)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = self.segmentStartTime + player.currentTime
            self.isPlaying = player.isPlaying
        }
    }

    private func savePosition() {
        guard let positionKey else { return }
        let position = player.map { segmentStartTime + $0.currentTime } ?? currentTime
        UserDefaults.standard.set(position, forKey: positionKey)
    }

    private func startNextSegmentIfAvailable() throws {
        while segmentIndex < segments.count {
            let segment = segments[segmentIndex]
            if let resumeTarget,
               resumeTarget >= segmentStartTime + segment.duration
            {
                segmentStartTime += segment.duration
                segmentIndex += 1
                continue
            }

            let next = try AVAudioPlayer(contentsOf: segment.url)
            next.delegate = self
            next.enableRate = true
            next.rate = Float(rate)
            next.volume = Float(volume)
            next.prepareToPlay()
            if let resumeTarget {
                next.currentTime = min(
                    max(0, resumeTarget - segmentStartTime),
                    next.duration
                )
                self.resumeTarget = nil
            }
            if shouldPlay, !next.play() {
                throw NativeLibraryError.audioPlaybackFailed
            }
            player = next
            currentURL = segment.url
            currentTime = segmentStartTime + next.currentTime
            isPlaying = next.isPlaying
            startTimer()
            #if os(iOS)
            updateNowPlayingInfo()
            #endif
            return
        }

        player = nil
        currentURL = nil
        currentTime = min(segmentStartTime, duration)
        isPlaying = false
        if streamIsFinished {
            completePlayback(removeSavedPosition: true)
        }
    }

    private func completePlayback(removeSavedPosition: Bool) {
        timer?.invalidate()
        timer = nil
        setSleepTimer(minutes: nil)
        player?.stop()
        player = nil
        currentURL = nil
        currentPlaybackID = nil
        shouldPlay = false
        streamIsFinished = true
        isPlaying = false
        currentTime = 0
        if removeSavedPosition, let positionKey {
            UserDefaults.standard.removeObject(forKey: positionKey)
        }
        #if os(iOS)
        setRemoteCommandsEnabled(false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    #if os(iOS)
    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.preferredIntervals = [30]
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
        commands.seekBackwardCommand.isEnabled = false
        commands.seekForwardCommand.isEnabled = false

        remoteCommandTargets = [
            (commands.playCommand, commands.playCommand.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.resume() }
                return .success
            }),
            (commands.pauseCommand, commands.pauseCommand.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.pause() }
                return .success
            }),
            (
                commands.togglePlayPauseCommand,
                commands.togglePlayPauseCommand.addTarget { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isPlaying ? self.pause() : self.resume()
                    }
                    return .success
                }
            ),
            (
                commands.skipBackwardCommand,
                commands.skipBackwardCommand.addTarget { [weak self] event in
                    guard let event = event as? MPSkipIntervalCommandEvent else {
                        return .commandFailed
                    }
                    DispatchQueue.main.async { self?.skip(by: -event.interval) }
                    return .success
                }
            ),
            (
                commands.skipForwardCommand,
                commands.skipForwardCommand.addTarget { [weak self] event in
                    guard let event = event as? MPSkipIntervalCommandEvent else {
                        return .commandFailed
                    }
                    DispatchQueue.main.async { self?.skip(by: event.interval) }
                    return .success
                }
            ),
            (
                commands.changePlaybackPositionCommand,
                commands.changePlaybackPositionCommand.addTarget { [weak self] event in
                    guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                        return .commandFailed
                    }
                    DispatchQueue.main.async { self?.seek(event.positionTime) }
                    return .success
                }
            )
        ]
        setRemoteCommandsEnabled(false)
    }

    private func setRemoteCommandsEnabled(_ enabled: Bool) {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = enabled
        commands.pauseCommand.isEnabled = enabled
        commands.togglePlayPauseCommand.isEnabled = enabled
        commands.skipBackwardCommand.isEnabled = enabled
        commands.skipForwardCommand.isEnabled = enabled
        commands.changePlaybackPositionCommand.isEnabled = enabled
    }

    private func updateNowPlayingInfo() {
        guard let player, let currentEntryID else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentTitle ?? "Briefly Audio",
            MPMediaItemPropertyArtist: "Briefly",
            MPMediaItemPropertyAlbumTitle: "Briefly",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime:
                segmentStartTime + player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: currentEntryID
        ]
    }
    #endif
}

private extension Double {
    var nonzero: Double? { self == 0 ? nil : self }
}
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
