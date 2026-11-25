@preconcurrency import AVFoundation
import AVKit
import Foundation
import os

/// Native `AVPlayer` engine supporting HLS/MP4 playback, strict concurrency observers, and PiP.
@MainActor
final class AVPlayerEngine: NSObject, PlayerEngineProtocol, AVPictureInPictureControllerDelegate {
    let capabilities: EngineCapabilities = [
        .arbitraryPlaybackRate,
        .nativePiP,
        .backgroundAudio,
        .qualitySelection,
        .audioTrackSelection,
        .precisionBoundaries,
        .managesNowPlaying
    ]

    private(set) var state: PlaybackState = .idle {
        didSet {
            guard oldValue != state else { return }
            broadcaster.send(.stateChanged(state))
        }
    }
    private(set) var currentTime: TimeInterval = 0
    private(set) var bufferedTime: TimeInterval = 0
    private(set) var durationInfo: DurationInfo = .unknown {
        didSet {
            guard oldValue != durationInfo else { return }
            broadcaster.send(.durationChanged(durationInfo))
        }
    }
    private(set) var rate: Float = 1.0
    private(set) var availableQualities: [QualityOption] = [
        QualityOption(id: "auto", label: "자동", height: 0, fps: 0, codec: "auto"),
        QualityOption(id: "1080p", label: "1080p", height: 1080, fps: 60, codec: "h264"),
        QualityOption(id: "720p", label: "720p", height: 720, fps: 60, codec: "h264"),
        QualityOption(id: "480p", label: "480p", height: 480, fps: 30, codec: "h264")
    ]
    private(set) var selectedQuality: QualityOption?
    private(set) var availableAudioTracks: [AudioTrackOption] = []
    private(set) var selectedAudioTrack: AudioTrackOption?

    /// Optional UI hook called before completing PiP UI restoration.
    var pipRestoreUIHandler: (@MainActor () async -> Void)?

    private var player: AVPlayer
    private weak var renderSurface: (any PlayerRenderSurfaceProtocol)?
    private var pipController: AVPictureInPictureController?
    private let broadcaster = EngineEventBroadcaster()

    private var periodicTimeObserver: Any?
    private var boundaryTimeObserver: Any?
    private var registeredBoundaries: [TimeInterval] = []
    private var boundaryCallback: (@MainActor (TimeInterval) -> Void)?

    private var playerObservers: [NSKeyValueObservation] = []
    private var itemObservers: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var activeLoadID = UUID()
    private var intendedToPlay = false
    private var isPiPActive = false

    override init() {
        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player
        super.init()
        self.selectedQuality = availableQualities.first
        installPlayerObservers()
    }

    func eventStream() -> AsyncStream<PlaybackEngineEvent> {
        broadcaster.makeStream()
    }

    func attachRenderSurface(_ surface: (any PlayerRenderSurfaceProtocol)?) {
        renderSurface = surface
        if let surface {
            surface.playerLayer.player = player
            setupPiPIfPossible(for: surface.playerLayer)
        } else {
            pipController = nil
        }
    }

    func load(source: PlayableSource, startAt: TimeInterval?) async throws {
        guard case .direct(let url, _, let headers) = source else {
            throw PlaybackError.sourceResolutionFailed("AVPlayerEngine requires a .direct PlayableSource")
        }

        let loadID = UUID()
        activeLoadID = loadID
        cleanupCurrentItemObservers()
        clearBoundaryObserver()

        state = .loading(loadID: loadID)
        currentTime = 0
        bufferedTime = 0
        durationInfo = .unknown
        availableAudioTracks = []
        selectedAudioTrack = nil

        var assetOptions: [String: Any] = [:]
        if !headers.isEmpty {
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: assetOptions)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 10
        item.audioTimePitchAlgorithm = .timeDomain
        if let maxHeight = selectedQuality?.height, maxHeight > 0 {
            item.preferredMaximumResolution = CGSize(width: Double(maxHeight) * 16.0 / 9.0, height: Double(maxHeight))
        }

        installItemObservers(for: item, loadID: loadID)
        player.replaceCurrentItem(with: item)

        // Load audio tracks asynchronously without blocking playback setup.
        Task { @MainActor [weak self, weak asset] in
            guard let self, let asset, self.activeLoadID == loadID else { return }
            if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
                guard self.activeLoadID == loadID else { return }
                let tracks = group.options.enumerated().map { idx, opt in
                    AudioTrackOption(
                        id: "\(idx):\(opt.displayName)",
                        languageCode: opt.extendedLanguageTag ?? "und",
                        displayName: opt.displayName
                    )
                }
                self.availableAudioTracks = tracks
                let currentOpt = item.currentMediaSelection.selectedMediaOption(in: group)
                self.selectedAudioTrack = tracks.first { $0.displayName == currentOpt?.displayName } ?? tracks.first
            }
        }

