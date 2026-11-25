import Foundation

/// SponsorBlock segment categories.
enum SponsorCategory: String, Sendable, Equatable, Codable, CaseIterable {
    case sponsor
    case selfpromo
    case interaction
    case intro
    case outro
    case preview
    case musicOfftopic = "music_offtopic"
    case filler
    case poiHighlight = "poi_highlight"
}

/// SponsorBlock segment action behavior.
enum SponsorActionType: String, Sendable, Equatable, Codable {
    case skip
    case mute
    case poi
    case full
}

/// Raw validated SponsorBlock segment associated with a specific video ID.
struct SponsorSegment: Identifiable, Sendable, Equatable, Codable {
    var id: String { uuid }
    let uuid: String
    let videoID: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let category: SponsorCategory
    let actionType: SponsorActionType
}

/// Merged contiguous or overlapping skip interval to avoid chained seek loops.
struct MergedSkipInterval: Identifiable, Sendable, Equatable {
    let id: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let categories: [SponsorCategory]
    let sourceUUIDs: [String]
}

/// Point-of-interest highlight timestamp separated from auto-skip segments.
struct SponsorHighlightPoint: Identifiable, Sendable, Equatable {
    var id: String { uuid }
    let uuid: String
    let timestamp: TimeInterval
}

/// Return YouTube Dislike metrics payload.
struct DislikeMetrics: Sendable, Equatable, Codable {
    let videoID: String
    let likes: Int
    let dislikes: Int
    let viewCount: Int64
    let rating: Double

    var likeRatio: Double {
        let total = likes + dislikes
        return total > 0 ? Double(likes) / Double(total) : 0.0
    }
}

/// Availability state preventing UI from misreporting failures as zero dislikes.
enum DislikeState: Sendable, Equatable {
    case loading
    case available(DislikeMetrics)
    case unavailable
}
