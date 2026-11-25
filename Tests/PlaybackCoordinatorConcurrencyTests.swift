import AVFoundation
import Foundation
import UIKit
import WebKit
import XCTest
@testable import YouTubeAdvanced

@MainActor
private final class MockPlayerEngine: PlayerEngineProtocol {
    let capabilities: EngineCapabilities
    var state: PlaybackState = .idle
    var currentTime: TimeInterval = 0
    var bufferedTime: TimeInterval = 0
    var durationInfo: DurationInfo = .unknown
    var rate: Float = 1.0
    var availableQualities: [QualityOption] = []
    var selectedQuality: QualityOption?
    var availableAudioTracks: [AudioTrackOption] = []
    var selectedAudioTrack: AudioTrackOption?

    private let broadcaster = EngineEventBroadcaster()

    var loadedSources: [(PlayableSource, TimeInterval?)] = []
    var seekHistory: [TimeInterval] = []
    var stopCallCount = 0
    var teardownCallCount = 0
    var onEventLog: ((String) -> Void)?

    init(capabilities: EngineCapabilities) {
        self.capabilities = capabilities
    }

    func eventStream() -> AsyncStream<PlaybackEngineEvent> {
        broadcaster.makeStream()
    }

    func attachRenderSurface(_ surface: (any PlayerRenderSurfaceProtocol)?) {}

    func load(source: PlayableSource, startAt: TimeInterval?) async throws {
        loadedSources.append((source, startAt))
        if let startAt {
            currentTime = startAt
        }
        state = .playing
        broadcaster.send(.stateChanged(.playing))
    }

    func stopAndClear() {
        stopCallCount += 1
        onEventLog?("stopAndClear:\(capabilities.contains(.managesNowPlaying) ? "native" : "web")")
        state = .idle
    }

    func play() {
        state = .playing
        broadcaster.send(.stateChanged(.playing))
    }

    func pause(reason: PauseReason) {
        state = .paused(reason: reason)
        broadcaster.send(.stateChanged(.paused(reason: reason)))
    }

    func seek(to time: TimeInterval, precision: SeekPrecision) async -> Bool {
        currentTime = time
        seekHistory.append(time)
        return true
    }

    func setRate(_ rate: Float) { self.rate = rate }
    func setMuted(_ muted: Bool) {}
    func selectQuality(_ quality: QualityOption) async throws {}
    func selectAudioTrack(_ track: AudioTrackOption) async throws {}
    func updateBoundaryObservers(times: [TimeInterval], onCrossed: @escaping @MainActor (TimeInterval) -> Void) {}
    func startPiP() {}
    func stopPiP() {}
    func handleBackgroundTransition(backgroundAudioEnabled: Bool, autoPiPEnabled: Bool) {}
    func handleForegroundTransition() {}

    func teardown() async {
        teardownCallCount += 1
        onEventLog?("teardown:\(capabilities.contains(.managesNowPlaying) ? "native" : "web")")
        broadcaster.finishAll()
    }

    func emit(_ event: PlaybackEngineEvent) {
        broadcaster.send(event)
    }
}

@MainActor
private final class MockRenderSurface: PlayerRenderSurfaceProtocol {
    let playerLayer = AVPlayerLayer()
    private(set) var activeSurface: ActiveRenderSurface = .none
    var onSurfaceChanged: ((ActiveRenderSurface) -> Void)?

    func attachWebView(_ webView: WKWebView) {}

    func setActiveSurface(_ surface: ActiveRenderSurface) {
        activeSurface = surface
        onSurfaceChanged?(surface)
    }
}

@MainActor
private final class MockNowPlayingManager: NowPlayingManagerProtocol {
    var onRemotePlay: (@MainActor () -> Void)?
    var onRemotePause: (@MainActor () -> Void)?
    var onRemoteTogglePlayPause: (@MainActor () -> Void)?
    var onRemoteSeek: (@MainActor (TimeInterval) -> Void)?
    var onRemoteNextTrack: (@MainActor () -> Void)?
    var onRemotePreviousTrack: (@MainActor () -> Void)?