        if let startAt, startAt.isFinite, startAt > 0 {
            await seek(to: startAt, precision: .exact)
        }
    }

    func stopAndClear() {
        activeLoadID = UUID()
        intendedToPlay = false
        player.pause()
        clearBoundaryObserver()
        cleanupCurrentItemObservers()
        player.replaceCurrentItem(with: nil)
        currentTime = 0
        bufferedTime = 0
        durationInfo = .unknown
        state = .idle
    }

    func play() {
        intendedToPlay = true
        player.playImmediately(atRate: rate)
        if player.timeControlStatus == .playing {
            state = .playing
        }
    }

    func pause(reason: PauseReason) {
        intendedToPlay = false
        player.pause()
        state = .paused(reason: reason)
    }

    @discardableResult
    func seek(to time: TimeInterval, precision: SeekPrecision) async -> Bool {
        let clamped = max(0, time.isFinite ? time : 0)
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        let tolerance: CMTime = precision == .exact
            ? .zero
            : CMTime(seconds: 0.5, preferredTimescale: 600)

        let resumeGuard = OSAllocatedUnfairLock(initialState: false)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                player.seek(to: cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                    let alreadyResumed = resumeGuard.withLock { done -> Bool in
                        if done { return true }
                        done = true
                        return false
                    }
                    if !alreadyResumed {
                        continuation.resume(returning: finished)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.player.currentItem?.cancelPendingSeeks()
            }
        }
    }

    func setRate(_ newRate: Float) {
        let clamped = min(max(newRate, 0.25), 3.0)
        rate = clamped
        if intendedToPlay || player.timeControlStatus == .playing {
            player.rate = clamped
        }
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    func selectQuality(_ quality: QualityOption) async throws {
        selectedQuality = quality
        guard let item = player.currentItem else { return }
        if quality.height > 0 {
            item.preferredMaximumResolution = CGSize(
                width: Double(quality.height) * 16.0 / 9.0,
                height: Double(quality.height)
            )
        } else {
            item.preferredMaximumResolution = .zero
        }
    }

    func selectAudioTrack(_ track: AudioTrackOption) async throws {
        guard let item = player.currentItem,
              let group = try await item.asset.loadMediaSelectionGroup(for: .audible) else {
            return
        }
        if let option = group.options.first(where: { $0.displayName == track.displayName }) {
            item.select(option, in: group)
            selectedAudioTrack = track
        }
    }

    func updateBoundaryObservers(
        times: [TimeInterval],
        onCrossed: @escaping @MainActor (TimeInterval) -> Void
    ) {
        clearBoundaryObserver()
        let sanitized = times.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sanitized.isEmpty else { return }

        registeredBoundaries = sanitized
        boundaryCallback = onCrossed

        let nsValues = sanitized.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
        boundaryTimeObserver = player.addBoundaryTimeObserver(forTimes: nsValues, queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = self.player.currentTime().seconds
                guard now.isFinite else { return }
                if let matched = self.registeredBoundaries.min(by: { abs($0 - now) < abs($1 - now) }),
                   abs(matched - now) <= 0.25 {
                    self.boundaryCallback?(matched)
                }
            }
        }
    }

    func startPiP() {
        guard let pipController, pipController.isPictureInPicturePossible else { return }
        pipController.startPictureInPicture()
    }

    func stopPiP() {
        guard let pipController, pipController.isPictureInPictureActive else { return }
        pipController.stopPictureInPicture()
    }

    func handleBackgroundTransition(backgroundAudioEnabled: Bool, autoPiPEnabled: Bool) {
        // Keep playerLayer connected if PiP is active or armed for inline automatic PiP.
        guard !autoPiPEnabled && !isPiPActive else { return }
        if backgroundAudioEnabled {
            renderSurface?.playerLayer.player = nil
        } else if intendedToPlay {
            pause(reason: .user)
        }
    }

    func handleForegroundTransition() {
        if let surface = renderSurface, surface.playerLayer.player !== player {
            surface.playerLayer.player = player
        }
    }

    func teardown() async {
        stopPiP()
        stopAndClear()
        removePlayerObservers()
        pipController = nil
        renderSurface?.playerLayer.player = nil
        broadcaster.finishAll()
    }

    /// Rebuilds the underlying `AVPlayer` instance after `mediaServicesWereResetNotification`.
    func rebuildAfterMediaServicesReset() {
        removePlayerObservers()
        clearBoundaryObserver()
        cleanupCurrentItemObservers()

        let fresh = AVPlayer()
        fresh.automaticallyWaitsToMinimizeStalling = true
        player = fresh
        installPlayerObservers()
        if let surface = renderSurface {
            surface.playerLayer.player = fresh
            setupPiPIfPossible(for: surface.playerLayer)
        }
    }

    // MARK: - AVPictureInPictureControllerDelegate

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let isPossible = pictureInPictureController.isPictureInPicturePossible
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPiPActive = true
            self.broadcaster.send(.pipStateChanged(isActive: true, isPossible: isPossible))
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let isPossible = pictureInPictureController.isPictureInPicturePossible
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPiPActive = false
            self.broadcaster.send(.pipStateChanged(isActive: false, isPossible: isPossible))
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        let completedLock = OSAllocatedUnfairLock(initialState: false)
        let finishOnce: @Sendable (Bool) -> Void = { restored in
            let alreadyDone = completedLock.withLock { done -> Bool in
                if done { return true }
                done = true
                return false
            }
            if !alreadyDone {
                completionHandler(restored)
            }
        }

        // 0.5s watchdog guarantees completionHandler is always called once.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            finishOnce(true)
            _ = self
        }

        Task { @MainActor [weak self] in
            await self?.pipRestoreUIHandler?()
            finishOnce(true)
        }
    }

    // MARK: - Private Observers

    private func setupPiPIfPossible(for layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            pipController = nil
            return
        }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller
    }

    private func installPlayerObservers() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        periodicTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] cmTime in
            let seconds = cmTime.seconds
            MainActor.assumeIsolated {
                guard let self, seconds.isFinite else { return }
                self.currentTime = max(0, seconds)
                self.broadcaster.send(.timeUpdated(currentTime: self.currentTime, bufferedTime: self.bufferedTime))
            }
        }

        let tcObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            let status = observedPlayer.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .playing:
                    self.state = .playing
                case .waitingToPlayAtSpecifiedRate:
                    if self.intendedToPlay {
                        self.state = .buffering(wasPlaying: true)
                    }
                case .paused:
                    if case .playing = self.state {
                        self.state = .paused(reason: .user)
                    } else if case .buffering = self.state, !self.intendedToPlay {
                        self.state = .paused(reason: .user)
                    }
                @unknown default:
                    break
                }
            }
        }
        playerObservers.append(tcObs)
    }

    private func removePlayerObservers() {
        if let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
            self.periodicTimeObserver = nil
        }
        playerObservers.forEach { $0.invalidate() }
        playerObservers.removeAll()
    }

    private func clearBoundaryObserver() {
        if let boundaryTimeObserver {
            player.removeTimeObserver(boundaryTimeObserver)
            self.boundaryTimeObserver = nil
        }
        registeredBoundaries.removeAll()
        boundaryCallback = nil
    }

    private func installItemObservers(for item: AVPlayerItem, loadID: UUID) {
        let statusObs = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            let rawDuration = observedItem.duration
            let seekableRange = observedItem.seekableTimeRanges.first?.timeRangeValue.letRange()
            let nsErr = observedItem.error as NSError?
            let errDomain = nsErr?.domain
            let errCode = nsErr?.code
            let errMessage = nsErr?.localizedDescription

            Task { @MainActor [weak self] in
                guard let self, self.activeLoadID == loadID else { return }
                switch status {
                case .readyToPlay:
                    self.updateDuration(from: rawDuration, seekableRange: seekableRange)
                    if self.intendedToPlay {
                        self.player.playImmediately(atRate: self.rate)
                    }
                case .failed:
                    if let code = errCode, code == 403 || code == 410 || code == -12660 || code == -12938 {
                        self.broadcaster.send(.streamLikelyExpired(httpStatus: code == 410 ? 410 : 403))
                    } else {
                        self.state = .failed(
                            .playbackFailed(
                                domain: errDomain ?? "AVFoundation",
                                code: errCode ?? -1,
                                message: errMessage ?? "재생에 실패했습니다."
                            )
                        )
                    }
                default:
                    break
                }
            }
        }
        itemObservers.append(statusObs)

        let bufferObs = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] observedItem, _ in
            let lastEnd = observedItem.loadedTimeRanges.last?.timeRangeValue.end.seconds
            Task { @MainActor [weak self] in
                guard let self, self.activeLoadID == loadID, let lastEnd, lastEnd.isFinite else { return }
                self.bufferedTime = max(0, lastEnd)
            }
        }
        itemObservers.append(bufferObs)

        let nc = NotificationCenter.default
        notificationTokens.append(
            nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.activeLoadID == loadID else { return }
                    self.state = .ended
                    self.broadcaster.send(.didPlayToEnd)
                }
            }
        )

        notificationTokens.append(
            nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                let code = err?.code ?? -1
                let domain = err?.domain ?? "AVFoundation"
                let message = err?.localizedDescription ?? "재생이 중단되었습니다."
                MainActor.assumeIsolated {
                    guard let self, self.activeLoadID == loadID else { return }
                    if code == 403 || code == 410 || code == -12660 || code == -12938 {
                        self.broadcaster.send(.streamLikelyExpired(httpStatus: code == 410 ? 410 : 403))
                    } else {
                        self.state = .failed(.playbackFailed(domain: domain, code: code, message: message))
                    }
                }
            }
        )

        notificationTokens.append(
            nc.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) { [weak self] note in
                let lastStatus = (note.object as? AVPlayerItem)?.errorLog()?.events.last?.errorStatusCode
                MainActor.assumeIsolated {
                    guard let self, self.activeLoadID == loadID, let lastStatus else { return }
                    if lastStatus == 403 || lastStatus == 410 || lastStatus == 416 {
                        self.broadcaster.send(.streamLikelyExpired(httpStatus: lastStatus))
                    }
                }
            }
        )
    }

    private func updateDuration(from cmTime: CMTime, seekableRange: ClosedRange<TimeInterval>?) {
        if cmTime.isIndefinite || !cmTime.seconds.isFinite {
            durationInfo = .live(seekableRange: seekableRange)
        } else if cmTime.seconds > 0 {
            durationInfo = .finite(cmTime.seconds)
        } else {
            durationInfo = .unknown
        }
    }

    private func cleanupCurrentItemObservers() {
        itemObservers.forEach { $0.invalidate() }
        itemObservers.removeAll()
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
    }
}

private extension CMTimeRange {
    func letRange() -> ClosedRange<TimeInterval>? {
        let lower = start.seconds
        let upper = end.seconds
        guard lower.isFinite, upper.isFinite, upper > lower else { return nil }
        return lower...upper
    }
}
