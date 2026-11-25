import Foundation
import SwiftData
import XCTest
@testable import YouTubeAdvanced

final class SubscriptionImporterTests: XCTestCase {
    private func makeInMemoryWorker() -> PersistenceWorker {
        let bootstrap = AppContainerFactory.makeContainer(forceInMemory: true)
        return PersistenceWorker(modelContainer: bootstrap.container)
    }

    func testImportOPML_ValidAndMalformedOutlines_ReportsPartialFailures() async throws {
        let worker = makeInMemoryWorker()
        let importer = SubscriptionImporter(persistence: worker)

        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.1">
          <body>
            <outline text="YouTube Subscriptions" title="YouTube Subscriptions">
              <outline type="rss" text="Swift Channel" title="Swift Channel" xmlUrl="https://www.youtube.com/feeds/videos.xml?channel_id=UC1234567890123456789012" />
              <outline type="rss" text="Broken Feed" title="Broken Feed" xmlUrl="https://example.com/not-a-channel" />
              <outline type="rss" text="iOS Dev" title="iOS Dev" xmlUrl="https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefABCDEF0123456789" />
            </outline>
          </body>
        </opml>
        """

        let result = try await importer.importOPML(data: Data(opml.utf8))
        XCTAssertEqual(result.importedCount, 2)
        XCTAssertEqual(result.duplicateSkippedCount, 0)
        XCTAssertEqual(result.failedRows.count, 1)

        let stored = try await worker.fetchSubscriptions()
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(Set(stored.map(\.channelId)), ["UC1234567890123456789012", "UCabcdefABCDEF0123456789"])
    }

    func testImportTakeoutCSV_WithUTF8BOMAndEscapedQuotes_ParsesAccurately() async throws {
        let worker = makeInMemoryWorker()
        let importer = SubscriptionImporter(persistence: worker)

        let csv = "\u{FEFF}Channel Id,Channel Url,Channel Title\r\n" +
            "UC1111111111111111111111,http://www.youtube.com/channel/UC1111111111111111111111,\"Tech, \"\"Pro\"\" & More\"\r\n" +
            "invalid_row,http://example.com,Bad Channel\r\n"

        let result = try await importer.importTakeoutCSV(data: Data(csv.utf8))
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.failedRows.count, 1)

        let stored = try await worker.fetchSubscriptions()
        XCTAssertEqual(stored.first?.name, "Tech, \"Pro\" & More")
    }

    func testImportTakeoutCSV_DuplicateChannelIds_SkipsAndCountsDuplicates() async throws {
        let worker = makeInMemoryWorker()
        let importer = SubscriptionImporter(persistence: worker)

        let csv = """
        Channel Id,Channel Url,Channel Title
        UC2222222222222222222222,https://youtube.com/channel/UC2222222222222222222222,Channel A
        UC2222222222222222222222,https://youtube.com/channel/UC2222222222222222222222,Channel A Duplicate
        """

        let first = try await importer.importTakeoutCSV(data: Data(csv.utf8))
        XCTAssertEqual(first.importedCount, 1)
        XCTAssertEqual(first.duplicateSkippedCount, 1)

        let second = try await importer.importTakeoutCSV(data: Data(csv.utf8))
        XCTAssertEqual(second.importedCount, 0)
        XCTAssertEqual(second.duplicateSkippedCount, 2)
    }

    func testAppContainerFactory_CorruptedStore_RecoversGracefully() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("YTAdvCorruptTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("Corrupted.store")
        try Data("not-a-valid-sqlite-database".utf8).write(to: storeURL)

        let result = AppContainerFactory.makeContainer(forceInMemory: false, storeURL: storeURL)
        XCTAssertTrue(result.didRecoverFromCorruptedStore)
    }

    func testPersistenceWorker_UpsertAndPlaylistSortOrder() async throws {
        let worker = makeInMemoryWorker()
        let dto1 = WatchHistoryDTO(
            videoId: "vid1",
            title: "Title 1",
            channelId: "ch1",
            channelName: "Ch 1",
            lastPosition: 12,
            duration: 100,
            watchedAt: Date(timeIntervalSince1970: 100)
        )
        let dto2 = WatchHistoryDTO(
            videoId: "vid1",
            title: "Title 1",
            channelId: "ch1",
            channelName: "Ch 1",
            lastPosition: 45,
            duration: 100,
            watchedAt: Date(timeIntervalSince1970: 200)
        )
        try await worker.upsertWatchHistory(dto1)
        try await worker.upsertWatchHistory(dto2)

        let history = try await worker.fetchRecentWatchHistory(limit: 10)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.lastPosition, 45)

        let playlist = try await worker.createPlaylist(name: "Favorites")
        try await worker.addVideoToPlaylist(playlistId: playlist.id, videoId: "a", title: "A")
        try await worker.addVideoToPlaylist(playlistId: playlist.id, videoId: "b", title: "B")
        try await worker.addVideoToPlaylist(playlistId: playlist.id, videoId: "c", title: "C")
        try await worker.reorderPlaylistItems(playlistId: playlist.id, orderedVideoIds: ["c", "a", "b"])

        let playlists = try await worker.fetchPlaylists()
        XCTAssertEqual(playlists.first?.items.map(\.videoId), ["c", "a", "b"])
        XCTAssertEqual(playlists.first?.items.map(\.sortOrder), [0, 1, 2])
    }

    func testISO8601DurationAndLAMidnightAndEndpointValidator() {
        XCTAssertEqual(ISO8601DurationParser.parse("PT1H2M30S"), 3750)
        XCTAssertEqual(ISO8601DurationParser.parse("P1DT2H"), 93_600)
        XCTAssertNil(ISO8601DurationParser.parse("P0D", isLiveOrUpcoming: true))

        // 2026-07-15T22:00:00Z is 15:00 PDT -> next LA midnight is 2026-07-16T07:00:00Z
        let sample = Date(timeIntervalSince1970: 1_784_152_800) // 2026-07-15T22:00:00Z
        let reset = YouTubeDataAPIv3Provider.nextLosAngelesMidnight(after: sample)
        XCTAssertEqual(reset.timeIntervalSince1970, 1_784_185_200, accuracy: 1.0) // 2026-07-16T07:00:00Z

        XCTAssertThrowsError(try StreamEndpointValidator.validate(urlString: "http://example.com/api"))
        XCTAssertThrowsError(try StreamEndpointValidator.validate(urlString: "http://172.15.0.1:8080"))
        XCTAssertNoThrow(try StreamEndpointValidator.validate(urlString: "http://172.16.0.5:8080"))
        XCTAssertNoThrow(try StreamEndpointValidator.validate(urlString: "http://192.168.1.10:3000"))
        XCTAssertNoThrow(try StreamEndpointValidator.validate(urlString: "https://piped.example.com"))
    }
}
