import Foundation

struct RSSDiskCacheEntry: Codable, Sendable {
    let items: [VideoItem]
    let etag: String?
    let lastModified: String?
    let cachedAt: Date
}

/// Quota-free YouTube Atom RSS feed fetcher with disk caching, ETag/304 support, and concurrency cap of 4.
actor RSSFeedProvider {
    private let httpClient: HTTPResilienceClient
    private let cacheDirectory: URL
    private let now: @Sendable () -> Date
    private let softTTL: TimeInterval = 900       // 15 minutes
    private let swrTTL: TimeInterval = 86_400     // 24 hours

    init(
        httpClient: HTTPResilienceClient,
        cacheDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.httpClient = httpClient
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.cacheDirectory = base.appendingPathComponent("RSSCache", isDirectory: true)
        }
        self.now = now
    }

    func fetchChannelFeed(channelId: String, forceRefresh: Bool = false) async throws -> [VideoItem] {
        let currentDate = now()
        let diskEntry = loadDiskCache(for: channelId)

        if !forceRefresh,
           let diskEntry,
           currentDate.timeIntervalSince(diskEntry.cachedAt) < softTTL {
            return diskEntry.items
        }

        guard let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)") else {
            throw VideoDataError.channelNotFound(channelId)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if let etag = diskEntry?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = diskEntry?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            let (data, response) = try await httpClient.perform(request, coalesce: true)
            if response.statusCode == 304, let diskEntry {
                let refreshed = RSSDiskCacheEntry(
                    items: diskEntry.items,
                    etag: diskEntry.etag,
                    lastModified: diskEntry.lastModified,
                    cachedAt: currentDate
                )
                saveDiskCache(refreshed, for: channelId)
                return diskEntry.items
            }

            guard (200...299).contains(response.statusCode) else {
                if let diskEntry, currentDate.timeIntervalSince(diskEntry.cachedAt) < swrTTL {
                    return diskEntry.items
                }
                throw VideoDataError.httpError(statusCode: response.statusCode, message: "RSS feed error")
            }

            if let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               contentType.contains("text/html") {
                if let diskEntry, currentDate.timeIntervalSince(diskEntry.cachedAt) < swrTTL {
                    return diskEntry.items
                }
                throw VideoDataError.parsingFailed("Unexpected HTML response for RSS feed")
            }

            let parser = RSSAtomParserHelper(fallbackChannelId: channelId)
            let items = try parser.parse(data: data)

            let entry = RSSDiskCacheEntry(
                items: items,
                etag: response.value(forHTTPHeaderField: "ETag") ?? diskEntry?.etag,
                lastModified: response.value(forHTTPHeaderField: "Last-Modified") ?? diskEntry?.lastModified,
                cachedAt: currentDate
            )
            saveDiskCache(entry, for: channelId)
            return items
        } catch {
            if let diskEntry, currentDate.timeIntervalSince(diskEntry.cachedAt) < swrTTL {
                return diskEntry.items
            }
            if let videoErr = error as? VideoDataError {
                throw videoErr
            }
            if let urlErr = error as? URLError, urlErr.code == .notConnectedToInternet {
                throw VideoDataError.networkUnavailable
            }
            throw VideoDataError.httpError(statusCode: -1, message: error.localizedDescription)
        }
    }

    /// Fetches multiple channel feeds using a sliding-window TaskGroup capped at 4 concurrent requests.
    func fetchMultipleChannelFeeds(
        channelIds: [String],
        forceRefresh: Bool = false
    ) async -> [VideoItem] {
        guard !channelIds.isEmpty else { return [] }
        let maxConcurrent = 4

        var allItems: [VideoItem] = []
        await withTaskGroup(of: [VideoItem].self) { group in
            var index = 0
            while index < min(maxConcurrent, channelIds.count) {
                let cid = channelIds[index]
                group.addTask {
                    (try? await self.fetchChannelFeed(channelId: cid, forceRefresh: forceRefresh)) ?? []
                }
                index += 1
            }

            while let batch = await group.next() {
                allItems.append(contentsOf: batch)
                if index < channelIds.count {
                    let cid = channelIds[index]
                    index += 1
                    group.addTask {
                        (try? await self.fetchChannelFeed(channelId: cid, forceRefresh: forceRefresh)) ?? []
                    }
                }
            }
        }

        // Deduplicate by video ID and sort newest first.
        var uniqueById: [String: VideoItem] = [:]
        for item in allItems where uniqueById[item.id] == nil {
            uniqueById[item.id] = item
        }
        return uniqueById.values.sorted { $0.publishedAt > $1.publishedAt }
    }

    // MARK: - Disk Cache

    private func cacheFileURL(for channelId: String) -> URL {
        let sanitized = channelId.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory.appendingPathComponent("\(sanitized).json")
    }

    private func loadDiskCache(for channelId: String) -> RSSDiskCacheEntry? {
        let url = cacheFileURL(for: channelId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RSSDiskCacheEntry.self, from: data)
    }

    private func saveDiskCache(_ entry: RSSDiskCacheEntry, for channelId: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: cacheDirectory.path) {
            try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: cacheFileURL(for: channelId), options: .atomic)
    }
}