    var onEventLog: ((String) -> Void)?
    private(set) var acquireCount = 0
    private(set) var relinquishCount = 0

    func acquireOwnership(for engine: any PlayerEngineProtocol, video: VideoItem) {
        acquireCount += 1
        onEventLog?("acquireOwnership")
    }

    func updatePlaybackStatus(state: PlaybackState, currentTime: TimeInterval, duration: DurationInfo, rate: Float) {}

    func relinquishOwnership() {
        relinquishCount += 1
        onEventLog?("relinquishOwnership")
    }
}

@MainActor
private final class MockAudioSessionManager: AudioSessionManagerProtocol {
    var onInterruptionBegan: (@MainActor () -> Void)?
    var onInterruptionEndedShouldResume: (@MainActor () -> Void)?
    var onRouteDisconnected: (@MainActor () -> Void)?
    var onMediaServicesReset: (@MainActor () -> Void)?
    func configurePlaybackSession() throws {}
    func activateSession() throws {}
    func startObserving() {}
    func stopObserving() {}
}

private final class MockStreamResolver: StreamResolverProtocol, @unchecked Sendable {
    var handler: @Sendable (VideoItem, Bool) async throws -> PlayableSource

    init(handler: @escaping @Sendable (VideoItem, Bool) async throws -> PlayableSource) {
        self.handler = handler
    }

    func resolve(video: VideoItem, bypassCache: Bool) async throws -> PlayableSource {
        try await handler(video, bypassCache)
    }

    func updateSettings(_ settings: StreamEndpointSettings) async {}
}

private actor DummySponsorBlockClient: SponsorBlockClientProtocol {
    func fetchSegments(for videoID: String, categories: [SponsorCategory]) async -> [SponsorSegment] { [] }
}

private actor DummyReturnDislikeClient: ReturnDislikeClientProtocol {
    func fetchMetrics(for videoID: String) async -> DislikeState { .unavailable }
}

final class PlaybackCoordinatorConcurrencyTests: XCTestCase {
    @MainActor
    private func makeCoordinator(
        native: MockPlayerEngine,
        web: MockPlayerEngine,
        resolver: MockStreamResolver,
        nowPlaying: MockNowPlayingManager,
        persistence: PersistenceWorker
    ) -> PlaybackCoordinator {
        PlaybackCoordinator(
            nativeEngine: native,
            webEngine: web,
            resolver: resolver,
            recoveryController: StreamRecoveryController(resolver: resolver, sleeper: { _ in }),
            ruleArbitrator: PlaybackRuleArbitrator(),
            queueManager: QueueManager(),
            nowPlayingManager: nowPlaying,
            audioSessionManager: MockAudioSessionManager(),
            persistence: persistence,
            sponsorBlockClient: DummySponsorBlockClient(),
            returnDislikeClient: DummyReturnDislikeClient()
        )
    }

