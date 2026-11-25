import Foundation

/// Combines quota-free RSS feeds with optional 50-ID Data API v3 metadata enrichment.
final class CompositeVideoRepository: VideoDataProvider, Sendable {
    private let rssProvider: RSSFeedProvider
    private let apiProvider: YouTubeDataAPIv3Provider

    init(rssProvider: RSSFeedProvider, apiProvider: YouTubeDataAPIv3Provider) {
        self.rssProvider = rssProvider
        self.apiProvider = apiProvider
    }

    func fetchChannelFeed(channelId: String, forceRefresh: Bool = false) async throws -> [VideoItem] {
        let rssItems = try await rssProvider.fetchChannelFeed(channelId: channelId, forceRefresh: forceRefresh)
        return await enrichMissingMetadataIfPossible(rssItems)
    }

    func fetchCombinedSubscriptionFeed(
        channelIds: [String],
        forceRefresh: Bool = false
    ) async -> [VideoItem] {
        let rssItems = await rssProvider.fetchMultipleChannelFeeds(channelIds: channelIds, forceRefresh: forceRefresh)
        return await enrichMissingMetadataIfPossible(rssItems)
    }

    func fetchVideoDetails(videoIds: [String]) async throws -> [VideoItem] {
        try await apiProvider.fetchVideoDetails(videoIds: videoIds)
    }

    func searchVideos(query: String, pageToken: String?) async throws -> VideoPage {
        try await apiProvider.searchVideos(query: query, pageToken: pageToken)
    }

    func resolveChannelId(fromInput input: String) async throws -> String {
        try await apiProvider.resolveChannelId(fromInput: input)
    }

    func notifyAPIKeyUpdated() async {
        await apiProvider.notifyAPIKeyUpdated()
    }

    func currentQuotaResetDate() async -> Date? {
        await apiProvider.currentQuotaResetDate()
    }

    private func enrichMissingMetadataIfPossible(_ items: [VideoItem]) async -> [VideoItem] {
        guard !items.isEmpty else { return [] }
        guard await apiProvider.hasAPIKey(),
              await apiProvider.currentQuotaResetDate() == nil else {
            return items
        }

        let missingIds = items.filter { $0.duration == nil }.map(\.id)
        guard !missingIds.isEmpty else { return items }

        do {
            let enriched = try await apiProvider.fetchVideoDetails(videoIds: missingIds)
            let byId = Dictionary(uniqueKeysWithValues: enriched.map { ($0.id, $0) })
            return items.map { item in
                guard let detail = byId[item.id] else { return item }
                return VideoItem(
                    id: item.id,
                    title: detail.title.isEmpty ? item.title : detail.title,
                    channelId: item.channelId,
                    channelTitle: detail.channelTitle.isEmpty ? item.channelTitle : detail.channelTitle,
                    duration: detail.duration,
                    thumbnailURL: detail.thumbnailURL ?? item.thumbnailURL,
                    publishedAt: item.publishedAt,
                    playability: detail.playability,
                    isShortHint: item.isShortHint ?? detail.isShortHint
                )
            }
        } catch {
            // Graceful degradation: RSS items remain usable even when API enrichment fails.
            return items
        }
    }
}
