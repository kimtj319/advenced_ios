import Foundation

/// Duration metadata distinguishing VOD, unknown RSS state, and live streams.
enum DurationInfo: Equatable, Sendable {
    case unknown
    case finite(TimeInterval)
    case live(seekableRange: ClosedRange<TimeInterval>?)

    var finiteSeconds: TimeInterval? {
        if case .finite(let seconds) = self, seconds.isFinite, seconds > 0 {
            return seconds
        }
        return nil
    }
}

/// Reason why playback entered `.paused`.
enum PauseReason: Equatable, Sendable {
    case user
    case audioSessionInterruption
    case audioRouteDisconnected
    case bufferingTimeout
}

/// Playback lifecycle state exposed by player engines and `PlaybackCoordinator`.
enum PlaybackState: Equatable, Sendable {
    case idle
    case loading(loadID: UUID)
    case playing
    case paused(reason: PauseReason)
    case buffering(wasPlaying: Bool)
    case ended
    case failed(PlaybackError)
}

/// Typed playback errors with Equatable support for SwiftUI state diffing.
enum PlaybackError: Error, Equatable, Sendable {
    case sourceResolutionFailed(String)
    case streamExpired(httpStatus: Int)
    case networkUnavailable
    case unsupportedMediaFormat(osStatus: Int32)
    case mediaServicesReset
    case playbackFailed(domain: String, code: Int, message: String)
    case webViewBridgeFailed(String)
}

/// Validated A-B loop interval requiring at least 1.0 second separation to prevent seek storms.
struct ABLoopRange: Equatable, Sendable {
    let pointA: TimeInterval
    let pointB: TimeInterval

    init?(pointA: TimeInterval, pointB: TimeInterval) {
        guard pointA.isFinite,
              pointB.isFinite,
              pointA >= 0,
              (pointB - pointA) >= 1.0 else {
            return nil
        }
        self.pointA = pointA
        self.pointB = pointB
    }
}
