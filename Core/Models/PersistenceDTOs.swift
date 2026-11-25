import Foundation

/// Sendable DTO for watch history persistence across actor boundaries.
struct WatchHistoryDTO: Identifiable, Sendable, Equatable {
    var id: String { videoId }
    let videoId: String
    let title: String
    let channelId: String
    let channelName: String
    let lastPosition: TimeInterval
    let duration: TimeInterval
    let watchedAt: Date
}

/// Sendable DTO for locally subscribed channels.
struct SubscribedChannelDTO: Identifiable, Sendable, Equatable {
    var id: String { channelId }
    let channelId: String
    let name: String
    let avatarURLString: String?
    let addedAt: Date
    let lastSyncedAt: Date?
    let etag: String?
}

/// Sendable DTO for timestamped video bookmarks.
struct BookmarkDTO: Identifiable, Sendable, Equatable {
    let id: UUID
    let videoId: String
    let timestamp: TimeInterval
    let note: String
    let createdAt: Date
}

/// Scope evaluated by `FeedFilterService` for a filter rule.
enum FilterTargetScope: String, Sendable, Equatable, Codable, CaseIterable {
    case titleOnly
    case channelNameOnly
    case all
}

/// Sendable DTO for keyword and regex feed filter rules.
struct FilterRuleDTO: Identifiable, Sendable, Equatable {
    let id: UUID
    let keyword: String
    let isRegex: Bool
    let targetScope: FilterTargetScope
    let isEnabled: Bool
}

/// Sendable DTO for ordered items inside a local playlist.
struct PlaylistItemDTO: Identifiable, Sendable, Equatable {
    var id: String { "\(playlistId.uuidString):\(videoId):\(sortOrder)" }
    let playlistId: UUID
    let videoId: String
    let title: String
    let sortOrder: Int
    let addedAt: Date
}

/// Sendable DTO for a local playlist and its sorted items.
struct LocalPlaylistDTO: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let createdAt: Date
    let items: [PlaylistItemDTO]
}

/// Broadcast domain emitted by `PersistenceWorker` when a save commits.
enum PersistenceChangeDomain: Sendable, Equatable {
    case watchHistory
    case subscriptions
    case bookmarks
    case filterRules
    case playlists
}

/// Per-row failure entry captured during partial-success OPML/CSV import.
struct SubscriptionImportRowError: Sendable, Equatable {
    let lineOrElementIndex: Int
    let rawValue: String
    let reason: String
}

/// Summary of an OPML or Takeout CSV subscription import operation.
struct SubscriptionImportResult: Sendable, Equatable {
    let importedCount: Int
    let duplicateSkippedCount: Int
    let failedRows: [SubscriptionImportRowError]
}
