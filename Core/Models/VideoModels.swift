import Foundation

/// Playability and broadcast state of a video item.
enum VideoPlayability: Sendable, Equatable, Codable {
    case playable
    case live(concurrentViewers: Int?)
    case upcoming(scheduledStart: Date?)
    case restricted(RestrictionReason)

    enum RestrictionReason: String, Sendable, Equatable, Codable {
        case privateOrDeleted
        case regionBlocked
        case ageRestricted
        case embedDisabled
    }
}

/// Core domain representation of a YouTube video across RSS, API, queue, and UI layers.
struct VideoItem: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let title: String
    let channelId: String
    let channelTitle: String
    let duration: TimeInterval?
    let thumbnailURL: URL?
    let publishedAt: Date
    let playability: VideoPlayability
    let isShortHint: Bool?

    init(
        id: String,
        title: String,
        channelId: String,
        channelTitle: String,
        duration: TimeInterval? = nil,
        thumbnailURL: URL? = nil,
        publishedAt: Date = .now,
        playability: VideoPlayability = .playable,
        isShortHint: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.channelId = channelId
        self.channelTitle = channelTitle
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.publishedAt = publishedAt
        self.playability = playability
        self.isShortHint = isShortHint
    }
}

/// Paginated search result container.
struct VideoPage: Sendable, Equatable {
    let items: [VideoItem]
    let nextPageToken: String?
}

/// Resolved playback source consumed by either `AVPlayerEngine` or `WKWebViewEngine`.
enum PlayableSource: Sendable, Equatable {
    case direct(url: URL, format: DirectStreamFormat, headers: [String: String])
    case webEmbed(videoID: String, baseURL: URL)

    enum DirectStreamFormat: String, Sendable, Equatable, Codable {
        case hls
        case muxedMP4
        case audioOnly
    }

    var isDirect: Bool {
        if case .direct = self { return true }
        return false
    }
}

/// Display modes for the single persistent `PlayerRenderHostView`.
enum PlayerDisplayMode: Sendable, Equatable {
    case hidden
    case inline
    case miniPlayer
    case fullscreen
}
