import Foundation
import os
import SwiftData

protocol PersistenceWorkerProtocol: Sendable {
    func changeStream() -> AsyncStream<PersistenceChangeDomain>
    func upsertWatchHistory(_ dto: WatchHistoryDTO) async throws
    func fetchWatchPosition(videoId: String) async throws -> TimeInterval?
    func fetchRecentWatchHistory(limit: Int) async throws -> [WatchHistoryDTO]
    func upsertSubscriptions(_ channels: [SubscribedChannelDTO]) async throws
    func fetchSubscriptions() async throws -> [SubscribedChannelDTO]
    func deleteSubscription(channelId: String) async throws
    func addBookmark(_ dto: BookmarkDTO) async throws
    func fetchBookmarks(videoId: String) async throws -> [BookmarkDTO]
    func fetchAllBookmarks() async throws -> [BookmarkDTO]
    func deleteBookmark(id: UUID) async throws
    func upsertFilterRule(_ dto: FilterRuleDTO) async throws
    func fetchFilterRules() async throws -> [FilterRuleDTO]
    func deleteFilterRule(id: UUID) async throws
    func createPlaylist(name: String) async throws -> LocalPlaylistDTO
    func addVideoToPlaylist(playlistId: UUID, videoId: String, title: String) async throws
    func reorderPlaylistItems(playlistId: UUID, orderedVideoIds: [String]) async throws
    func fetchPlaylists() async throws -> [LocalPlaylistDTO]
    func deletePlaylist(id: UUID) async throws
}

