import Foundation
import Observation
import SwiftUI
import UIKit

/// Central coordinator orchestrating dual engines, race-free video loading, SponsorBlock/A-B loop rules, and persistence.
@MainActor
@Observable
final class PlaybackCoordinator {
    // Public observable playback & UI state
    private(set) var currentVideo: VideoItem?
    private(set) var displayMode: PlayerDisplayMode = .hidden
    private(set) var playbackState: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var bufferedTime: TimeInterval = 0
    private(set) var durationInfo: DurationInfo = .unknown
    private(set) var userPreferredRate: Float = 1.0
    private(set) var isTempSpeedBoostActive: Bool = false
    private(set) var activeCapabilities: EngineCapabilities = []
    private(set) var isUsingCompatibilityWebMode: Bool = false

    private(set) var availableQualities: [QualityOption] = []
    private(set) var selectedQuality: QualityOption?
    private(set) var availableAudioTracks: [AudioTrackOption] = []
    private(set) var selectedAudioTrack: AudioTrackOption?

    private(set) var dislikeState: DislikeState = .unavailable
    private(set) var mergedSkipIntervals: [MergedSkipInterval] = []
    private(set) var muteSegments: [SponsorSegment] = []
    private(set) var highlightPoints: [SponsorHighlightPoint] = []
    private(set) var hasFullVideoSponsorBadge: Bool = false
    private(set) var abLoopRange: ABLoopRange?
    private(set) var pendingLoopPointA: TimeInterval?

    // User preferences
    var enabledSponsorCategories: Set<SponsorCategory> = Set(SponsorCategory.allCases) {
        didSet {
            reapplySponsorRules()
        }
    }
    var backgroundAudioEnabled: Bool = true
    var autoPiPEnabled: Bool = true

    // Dependencies
    private let nativeEngine: any PlayerEngineProtocol
    private let webEngine: any PlayerEngineProtocol
    private let resolver: any StreamResolverProtocol
    private let recoveryController: StreamRecoveryController
    private let ruleArbitrator: PlaybackRuleArbitrator
    let queueManager: any QueueManagerProtocol
    private let nowPlayingManager: any NowPlayingManagerProtocol
    private let audioSessionManager: any AudioSessionManagerProtocol
    private let persistence: any PersistenceWorkerProtocol
    private let sponsorBlockClient: any SponsorBlockClientProtocol
    private let returnDislikeClient: any ReturnDislikeClientProtocol

    private var activeEngine: (any PlayerEngineProtocol)?
    private weak var renderSurface: (any PlayerRenderSurfaceProtocol)?

    private var activeLoadID: UUID?
    private var loadTask: Task<Void, Never>?
    private var eventSubscriptionTask: Task<Void, Never>?
    private var communityMetadataTask: Task<Void, Never>?

    private var pendingResumePosition: TimeInterval?
    private var isInitialSeekApplied = false
    private var wasPlayingBeforeInterruption = false
    private var isApplyingAutomatedSeek = false

    private var lastSavedAt: Date = .distantPast
    private var lastSavedPosition: TimeInterval = 0

    init(
        nativeEngine: any PlayerEngineProtocol,
        webEngine: any PlayerEngineProtocol,
        resolver: any StreamResolverProtocol,
        recoveryController: StreamRecoveryController,
        ruleArbitrator: PlaybackRuleArbitrator,
        queueManager: any QueueManagerProtocol,
        nowPlayingManager: any NowPlayingManagerProtocol,
        audioSessionManager: any AudioSessionManagerProtocol,
        persistence: any PersistenceWorkerProtocol,
        sponsorBlockClient: any SponsorBlockClientProtocol,
        returnDislikeClient: any ReturnDislikeClientProtocol
    ) {
        self.nativeEngine = nativeEngine
        self.webEngine = webEngine
        self.resolver = resolver
        self.recoveryController = recoveryController
        self.ruleArbitrator = ruleArbitrator
        self.queueManager = queueManager
        self.nowPlayingManager = nowPlayingManager
        self.audioSessionManager = audioSessionManager
        self.persistence = persistence
        self.sponsorBlockClient = sponsorBlockClient
        self.returnDislikeClient = returnDislikeClient

        if let avEngine = nativeEngine as? AVPlayerEngine {
            avEngine.pipRestoreUIHandler = { [weak self] in
                self?.setDisplayMode(.fullscreen)
            }
        }

        bindAudioSessionCallbacks()
        bindRemoteCommandCallbacks()
        audioSessionManager.startObserving()
    }