    @MainActor
    func testRapidVideoSwitching_CancelsStaleLoadAndPreventsGhostAudio() async {
        let bootstrap = AppContainerFactory.makeContainer(forceInMemory: true)
        let persistence = PersistenceWorker(modelContainer: bootstrap.container)
        let native = MockPlayerEngine(capabilities: [.arbitraryPlaybackRate, .managesNowPlaying])
        let web = MockPlayerEngine(capabilities: [])
        let nowPlaying = MockNowPlayingManager()

        let resolver = MockStreamResolver { video, _ in
            if video.id == "vidA" {
                try await Task.sleep(for: .milliseconds(80))
            }
            return .direct(url: URL(string: "https://cdn.example.com/\(video.id).m3u8")!, format: .hls, headers: [:])
        }

        let coordinator = makeCoordinator(
            native: native,
            web: web,
            resolver: resolver,
            nowPlaying: nowPlaying,
            persistence: persistence
        )

        let videoA = VideoItem(id: "vidA", title: "Video A", channelId: "c1", channelTitle: "Ch 1", duration: 100)
        let videoB = VideoItem(id: "vidB", title: "Video B", channelId: "c1", channelTitle: "Ch 1", duration: 100)

        coordinator.play(video: videoA)
        try? await Task.sleep(for: .milliseconds(10))
        coordinator.play(video: videoB)
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(coordinator.currentVideo?.id, "vidB")
        XCTAssertEqual(native.loadedSources.count, 1)
        if case .direct(let url, _, _) = native.loadedSources.first?.0 {
            XCTAssertTrue(url.absoluteString.contains("vidB"))
        } else {
            XCTFail("Expected .direct source for vidB")
        }
    }

    @MainActor
    func testEngineSwitch_DirectToWebEmbed_RelinquishesNowPlayingAndSwitchesSurface() async {
        let bootstrap = AppContainerFactory.makeContainer(forceInMemory: true)
        let persistence = PersistenceWorker(modelContainer: bootstrap.container)
        let native = MockPlayerEngine(capabilities: [.arbitraryPlaybackRate, .managesNowPlaying])
        let web = MockPlayerEngine(capabilities: [])
        let nowPlaying = MockNowPlayingManager()
        let surface = MockRenderSurface()

        var sequenceLog: [String] = []
        native.onEventLog = { sequenceLog.append($0) }
        nowPlaying.onEventLog = { sequenceLog.append($0) }
        surface.onSurfaceChanged = { sequenceLog.append("surface:\($0)") }

        let resolver = MockStreamResolver { video, _ in
            if video.id == "direct1" {
                return .direct(url: URL(string: "https://cdn.example.com/1.m3u8")!, format: .hls, headers: [:])
            }
            return .webEmbed(videoID: video.id, baseURL: URL(string: "https://www.youtube-nocookie.com")!)
        }

        let coordinator = makeCoordinator(
            native: native,
            web: web,
            resolver: resolver,
            nowPlaying: nowPlaying,
            persistence: persistence
        )
        coordinator.attachRenderSurface(surface)

        coordinator.play(video: VideoItem(id: "direct1", title: "Direct", channelId: "c1", channelTitle: "Ch", duration: 120))
        try? await Task.sleep(for: .milliseconds(50))
        sequenceLog.removeAll()

        coordinator.play(video: VideoItem(id: "embed2", title: "Embed", channelId: "c1", channelTitle: "Ch", duration: 120))
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(surface.activeSurface, .webView)
        XCTAssertTrue(sequenceLog.contains("stopAndClear:native"))
        XCTAssertTrue(sequenceLog.contains("relinquishOwnership"))
        XCTAssertTrue(sequenceLog.contains("surface:webView"))
        if let stopIdx = sequenceLog.firstIndex(of: "stopAndClear:native"),
           let relIdx = sequenceLog.firstIndex(of: "relinquishOwnership"),
           let surfIdx = sequenceLog.firstIndex(of: "surface:webView") {
            XCTAssertTrue(stopIdx < relIdx && relIdx < surfIdx)
        } else {
            XCTFail("Missing expected switch events: \(sequenceLog)")
        }
    }

