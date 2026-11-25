import Foundation
import SwiftData

/// Version 1 SwiftData schema containing all six local persistence entities.
enum AppSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            WatchHistoryEntity.self,
            SubscribedChannelEntity.self,
            BookmarkEntity.self,
            FilterRuleEntity.self,
            LocalPlaylistEntity.self,
            PlaylistItemEntity.self
        ]
    }

    @Model
    final class WatchHistoryEntity {
        @Attribute(.unique) var videoId: String
        var title: String
        var channelId: String
        var channelName: String
        var lastPosition: TimeInterval
        var duration: TimeInterval
        var watchedAt: Date

        init(
            videoId: String,
            title: String,
            channelId: String,
            channelName: String,
            lastPosition: TimeInterval,
            duration: TimeInterval,
            watchedAt: Date = .now
        ) {
            self.videoId = videoId
            self.title = title
            self.channelId = channelId
            self.channelName = channelName
            self.lastPosition = lastPosition
            self.duration = duration
            self.watchedAt = watchedAt
        }
    }

    @Model
    final class SubscribedChannelEntity {
        @Attribute(.unique) var channelId: String
        var name: String
        var avatarURLString: String?
        var addedAt: Date
        var lastSyncedAt: Date?
        var etag: String?

        init(
            channelId: String,
            name: String,
            avatarURLString: String? = nil,
            addedAt: Date = .now,
            lastSyncedAt: Date? = nil,
            etag: String? = nil
        ) {
            self.channelId = channelId
            self.name = name
            self.avatarURLString = avatarURLString
            self.addedAt = addedAt
            self.lastSyncedAt = lastSyncedAt
            self.etag = etag
        }
    }

    @Model
    final class BookmarkEntity {
        @Attribute(.unique) var id: UUID
        var videoId: String
        var timestamp: TimeInterval
        var note: String
        var createdAt: Date

        init(
            id: UUID = UUID(),
            videoId: String,
            timestamp: TimeInterval,
            note: String,
            createdAt: Date = .now
        ) {
            self.id = id
            self.videoId = videoId
            self.timestamp = timestamp
            self.note = note
            self.createdAt = createdAt
        }
    }

    @Model
    final class FilterRuleEntity {
        @Attribute(.unique) var id: UUID
        var keyword: String
        var isRegex: Bool
        var targetScopeRaw: String
        var isEnabled: Bool

        init(
            id: UUID = UUID(),
            keyword: String,
            isRegex: Bool,
            targetScopeRaw: String,
            isEnabled: Bool = true
        ) {
            self.id = id
            self.keyword = keyword
            self.isRegex = isRegex
            self.targetScopeRaw = targetScopeRaw
            self.isEnabled = isEnabled
        }
    }

    @Model
    final class LocalPlaylistEntity {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date
        @Relationship(deleteRule: .cascade, inverse: \PlaylistItemEntity.playlist)
        var items: [PlaylistItemEntity] = []

        init(id: UUID = UUID(), name: String, createdAt: Date = .now) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
        }
    }

    @Model
    final class PlaylistItemEntity {
        var videoId: String
        var title: String
        var sortOrder: Int
        var addedAt: Date
        var playlist: LocalPlaylistEntity?

        init(
            videoId: String,
            title: String,
            sortOrder: Int,
            addedAt: Date = .now,
            playlist: LocalPlaylistEntity? = nil
        ) {
            self.videoId = videoId
            self.title = title
            self.sortOrder = sortOrder
            self.addedAt = addedAt
            self.playlist = playlist
        }
    }
}

typealias WatchHistoryEntity = AppSchemaV1.WatchHistoryEntity
typealias SubscribedChannelEntity = AppSchemaV1.SubscribedChannelEntity
typealias BookmarkEntity = AppSchemaV1.BookmarkEntity
typealias FilterRuleEntity = AppSchemaV1.FilterRuleEntity
typealias LocalPlaylistEntity = AppSchemaV1.LocalPlaylistEntity
typealias PlaylistItemEntity = AppSchemaV1.PlaylistItemEntity

/// Result of creating the SwiftData `ModelContainer`, including recovery metadata.
struct AppContainerBootstrapResult {
    let container: ModelContainer
    let didRecoverFromCorruptedStore: Bool
    let isFallbackInMemory: Bool
}

/// Three-stage SwiftData container factory avoiding V1 migration crashes and free-account entitlements.
enum AppContainerFactory {
    static func makeContainer(
        forceInMemory: Bool = false,
        storeURL: URL? = nil
    ) -> AppContainerBootstrapResult {
        let schema = Schema(versionedSchema: AppSchemaV1.self)
        let isTestEnv = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

        // Stage 1: Test host or explicit in-memory short-circuit (skip when testing a specific storeURL).
        if forceInMemory || (isTestEnv && storeURL == nil) {
            let memConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
            if let container = try? ModelContainer(for: schema, configurations: [memConfig]) {
                return AppContainerBootstrapResult(
                    container: container,
                    didRecoverFromCorruptedStore: false,
                    isFallbackInMemory: false
                )
            }
        }

        // Stage 2: Disk-backed store without App Group or CloudKit entitlements.
        let diskConfig: ModelConfiguration
        if let storeURL {
            diskConfig = ModelConfiguration(
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
        } else {
            diskConfig = ModelConfiguration(
                "YouTubeAdvancedStore",
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
        }

        if let container = try? ModelContainer(for: schema, configurations: [diskConfig]) {
            return AppContainerBootstrapResult(
                container: container,
                didRecoverFromCorruptedStore: false,
                isFallbackInMemory: false
            )
        }

        // Stage 3a: Remove corrupted SQLite files and retry once.
        removeStoreFiles(at: diskConfig.url)
        if let recoveredContainer = try? ModelContainer(for: schema, configurations: [diskConfig]) {
            return AppContainerBootstrapResult(
                container: recoveredContainer,
                didRecoverFromCorruptedStore: true,
                isFallbackInMemory: false
            )
        }

        // Stage 3b: Non-crashing in-memory fallback so the UI can warn the user gracefully.
        let fallbackConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        do {
            let fallbackContainer = try ModelContainer(for: schema, configurations: [fallbackConfig])
            return AppContainerBootstrapResult(
                container: fallbackContainer,
                didRecoverFromCorruptedStore: true,
                isFallbackInMemory: true
            )
        } catch {
            // Only reachable if the Schema definition itself is invalid.
            preconditionFailure("Unable to initialize fallback in-memory ModelContainer: \(error)")
        }
    }

    private static func removeStoreFiles(at url: URL) {
        let fm = FileManager.default
        let candidates = [
            url,
            URL(fileURLWithPath: url.path + "-shm"),
            URL(fileURLWithPath: url.path + "-wal")
        ]
        for fileURL in candidates where fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: fileURL)
        }
    }
}
