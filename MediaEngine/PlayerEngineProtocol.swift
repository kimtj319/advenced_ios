import AVFoundation
import Foundation
import WebKit

enum ActiveRenderSurface: Sendable, Equatable {
    case none
    case avPlayerLayer
    case webView
}

/// Decouples MediaEngine from SwiftUI views so `AVPlayerEngine` and `WKWebViewEngine` can be tested cleanly.
@MainActor
protocol PlayerRenderSurfaceProtocol: AnyObject {
    var playerLayer: AVPlayerLayer { get }
    func attachWebView(_ webView: WKWebView)
    func setActiveSurface(_ surface: ActiveRenderSurface)
}

struct EngineCapabilities: OptionSet, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let arbitraryPlaybackRate = EngineCapabilities(rawValue: 1 << 0)
    static let nativePiP             = EngineCapabilities(rawValue: 1 << 1)
    static let backgroundAudio       = EngineCapabilities(rawValue: 1 << 2)
    static let qualitySelection      = EngineCapabilities(rawValue: 1 << 3)
    static let audioTrackSelection   = EngineCapabilities(rawValue: 1 << 4)
    static let precisionBoundaries   = EngineCapabilities(rawValue: 1 << 5)
    static let managesNowPlaying     = EngineCapabilities(rawValue: 1 << 6)
}

struct QualityOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let height: Int
    let fps: Float
    let codec: String
}

struct AudioTrackOption: Identifiable, Hashable, Sendable {
    let id: String
    let languageCode: String
    let displayName: String
}

enum PlaybackEngineEvent: Sendable, Equatable {
    case stateChanged(PlaybackState)
    case timeUpdated(currentTime: TimeInterval, bufferedTime: TimeInterval)
    case durationChanged(DurationInfo)
    case didPlayToEnd
    case streamLikelyExpired(httpStatus: Int)
    case pipStateChanged(isActive: Bool, isPossible: Bool)
}

enum SeekPrecision: Sendable {
    case exact
    case fast
}

@MainActor
protocol PlayerEngineProtocol: AnyObject {
    var capabilities: EngineCapabilities { get }
    var state: PlaybackState { get }
    var currentTime: TimeInterval { get }
    var bufferedTime: TimeInterval { get }
    var durationInfo: DurationInfo { get }
    var rate: Float { get }
    var availableQualities: [QualityOption] { get }
    var selectedQuality: QualityOption? { get }
    var availableAudioTracks: [AudioTrackOption] { get }
    var selectedAudioTrack: AudioTrackOption? { get }

    func eventStream() -> AsyncStream<PlaybackEngineEvent>
    func attachRenderSurface(_ surface: (any PlayerRenderSurfaceProtocol)?)
    func load(source: PlayableSource, startAt: TimeInterval?) async throws
    func stopAndClear()
    func play()
    func pause(reason: PauseReason)
    @discardableResult
    func seek(to time: TimeInterval, precision: SeekPrecision) async -> Bool
    func setRate(_ rate: Float)
    func setMuted(_ muted: Bool)
    func selectQuality(_ quality: QualityOption) async throws
    func selectAudioTrack(_ track: AudioTrackOption) async throws
    func updateBoundaryObservers(times: [TimeInterval], onCrossed: @escaping @MainActor (TimeInterval) -> Void)
    func startPiP()
    func stopPiP()
    func handleBackgroundTransition(backgroundAudioEnabled: Bool, autoPiPEnabled: Bool)
    func handleForegroundTransition()
    func teardown() async
}