    @MainActor
    func testStreamExpired_RetriesTwiceThenFallsBackToWebEnginePreservingTime() async {
        let bootstrap = AppContainerFactory.makeContainer(forceInMemory: true)
        let persistence = PersistenceWorker(modelContainer: bootstrap.container)
        let native = MockPlayerEngine(capabilities: [.arbitraryPlaybackRate, .managesNowPlaying])
        let web = MockPlayerEngine(capabilities: [])
        let nowPlaying = MockNowPlayingManager()

        let resolver = MockStreamResolver { video, bypassCache in
            if bypassCache {
                throw PlaybackError.sourceResolutionFailed("Expired permanently")
            }
            return .direct(url: URL(string: "https://cdn.example.com/\(video.id).m3u8")!, format: .hls, headers: [:])
        }

        let coordinator = makeCoordinator(
            native: native,
            web: web,
            resolver: resolver,
            nowPlaying: nowPlaying,
            persistence: persistence
        )
        coordinator.play(video: VideoItem(id: "exp1", title: "Expiring", channelId: "c1", channelTitle: "Ch", duration: 300))
        try? await Task.sleep(for: .milliseconds(50))

        native.currentTime = 77.5
        native.emit(.streamLikelyExpired(httpStatus: 403))
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(native.teardownCallCount, 1)
        XCTAssertEqual(web.loadedSources.count, 1)
        XCTAssertEqual(web.loadedSources.first?.1 ?? -1, 77.5, accuracy: 0.1)
    }

    @MainActor
    func testDeferredResumePosition_WhenInitialDurationIsNil_SeeksAfterDurationResolved() async throws {
        let bootstrap = AppContainerFactory.makeContainer(forceInMemory: true)
        let persistence = PersistenceWorker(modelContainer: bootstrap.container)
        try await persistence.upsertWatchHistory(
            WatchHistoryDTO(
                videoId: "rss1",
                title: "RSS Video",
                channelId: "c1",
                channelName: "Ch",
                lastPosition: 45.0,
                duration: 0,
                watchedAt: .now
            )
        )

        let native = MockPlayerEngine(capabilities: [.arbitraryPlaybackRate, .managesNowPlaying])
        let web = MockPlayerEngine(capabilities: [])
        let nowPlaying = MockNowPlayingManager()
        let resolver = MockStreamResolver { video, _ in
            .direct(url: URL(string: "https://cdn.example.com/\(video.id).m3u8")!, format: .hls, headers: [:])
        }

        let coordinator = makeCoordinator(
            native: native,
            web: web,
            resolver: resolver,
            nowPlaying: nowPlaying,
            persistence: persistence
        )

        // Duration is initially nil (as from RSS feed).
        coordinator.play(video: VideoItem(id: "rss1", title: "RSS Video", channelId: "c1", channelTitle: "Ch", duration: nil))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(native.seekHistory.isEmpty)

        // Once engine resolves finite duration = 120.0s (> 45 + 5), deferred resume seeks to 45.0s.
        native.emit(.durationChanged(.finite(120.0)))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(native.seekHistory, [45.0])
    }

    @MainActor
    func testWKWebViewClampingAndGestureExclusionZones() {
        XCTAssertEqual(WKWebViewEngine.nearestSupportedRate(for: 1.35), 1.25)
        XCTAssertEqual(WKWebViewEngine.nearestSupportedRate(for: 2.8), 2.0)

        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let safe = UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
        XCTAssertTrue(PlayerGestureOverlay.isExcludedTouchLocation(CGPoint(x: 100, y: 50), bounds: bounds, safeAreaInsets: safe, excludedBottomHeight: 64))
        XCTAssertTrue(PlayerGestureOverlay.isExcludedTouchLocation(CGPoint(x: 100, y: 800), bounds: bounds, safeAreaInsets: safe, excludedBottomHeight: 64))
        XCTAssertFalse(PlayerGestureOverlay.isExcludedTouchLocation(CGPoint(x: 100, y: 400), bounds: bounds, safeAreaInsets: safe, excludedBottomHeight: 64))

        XCTAssertEqual(PlayerGestureOverlay.fullscreenPanZone(xRatio: 0.2), .brightness)
        XCTAssertEqual(PlayerGestureOverlay.fullscreenPanZone(xRatio: 0.5), .centerVertical)
        XCTAssertEqual(PlayerGestureOverlay.fullscreenPanZone(xRatio: 0.8), .volume)
    }
}
