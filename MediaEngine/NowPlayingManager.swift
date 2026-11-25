import Foundation
import MediaPlayer
import UIKit

@MainActor
protocol NowPlayingManagerProtocol: AnyObject {
    var onRemotePlay: (@MainActor () -> Void)? { get set }
    var onRemotePause: (@MainActor () -> Void)? { get set }
    var onRemoteTogglePlayPause: (@MainActor () -> Void)? { get set }
    var onRemoteSeek: (@MainActor (TimeInterval) -> Void)? { get set }
    var onRemoteNextTrack: (@MainActor () -> Void)? { get set }
    var onRemotePreviousTrack: (@MainActor () -> Void)? { get set }

    func acquireOwnership(for engine: any PlayerEngineProtocol, video: VideoItem)
    func updatePlaybackStatus(state: PlaybackState, currentTime: TimeInterval, duration: DurationInfo, rate: Float)
    func relinquishOwnership()
}

/// Manages `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` tokens exclusively for native engines.
@MainActor
final class NowPlayingManager: NowPlayingManagerProtocol {
    var onRemotePlay: (@MainActor () -> Void)?
    var onRemotePause: (@MainActor () -> Void)?
    var onRemoteTogglePlayPause: (@MainActor () -> Void)?
    var onRemoteSeek: (@MainActor (TimeInterval) -> Void)?
    var onRemoteNextTrack: (@MainActor () -> Void)?
    var onRemotePreviousTrack: (@MainActor () -> Void)?

    private var commandTokens: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var currentVideoID: String?
    private var currentVideo: VideoItem?
    private var cachedArtwork: MPMediaItemArtwork?
    private var hasOwnership = false

    init() {}

    func acquireOwnership(for engine: any PlayerEngineProtocol, video: VideoItem) {
        guard engine.capabilities.contains(.managesNowPlaying) else {
            relinquishOwnership()
            return
        }

        if hasOwnership {
            unregisterCommands()
        }
        hasOwnership = true
        currentVideo = video

        if currentVideoID != video.id {
            currentVideoID = video.id
            cachedArtwork = nil
            loadArtwork(for: video)
        }

        registerCommands()
        updatePlaybackStatus(
            state: engine.state,
            currentTime: engine.currentTime,
            duration: engine.durationInfo,
            rate: engine.rate
        )
    }

    func updatePlaybackStatus(
        state: PlaybackState,
        currentTime: TimeInterval,
        duration: DurationInfo,
        rate: Float
    ) {
        guard hasOwnership, let video = currentVideo else { return }

        let isPlaying: Bool = {
            if case .playing = state { return true }
            return false
        }()

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: video.title,
            MPMediaItemPropertyArtist: video.channelTitle,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate)
        ]

        switch duration {
        case .finite(let total):
            info[MPMediaItemPropertyPlaybackDuration] = total
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime.isFinite ? max(0, currentTime) : 0
            info[MPNowPlayingInfoPropertyIsLiveStream] = false
        case .live:
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        case .unknown:
            break
        }

        if let cachedArtwork {
            info[MPMediaItemPropertyArtwork] = cachedArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func relinquishOwnership() {
        hasOwnership = false
        artworkTask?.cancel()
        artworkTask = nil
        currentVideoID = nil
        currentVideo = nil
        cachedArtwork = nil
        unregisterCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Private

    private func registerCommands() {
        let cc = MPRemoteCommandCenter.shared()

        func bind(_ cmd: MPRemoteCommand, _ handler: @escaping @MainActor () -> Void) {
            cmd.isEnabled = true
            let token = cmd.addTarget { _ in
                Task { @MainActor in
                    handler()
                }
                return .success
            }
            commandTokens.append((cmd, token))
        }

        bind(cc.playCommand) { [weak self] in self?.onRemotePlay?() }
        bind(cc.pauseCommand) { [weak self] in self?.onRemotePause?() }
        bind(cc.togglePlayPauseCommand) { [weak self] in self?.onRemoteTogglePlayPause?() }

        cc.changePlaybackPositionCommand.isEnabled = true
        let seekToken = cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let pos = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let targetTime = pos.positionTime
            Task { @MainActor [weak self] in
                self?.onRemoteSeek?(targetTime)
            }
            return .success
        }
        commandTokens.append((cc.changePlaybackPositionCommand, seekToken))

        bind(cc.nextTrackCommand) { [weak self] in self?.onRemoteNextTrack?() }
        bind(cc.previousTrackCommand) { [weak self] in self?.onRemotePreviousTrack?() }
    }

    private func unregisterCommands() {
        for (cmd, token) in commandTokens {
            cmd.removeTarget(token)
            cmd.isEnabled = false
        }
        commandTokens.removeAll()
    }

    private func loadArtwork(for video: VideoItem) {
        artworkTask?.cancel()
        guard let url = video.thumbnailURL else { return }
        let targetVideoID = video.id

        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let image = UIImage(data: data) else {
                return
            }
            await MainActor.run {
                guard let self, self.hasOwnership, self.currentVideoID == targetVideoID else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.cachedArtwork = artwork
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}
