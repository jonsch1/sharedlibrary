import AVFoundation
import Foundation
import Observation
#if os(iOS)
import MediaPlayer
#endif

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