    func attachRenderSurface(_ surface: (any PlayerRenderSurfaceProtocol)?) {
        renderSurface = surface
        if let activeEngine {
            let surfaceType: ActiveRenderSurface = (activeEngine === nativeEngine) ? .avPlayerLayer : .webView
            surface?.setActiveSurface(surfaceType)
            activeEngine.attachRenderSurface(surface)
        }
    }

    func playQueue(_ items: [VideoItem], startIndex: Int) {
        queueManager.replaceQueue(with: items, startIndex: startIndex)
        if let selected = queueManager.currentItem {
            play(video: selected)
        }
    }

    func play(video: VideoItem) {
        // 1. Cancel any prior loading & observation tasks immediately.
        loadTask?.cancel()
        eventSubscriptionTask?.cancel()
        communityMetadataTask?.cancel()

        // 2. Issue fresh generation token and reset active engine synchronously.
        let loadID = UUID()
        activeLoadID = loadID
        currentVideo = video
        playbackState = .loading(loadID: loadID)
        currentTime = 0
        bufferedTime = 0
        durationInfo = video.duration.map { .finite($0) } ?? .unknown
        dislikeState = .loading
        mergedSkipIntervals = []
        muteSegments = []
        highlightPoints = []
        hasFullVideoSponsorBadge = false
        abLoopRange = nil
        pendingLoopPointA = nil
        pendingResumePosition = nil
        isInitialSeekApplied = false
        isTempSpeedBoostActive = false

        activeEngine?.stopAndClear()
        ruleArbitrator.reset()
        recoveryController.reset(for: video.id)

        if displayMode == .hidden || displayMode == .miniPlayer {
            displayMode = .inline
        }

        // 3. Kick off primary playback load.
        let streamResolver = self.resolver
        let persistenceWorker = self.persistence
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let sourceTask = streamResolver.resolve(video: video, bypassCache: false)
                async let savedPosTask = try? persistenceWorker.fetchWatchPosition(videoId: video.id)

                let source = try await sourceTask
                try Task.checkCancellation()
                guard self.activeLoadID == loadID else { return }

                let savedPosition = await savedPosTask
                try Task.checkCancellation()
                guard self.activeLoadID == loadID else { return }

                try? audioSessionManager.configurePlaybackSession()
                await switchActiveEngine(for: source, isFallbackTeardown: false)
                guard !Task.isCancelled, self.activeLoadID == loadID else { return }

                var initialSeek: TimeInterval?
                if let savedPosition, savedPosition > 3.0 {
                    if let knownDuration = video.duration, knownDuration.isFinite {
                        if savedPosition < knownDuration - 5.0 {
                            initialSeek = savedPosition
                            isInitialSeekApplied = true
                        }
                    } else {
                        pendingResumePosition = savedPosition
                    }
                }

                guard let engine = self.activeEngine else { return }
                try await engine.load(source: source, startAt: initialSeek)
                try Task.checkCancellation()
                guard self.activeLoadID == loadID else { return }

                engine.setRate(isTempSpeedBoostActive ? 2.0 : userPreferredRate)
                engine.play()

                if engine.capabilities.contains(.managesNowPlaying) {
                    nowPlayingManager.acquireOwnership(for: engine, video: video)
                }
                syncEngineMetadata(from: engine)
            } catch is CancellationError {
                return
            } catch let playbackErr as PlaybackError {
                guard self.activeLoadID == loadID else { return }
                self.playbackState = .failed(playbackErr)
            } catch {
                guard self.activeLoadID == loadID else { return }
                self.playbackState = .failed(.sourceResolutionFailed(error.localizedDescription))
            }
        }

        // 4. Kick off non-blocking SponsorBlock & RYD lookups in parallel.
        let sbClient = self.sponsorBlockClient
        let rydClient = self.returnDislikeClient
        let categories = Array(self.enabledSponsorCategories)
        communityMetadataTask = Task { [weak self] in
            guard let self else { return }
            async let segmentsTask = sbClient.fetchSegments(
                for: video.id,
                categories: categories
            )
            async let dislikeTask = rydClient.fetchMetrics(for: video.id)

            let (segments, dislike) = await (segmentsTask, dislikeTask)
            guard !Task.isCancelled, self.activeLoadID == loadID else { return }

            self.dislikeState = dislike
            self.ruleArbitrator.configure(segments: segments, enabledCategories: self.enabledSponsorCategories)
            self.syncArbitratorStateToUI()
            self.refreshBoundaryObservers()
            await self.syncMuteState(at: self.currentTime)
        }
    }

    // MARK: - Controls

    func togglePlayPause() {
        guard let engine = activeEngine else { return }
        if case .playing = playbackState {
            pause(reason: .user)
        } else {
            try? audioSessionManager.activateSession()
            engine.play()
        }
    }

    func playActive() {
        try? audioSessionManager.activateSession()
        activeEngine?.play()
    }

    func pause(reason: PauseReason = .user) {
        activeEngine?.pause(reason: reason)
        flushProgressToDisk()
    }

    func seek(to time: TimeInterval, isManual: Bool = true) async {
        guard let engine = activeEngine else { return }
        let clamped = max(0, time.isFinite ? time : 0)
        if isManual {
            ruleArbitrator.notifyManualSeek(to: clamped)
        }
        await engine.seek(to: clamped, precision: .exact)
        currentTime = clamped
        await syncMuteState(at: clamped)
        if let currentVideo {
            nowPlayingManager.updatePlaybackStatus(
                state: playbackState,
                currentTime: clamped,
                duration: durationInfo,
                rate: isTempSpeedBoostActive ? 2.0 : userPreferredRate
            )
            _ = currentVideo
        }
        flushProgressToDisk()
    }

    func seekRelative(_ delta: TimeInterval) async {
        let maxTime = durationInfo.finiteSeconds ?? .greatestFiniteMagnitude
        let target = min(max(0, currentTime + delta), maxTime)
        await seek(to: target, isManual: true)
    }

    func setUserPreferredRate(_ newRate: Float) {
        userPreferredRate = min(max(newRate, 0.25), 3.0)
        if !isTempSpeedBoostActive {
            activeEngine?.setRate(userPreferredRate)
            nowPlayingManager.updatePlaybackStatus(
                state: playbackState,
                currentTime: currentTime,
                duration: durationInfo,
                rate: userPreferredRate
            )
        }
    }

    func setTemporarySpeedBoost(_ active: Bool) {
        isTempSpeedBoostActive = active
        let appliedRate = active ? 2.0 : userPreferredRate
        activeEngine?.setRate(appliedRate)
        nowPlayingManager.updatePlaybackStatus(
            state: playbackState,
            currentTime: currentTime,
            duration: durationInfo,
            rate: appliedRate
        )
    }

    func selectQuality(_ quality: QualityOption) async {
        try? await activeEngine?.selectQuality(quality)
        if let activeEngine {
            syncEngineMetadata(from: activeEngine)
        }
    }

    func selectAudioTrack(_ track: AudioTrackOption) async {
        try? await activeEngine?.selectAudioTrack(track)
        if let activeEngine {
            syncEngineMetadata(from: activeEngine)
        }
    }

    func startPiP() {
        activeEngine?.startPiP()
    }

    func stop() {
        loadTask?.cancel()
        eventSubscriptionTask?.cancel()
        communityMetadataTask?.cancel()
        flushProgressToDisk()
        activeLoadID = nil
        activeEngine?.stopAndClear()
        nowPlayingManager.relinquishOwnership()
        ruleArbitrator.reset()
        currentVideo = nil
        playbackState = .idle
        displayMode = .hidden
        Task {
            await OrientationManager.shared.setFullscreen(false)
        }
    }

    func setDisplayMode(_ newMode: PlayerDisplayMode) {
        let wasFullscreen = (displayMode == .fullscreen)
        displayMode = newMode
        if newMode == .fullscreen && !wasFullscreen {
            Task {
                await OrientationManager.shared.setFullscreen(true)
            }
        } else if newMode != .fullscreen && wasFullscreen {
            Task {
                await OrientationManager.shared.setFullscreen(false)
            }
        }
    }

    // MARK: - A-B Loop

    func setPointA(_ time: TimeInterval? = nil) {
        let a = time ?? currentTime
        pendingLoopPointA = max(0, a)
        abLoopRange = nil
        ruleArbitrator.abLoopRange = nil
        refreshBoundaryObservers()
    }

    func setPointB(_ time: TimeInterval? = nil) {
        let b = time ?? currentTime
        guard let a = pendingLoopPointA,
              let validRange = ABLoopRange(pointA: a, pointB: b) else {
            return
        }
        abLoopRange = validRange
        ruleArbitrator.abLoopRange = validRange
        refreshBoundaryObservers()
    }

    func clearABLoop() {
        pendingLoopPointA = nil
        abLoopRange = nil
        ruleArbitrator.abLoopRange = nil
        refreshBoundaryObservers()
    }

    func playNextInQueue() {
        if let next = queueManager.advanceToNext() {
            play(video: next)
        }
    }

    func playPreviousInQueue() {
        switch queueManager.previousAction(currentPlaybackTime: currentTime) {
        case .restartCurrent:
            Task { await seek(to: 0, isManual: true) }
        case .playPrevious(let video):
            play(video: video)
        case .none:
            break
        }
    }

    // MARK: - Lifecycle & Persistence

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            activeEngine?.handleBackgroundTransition(
                backgroundAudioEnabled: backgroundAudioEnabled,
                autoPiPEnabled: autoPiPEnabled
            )
            flushProgressWithBackgroundTask()
        case .active:
            activeEngine?.handleForegroundTransition()
        case .inactive:
            flushProgressToDisk()
        @unknown default:
            break
        }
    }

    func flushProgressToDisk() {
        guard let video = currentVideo else { return }
        let safePos = currentTime.isFinite ? max(0, currentTime) : 0
        let safeDur = (durationInfo.finiteSeconds ?? video.duration ?? 0)
        let dto = WatchHistoryDTO(
            videoId: video.id,
            title: video.title,
            channelId: video.channelId,
            channelName: video.channelTitle,
            lastPosition: safePos,
            duration: safeDur.isFinite ? safeDur : 0,
            watchedAt: .now
        )
        lastSavedAt = .now
        lastSavedPosition = safePos
        Task {
            try? await persistence.upsertWatchHistory(dto)
        }
    }

    private func flushProgressWithBackgroundTask() {
        guard let video = currentVideo else { return }
        let safePos = currentTime.isFinite ? max(0, currentTime) : 0
        let safeDur = (durationInfo.finiteSeconds ?? video.duration ?? 0)
        let dto = WatchHistoryDTO(
            videoId: video.id,
            title: video.title,
            channelId: video.channelId,
            channelName: video.channelTitle,
            lastPosition: safePos,
            duration: safeDur.isFinite ? safeDur : 0,
            watchedAt: .now
        )
        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "FlushPlaybackProgress") {
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
        }
        Task {
            try? await persistence.upsertWatchHistory(dto)
            await MainActor.run {
                if bgTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskId)
                    bgTaskId = .invalid
                }
            }
        }
    }

    // MARK: - Dual Engine Switching & Events

    private func switchActiveEngine(for source: PlayableSource, isFallbackTeardown: Bool) async {
        let targetEngine: any PlayerEngineProtocol = source.isDirect ? nativeEngine : webEngine
        let targetSurface: ActiveRenderSurface = source.isDirect ? .avPlayerLayer : .webView
        isUsingCompatibilityWebMode = !source.isDirect

        if activeEngine !== targetEngine {
            if let previousEngine = activeEngine {
                if isFallbackTeardown {
                    await previousEngine.teardown()
                } else {
                    previousEngine.stopAndClear()
                }
            }
            nowPlayingManager.relinquishOwnership()
            renderSurface?.setActiveSurface(targetSurface)
            targetEngine.attachRenderSurface(renderSurface)
            activeEngine = targetEngine
            subscribeToEngineEvents(targetEngine)
        } else {
            renderSurface?.setActiveSurface(targetSurface)
            targetEngine.attachRenderSurface(renderSurface)
        }

        activeCapabilities = targetEngine.capabilities
        if let video = currentVideo, targetEngine.capabilities.contains(.managesNowPlaying) {
            nowPlayingManager.acquireOwnership(for: targetEngine, video: video)
        }
    }

    private func subscribeToEngineEvents(_ engine: any PlayerEngineProtocol) {
        eventSubscriptionTask?.cancel()
        let loadIDSnapshot = activeLoadID
        let stream = engine.eventStream()

        eventSubscriptionTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                guard let self, self.activeLoadID == loadIDSnapshot else { break }
                await self.handleEngineEvent(event)
            }
        }
    }

    private func handleEngineEvent(_ event: PlaybackEngineEvent) async {
        switch event {
        case .stateChanged(let newState):
            playbackState = newState
            if case .failed(let err) = newState {
                await triggerRecoveryIfEligible(error: err)
            } else {
                nowPlayingManager.updatePlaybackStatus(
                    state: newState,
                    currentTime: currentTime,
                    duration: durationInfo,
                    rate: isTempSpeedBoostActive ? 2.0 : userPreferredRate
                )
            }

        case .timeUpdated(let time, let buffered):
            currentTime = time
            bufferedTime = buffered
            maybeThrottleSaveHistory(at: time)

        case .durationChanged(let newDuration):
            durationInfo = newDuration
            if !isInitialSeekApplied,
               let pendingPos = pendingResumePosition,
               let finiteDur = newDuration.finiteSeconds {
                isInitialSeekApplied = true
                pendingResumePosition = nil
                if pendingPos > 3.0 && pendingPos < (finiteDur - 5.0) {
                    await seek(to: pendingPos, isManual: false)
                }
            }
            if let engine = activeEngine {
                syncEngineMetadata(from: engine)
            }
            nowPlayingManager.updatePlaybackStatus(
                state: playbackState,
                currentTime: currentTime,
                duration: newDuration,
                rate: isTempSpeedBoostActive ? 2.0 : userPreferredRate
            )

        case .didPlayToEnd:
            let action = ruleArbitrator.handleDidPlayToEnd(duration: durationInfo.finiteSeconds)
            if case .seekTo(let target, _) = action {
                await performAutomatedSeek(to: target)
                activeEngine?.play()
            } else if let next = queueManager.advanceToNext() {
                play(video: next)
            }

        case .streamLikelyExpired(let statusCode):
            await triggerRecoveryIfEligible(error: .streamExpired(httpStatus: statusCode))

        case .pipStateChanged:
            break
        }
    }

    private func triggerRecoveryIfEligible(error: PlaybackError) async {
        guard let video = currentVideo,
              activeEngine === nativeEngine else {
            return
        }
        let loadIDSnapshot = activeLoadID
        let resumeTime = max(currentTime, activeEngine?.currentTime ?? 0)
        let decision = await recoveryController.attemptRecovery(
            for: video,
            lastKnownTime: resumeTime,
            triggerError: error
        )
        guard activeLoadID == loadIDSnapshot else { return }

        switch decision {
        case .retryDirect(let source, let resumeAt):
            try? await nativeEngine.load(source: source, startAt: resumeAt)
            guard activeLoadID == loadIDSnapshot else { return }
            nativeEngine.setRate(isTempSpeedBoostActive ? 2.0 : userPreferredRate)
            nativeEngine.play()

        case .fallbackToWebEmbed(let webSource, let resumeAt):
            await switchActiveEngine(for: webSource, isFallbackTeardown: true)
            guard activeLoadID == loadIDSnapshot else { return }
            try? await webEngine.load(source: webSource, startAt: resumeAt)
            guard activeLoadID == loadIDSnapshot else { return }
            webEngine.setRate(isTempSpeedBoostActive ? 2.0 : userPreferredRate)
            webEngine.play()

        case .giveUp(let finalError):
            playbackState = .failed(finalError)
        }
    }

    private func refreshBoundaryObservers() {
        let times = ruleArbitrator.allBoundaryTimes()
        activeEngine?.updateBoundaryObservers(times: times) { [weak self] crossedTime in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.handleBoundaryCrossed(at: crossedTime)
            }
        }
    }

    private func handleBoundaryCrossed(at crossedTime: TimeInterval) async {
        guard !isApplyingAutomatedSeek else { return }
        let actions = ruleArbitrator.evaluateBoundaryCrossed(at: crossedTime)
        for action in actions {
            switch action {
            case .none:
                break
            case .seekTo(let target, _):
                await performAutomatedSeek(to: target)
            case .setSystemMute(let shouldMute):
                activeEngine?.setMuted(shouldMute)
            }
        }
    }

    private func performAutomatedSeek(to target: TimeInterval) async {
        isApplyingAutomatedSeek = true
        defer { isApplyingAutomatedSeek = false }
        await activeEngine?.seek(to: target, precision: .exact)
        currentTime = target
        await syncMuteState(at: target)
    }

    private func syncMuteState(at time: TimeInterval) async {
        if case .setSystemMute(let muted) = ruleArbitrator.evaluateMuteState(at: time) {
            activeEngine?.setMuted(muted)
        } else {
            activeEngine?.setMuted(ruleArbitrator.isSystemMutedBySponsor)
        }
    }

    private func reapplySponsorRules() {
        guard let currentVideo else { return }
        let loadIDSnapshot = activeLoadID
        Task { [weak self] in
            guard let self else { return }
            let segments = await sponsorBlockClient.fetchSegments(
                for: currentVideo.id,
                categories: Array(enabledSponsorCategories)
            )
            guard self.activeLoadID == loadIDSnapshot else { return }
            self.ruleArbitrator.configure(segments: segments, enabledCategories: self.enabledSponsorCategories)
            self.syncArbitratorStateToUI()
            self.refreshBoundaryObservers()
            await self.syncMuteState(at: self.currentTime)
        }
    }

    private func syncArbitratorStateToUI() {
        mergedSkipIntervals = ruleArbitrator.mergedSkipIntervals
        muteSegments = ruleArbitrator.muteSegments
        highlightPoints = ruleArbitrator.highlightPoints
        hasFullVideoSponsorBadge = ruleArbitrator.hasFullVideoSponsor
    }

    private func syncEngineMetadata(from engine: any PlayerEngineProtocol) {
        availableQualities = engine.availableQualities
        selectedQuality = engine.selectedQuality
        availableAudioTracks = engine.availableAudioTracks
        selectedAudioTrack = engine.selectedAudioTrack
    }

    private func maybeThrottleSaveHistory(at time: TimeInterval) {
        let now = Date()
        guard now.timeIntervalSince(lastSavedAt) >= 10.0,
              abs(time - lastSavedPosition) >= 5.0 else {
            return
        }
        flushProgressToDisk()
    }

    private func bindAudioSessionCallbacks() {
        audioSessionManager.onInterruptionBegan = { [weak self] in
            guard let self else { return }
            if case .playing = self.playbackState {
                self.wasPlayingBeforeInterruption = true
            } else if case .buffering(let wasPlaying) = self.playbackState {
                self.wasPlayingBeforeInterruption = wasPlaying
            } else {
                self.wasPlayingBeforeInterruption = false
            }
            self.activeEngine?.pause(reason: .audioSessionInterruption)
        }

        audioSessionManager.onInterruptionEndedShouldResume = { [weak self] in
            guard let self, self.wasPlayingBeforeInterruption else { return }
            self.wasPlayingBeforeInterruption = false
            self.activeEngine?.play()
        }

        audioSessionManager.onRouteDisconnected = { [weak self] in
            self?.wasPlayingBeforeInterruption = false
            self?.activeEngine?.pause(reason: .audioRouteDisconnected)
        }

        audioSessionManager.onMediaServicesReset = { [weak self] in
            guard let self else { return }
            if let avEngine = self.nativeEngine as? AVPlayerEngine {
                avEngine.rebuildAfterMediaServicesReset()
            }
            if let video = self.currentVideo {
                let resumeTime = self.currentTime
                self.play(video: video)
                if resumeTime > 1.0 {
                    self.pendingResumePosition = resumeTime
                    self.isInitialSeekApplied = false
                }
            }
        }
    }

    private func bindRemoteCommandCallbacks() {
        nowPlayingManager.onRemotePlay = { [weak self] in self?.playActive() }
        nowPlayingManager.onRemotePause = { [weak self] in self?.pause(reason: .user) }
        nowPlayingManager.onRemoteTogglePlayPause = { [weak self] in self?.togglePlayPause() }
        nowPlayingManager.onRemoteSeek = { [weak self] time in
            Task { @MainActor [weak self] in
                await self?.seek(to: time, isManual: true)
            }
        }
        nowPlayingManager.onRemoteNextTrack = { [weak self] in self?.playNextInQueue() }
        nowPlayingManager.onRemotePreviousTrack = { [weak self] in self?.playPreviousInQueue() }
    }
}
