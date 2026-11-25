import Foundation

enum RecoveryDecision: Equatable, Sendable {
    case retryDirect(PlayableSource, resumeAt: TimeInterval)
    case fallbackToWebEmbed(PlayableSource, resumeAt: TimeInterval)
    case giveUp(PlaybackError)
}

/// Retries expired or stalled direct streams up to 2 times with backoff before falling back to WKWebView.
@MainActor
final class StreamRecoveryController {
    private static let defaultEmbedBaseURL = URL(string: "https://www.youtube-nocookie.com")!
    private static let backoffDurations: [Duration] = [.milliseconds(500), .milliseconds(1500)]

    private let resolver: any StreamResolverProtocol
    private let sleeper: @Sendable (Duration) async throws -> Void
    private var attemptsByVideoID: [String: Int] = [:]

    init(
        resolver: any StreamResolverProtocol,
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.resolver = resolver
        self.sleeper = sleeper
    }

    func reset(for videoID: String? = nil) {
        if let videoID {
            attemptsByVideoID.removeValue(forKey: videoID)
        } else {
            attemptsByVideoID.removeAll()
        }
    }

    func attemptRecovery(
        for video: VideoItem,
        lastKnownTime: TimeInterval,
        triggerError: PlaybackError
    ) async -> RecoveryDecision {
        let currentAttempt = attemptsByVideoID[video.id] ?? 0
        if currentAttempt >= Self.backoffDurations.count {
            let embed = PlayableSource.webEmbed(videoID: video.id, baseURL: Self.defaultEmbedBaseURL)
            return .fallbackToWebEmbed(embed, resumeAt: max(0, lastKnownTime))
        }

        let delay = Self.backoffDurations[currentAttempt]
        attemptsByVideoID[video.id] = currentAttempt + 1

        do {
            try await sleeper(delay)
            let refreshed = try await resolver.resolve(video: video, bypassCache: true)
            if refreshed.isDirect {
                return .retryDirect(refreshed, resumeAt: max(0, lastKnownTime))
            } else {
                return .fallbackToWebEmbed(refreshed, resumeAt: max(0, lastKnownTime))
            }
        } catch is CancellationError {
            return .giveUp(triggerError)
        } catch {
            // If that was the second failure, transition immediately to webEmbed fallback.
            if (attemptsByVideoID[video.id] ?? 0) >= Self.backoffDurations.count {
                let embed = PlayableSource.webEmbed(videoID: video.id, baseURL: Self.defaultEmbedBaseURL)
                return .fallbackToWebEmbed(embed, resumeAt: max(0, lastKnownTime))
            }
            // Otherwise allow a second recovery retry.
            return await attemptRecovery(for: video, lastKnownTime: lastKnownTime, triggerError: triggerError)
        }
    }
}