private final class RSSAtomParserHelper: NSObject, XMLParserDelegate {
    private let fallbackChannelId: String
    private var elementStack: [String] = []
    private var currentText = ""

    private var feedChannelTitle = ""
    private var items: [VideoItem] = []

    // Per-entry scratch fields
    private var inEntry = false
    private var entryVideoId = ""
    private var entryChannelId = ""
    private var entryTitle = ""
    private var entryAuthorName = ""
    private var entryPublished = ""
    private var entryThumbnailURL: String?
    private var entryIsShortHint: Bool?

    private static let isoStyleWithFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoStyleStandard = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    init(fallbackChannelId: String) {
        self.fallbackChannelId = fallbackChannelId
    }

    func parse(data: Data) throws -> [VideoItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        let success = parser.parse()
        if !success && items.isEmpty {
            throw VideoDataError.parsingFailed(parser.parserError?.localizedDescription ?? "XML parse error")
        }
        return items
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elementStack.append(elementName)
        currentText = ""

        if elementName == "entry" {
            inEntry = true
            entryVideoId = ""
            entryChannelId = fallbackChannelId
            entryTitle = ""
            entryAuthorName = ""
            entryPublished = ""
            entryThumbnailURL = nil
            entryIsShortHint = nil
        } else if inEntry && elementName == "media:thumbnail", let urlStr = attributeDict["url"] {
            if entryThumbnailURL == nil {
                entryThumbnailURL = urlStr
            }
        } else if inEntry && elementName == "link",
                  attributeDict["rel"] == "alternate",
                  let href = attributeDict["href"],
                  href.contains("/shorts/") {
            entryIsShortHint = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = elementStack.dropLast().last

        if !inEntry {
            if elementName == "title" && parent == "feed" && !trimmed.isEmpty {
                feedChannelTitle = trimmed
            }
        } else {
            switch elementName {
            case "yt:videoId":
                entryVideoId = trimmed
            case "yt:channelId":
                if !trimmed.isEmpty { entryChannelId = trimmed }
            case "title" where parent == "entry":
                entryTitle = trimmed
            case "name" where parent == "author":
                entryAuthorName = trimmed
            case "published" where parent == "entry":
                entryPublished = trimmed
            case "entry":
                if !entryVideoId.isEmpty {
                    let publishedDate = (try? Self.isoStyleWithFractional.parse(entryPublished))
                        ?? (try? Self.isoStyleStandard.parse(entryPublished))
                        ?? Date()
                    let thumb = entryThumbnailURL.flatMap(URL.init(string:))
                        ?? URL(string: "https://i.ytimg.com/vi/\(entryVideoId)/hqdefault.jpg")
                    items.append(
                        VideoItem(
                            id: entryVideoId,
                            title: entryTitle.isEmpty ? "제목 없음" : entryTitle,
                            channelId: entryChannelId,
                            channelTitle: entryAuthorName.isEmpty ? feedChannelTitle : entryAuthorName,
                            duration: nil,
                            thumbnailURL: thumb,
                            publishedAt: publishedDate,
                            playability: .playable,
                            isShortHint: entryIsShortHint
                        )
                    )
                }
                inEntry = false
            default:
                break
            }
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
        currentText = ""
    }
}