/// Manual `ModelActor` binding `unownedExecutor` and disabling autosave for explicit iOS 17 upserts.
actor PersistenceWorker: ModelActor, PersistenceWorkerProtocol {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        modelExecutor.asUnownedSerialExecutor()
    }

    private let changeContinuationsLock = OSAllocatedUnfairLock<[UUID: AsyncStream<PersistenceChangeDomain>.Continuation]>(initialState: [:])

    init(modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    nonisolated func changeStream() -> AsyncStream<PersistenceChangeDomain> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            changeContinuationsLock.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    private nonisolated func removeContinuation(id: UUID) {
        changeContinuationsLock.withLock {
            _ = $0.removeValue(forKey: id)
        }
    }

    private nonisolated func broadcast(_ domain: PersistenceChangeDomain) {
        let active = changeContinuationsLock.withLock { Array($0.values) }
        for continuation in active {
            continuation.yield(domain)
        }
    }

    // MARK: - Watch History

    func upsertWatchHistory(_ dto: WatchHistoryDTO) async throws {
        let safePosition = dto.lastPosition.isFinite ? max(0, dto.lastPosition) : 0
        let safeDuration = dto.duration.isFinite ? max(0, dto.duration) : 0
        let targetId = dto.videoId

        var descriptor = FetchDescriptor<WatchHistoryEntity>(
            predicate: #Predicate { $0.videoId == targetId }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.title = dto.title
            existing.channelId = dto.channelId
            existing.channelName = dto.channelName
            existing.lastPosition = safePosition
            existing.duration = max(existing.duration, safeDuration)
            existing.watchedAt = dto.watchedAt
        } else {
            let entity = WatchHistoryEntity(
                videoId: dto.videoId,
                title: dto.title,
                channelId: dto.channelId,
                channelName: dto.channelName,
                lastPosition: safePosition,
                duration: safeDuration,
                watchedAt: dto.watchedAt
            )
            modelContext.insert(entity)
        }

        try modelContext.save()
        broadcast(.watchHistory)
    }

    func fetchWatchPosition(videoId: String) async throws -> TimeInterval? {
        var descriptor = FetchDescriptor<WatchHistoryEntity>(
            predicate: #Predicate { $0.videoId == videoId }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.lastPosition
    }

    func fetchRecentWatchHistory(limit: Int = 100) async throws -> [WatchHistoryDTO] {
        var descriptor = FetchDescriptor<WatchHistoryEntity>(
            sortBy: [SortDescriptor(\.watchedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return try modelContext.fetch(descriptor).map {
            WatchHistoryDTO(
                videoId: $0.videoId,
                title: $0.title,
                channelId: $0.channelId,
                channelName: $0.channelName,
                lastPosition: $0.lastPosition,
                duration: $0.duration,
                watchedAt: $0.watchedAt
            )
        }
    }

    // MARK: - Subscriptions

    func upsertSubscriptions(_ channels: [SubscribedChannelDTO]) async throws {
        guard !channels.isEmpty else { return }

        for dto in channels {
            let cid = dto.channelId
            var descriptor = FetchDescriptor<SubscribedChannelEntity>(
                predicate: #Predicate { $0.channelId == cid }
            )
            descriptor.fetchLimit = 1

            if let existing = try modelContext.fetch(descriptor).first {
                existing.name = dto.name
                if let avatar = dto.avatarURLString {
                    existing.avatarURLString = avatar
                }
                if let lastSynced = dto.lastSyncedAt {
                    existing.lastSyncedAt = lastSynced
                }
                if let etag = dto.etag {
                    existing.etag = etag
                }
            } else {
                let entity = SubscribedChannelEntity(
                    channelId: dto.channelId,
                    name: dto.name,
                    avatarURLString: dto.avatarURLString,
                    addedAt: dto.addedAt,
                    lastSyncedAt: dto.lastSyncedAt,
                    etag: dto.etag
                )
                modelContext.insert(entity)
            }
        }

        try modelContext.save()
        broadcast(.subscriptions)
    }

    func fetchSubscriptions() async throws -> [SubscribedChannelDTO] {
        let descriptor = FetchDescriptor<SubscribedChannelEntity>(
            sortBy: [SortDescriptor(\.addedAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map {
            SubscribedChannelDTO(
                channelId: $0.channelId,
                name: $0.name,
                avatarURLString: $0.avatarURLString,
                addedAt: $0.addedAt,
                lastSyncedAt: $0.lastSyncedAt,
                etag: $0.etag
            )
        }
    }

    func deleteSubscription(channelId: String) async throws {
        let descriptor = FetchDescriptor<SubscribedChannelEntity>(
            predicate: #Predicate { $0.channelId == channelId }
        )
        let matches = try modelContext.fetch(descriptor)
        for entity in matches {
            modelContext.delete(entity)
        }
        try modelContext.save()
        broadcast(.subscriptions)
    }

    // MARK: - Bookmarks

    func addBookmark(_ dto: BookmarkDTO) async throws {
        let targetId = dto.id
        var descriptor = FetchDescriptor<BookmarkEntity>(
            predicate: #Predicate { $0.id == targetId }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.timestamp = dto.timestamp
            existing.note = dto.note
        } else {
            let entity = BookmarkEntity(
                id: dto.id,
                videoId: dto.videoId,
                timestamp: dto.timestamp,
                note: dto.note,
                createdAt: dto.createdAt
            )
            modelContext.insert(entity)
        }

        try modelContext.save()
        broadcast(.bookmarks)
    }

    func fetchBookmarks(videoId: String) async throws -> [BookmarkDTO] {
        let descriptor = FetchDescriptor<BookmarkEntity>(
            predicate: #Predicate { $0.videoId == videoId },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map {
            BookmarkDTO(
                id: $0.id,
                videoId: $0.videoId,
                timestamp: $0.timestamp,
                note: $0.note,
                createdAt: $0.createdAt
            )
        }
    }

    func fetchAllBookmarks() async throws -> [BookmarkDTO] {
        let descriptor = FetchDescriptor<BookmarkEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map {
            BookmarkDTO(
                id: $0.id,
                videoId: $0.videoId,
                timestamp: $0.timestamp,
                note: $0.note,
                createdAt: $0.createdAt
            )
        }
    }

    func deleteBookmark(id: UUID) async throws {
        let descriptor = FetchDescriptor<BookmarkEntity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(descriptor) {
            modelContext.delete(entity)
        }
        try modelContext.save()
        broadcast(.bookmarks)
    }

    // MARK: - Filter Rules

    func upsertFilterRule(_ dto: FilterRuleDTO) async throws {
        let targetId = dto.id
        var descriptor = FetchDescriptor<FilterRuleEntity>(
            predicate: #Predicate { $0.id == targetId }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.keyword = dto.keyword
            existing.isRegex = dto.isRegex
            existing.targetScopeRaw = dto.targetScope.rawValue
            existing.isEnabled = dto.isEnabled
        } else {
            let entity = FilterRuleEntity(
                id: dto.id,
                keyword: dto.keyword,
                isRegex: dto.isRegex,
                targetScopeRaw: dto.targetScope.rawValue,
                isEnabled: dto.isEnabled
            )
            modelContext.insert(entity)
        }

        try modelContext.save()
        broadcast(.filterRules)
    }

    func fetchFilterRules() async throws -> [FilterRuleDTO] {
        let descriptor = FetchDescriptor<FilterRuleEntity>()
        return try modelContext.fetch(descriptor).map {
            FilterRuleDTO(
                id: $0.id,
                keyword: $0.keyword,
                isRegex: $0.isRegex,
                targetScope: FilterTargetScope(rawValue: $0.targetScopeRaw) ?? .all,
                isEnabled: $0.isEnabled
            )
        }
    }

    func deleteFilterRule(id: UUID) async throws {
        let descriptor = FetchDescriptor<FilterRuleEntity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(descriptor) {
            modelContext.delete(entity)
        }
        try modelContext.save()
        broadcast(.filterRules)
    }

    // MARK: - Playlists

    func createPlaylist(name: String) async throws -> LocalPlaylistDTO {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let entity = LocalPlaylistEntity(name: trimmed.isEmpty ? "새 재생목록" : trimmed)
        modelContext.insert(entity)
        try modelContext.save()
        broadcast(.playlists)
        return LocalPlaylistDTO(id: entity.id, name: entity.name, createdAt: entity.createdAt, items: [])
    }

    func addVideoToPlaylist(playlistId: UUID, videoId: String, title: String) async throws {
        var descriptor = FetchDescriptor<LocalPlaylistEntity>(
            predicate: #Predicate { $0.id == playlistId }
        )
        descriptor.fetchLimit = 1
        guard let playlist = try modelContext.fetch(descriptor).first else { return }

        let nextOrder = (playlist.items.map(\.sortOrder).max() ?? -1) + 1
        let item = PlaylistItemEntity(
            videoId: videoId,
            title: title,
            sortOrder: nextOrder,
            playlist: playlist
        )
        modelContext.insert(item)
        playlist.items.append(item)
        try modelContext.save()
        broadcast(.playlists)
    }

    func reorderPlaylistItems(playlistId: UUID, orderedVideoIds: [String]) async throws {
        var descriptor = FetchDescriptor<LocalPlaylistEntity>(
            predicate: #Predicate { $0.id == playlistId }
        )
        descriptor.fetchLimit = 1
        guard let playlist = try modelContext.fetch(descriptor).first else { return }

        var remaining = playlist.items.sorted { $0.sortOrder < $1.sortOrder }
        var assigned = 0

        for targetVideoId in orderedVideoIds {
            if let idx = remaining.firstIndex(where: { $0.videoId == targetVideoId }) {
                let item = remaining.remove(at: idx)
                item.sortOrder = assigned
                assigned += 1
            }
        }
        for leftover in remaining {
            leftover.sortOrder = assigned
            assigned += 1
        }

        try modelContext.save()
        broadcast(.playlists)
    }

    func fetchPlaylists() async throws -> [LocalPlaylistDTO] {
        let descriptor = FetchDescriptor<LocalPlaylistEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { playlist in
            let sortedItems = playlist.items
                .sorted { $0.sortOrder < $1.sortOrder }
                .map {
                    PlaylistItemDTO(
                        playlistId: playlist.id,
                        videoId: $0.videoId,
                        title: $0.title,
                        sortOrder: $0.sortOrder,
                        addedAt: $0.addedAt
                    )
                }
            return LocalPlaylistDTO(
                id: playlist.id,
                name: playlist.name,
                createdAt: playlist.createdAt,
                items: sortedItems
            )
        }
    }

    func deletePlaylist(id: UUID) async throws {
        let descriptor = FetchDescriptor<LocalPlaylistEntity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(descriptor) {
            modelContext.delete(entity)
        }
        try modelContext.save()
        broadcast(.playlists)
    }
}
