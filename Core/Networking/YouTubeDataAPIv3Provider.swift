import Foundation

/// YouTube Data API v3 client supporting 50-ID batching, LA-midnight quota reset, and bundle headers.
actor YouTubeDataAPIv3Provider {
    private let httpClient: HTTPResilienceClient
    private let keychain: any KeychainStoreProtocol
    private let now: @Sendable () -> Date
    private let bundleIdentifierProvider: @Sendable () -> String

    private(set) var quotaResetAt: Date?
    private var lastObservedAPIKey: String?

    init(
        httpClient: HTTPResilienceClient,
        keychain: any KeychainStoreProtocol,
        now: @escaping @Sendable () -> Date = { Date() },
        bundleIdentifierProvider: @escaping @Sendable () -> String = {
            Bundle.main.bundleIdentifier ?? "com.personal.ytadvanced.app"
        }
    ) {
        self.httpClient = httpClient
        self.keychain = keychain
        self.now = now
        self.bundleIdentifierProvider = bundleIdentifierProvider
        self.lastObservedAPIKey = keychain.loadAPIKey()
    }

    func notifyAPIKeyUpdated() {
        lastObservedAPIKey = keychain.loadAPIKey()
        quotaResetAt = nil
    }

    func hasAPIKey() -> Bool {
        syncKeyChangeIfNeeded()
        return lastObservedAPIKey != nil
    }

    func currentQuotaResetDate() -> Date? {
        if let resetAt = quotaResetAt, now() >= resetAt {
            quotaResetAt = nil
            return nil
        }
        return quotaResetAt
    }

    func fetchVideoDetails(videoIds: [String]) async throws -> [VideoItem] {
        guard !videoIds.isEmpty else { return [] }
        let apiKey = try requireAvailableAPIKey()

        var results: [VideoItem] = []
        let chunkSize = 50
        var offset = 0

        while offset < videoIds.count {
            let end = min(offset + chunkSize, videoIds.count)
            let chunk = Array(videoIds[offset..<end])
            offset = end

            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
            components.queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails,status,liveStreamingDetails"),
                URLQueryItem(name: "id", value: chunk.joined(separator: ",")),
                URLQueryItem(name: "key", value: apiKey)
            ]

            let data = try await sendAuthorizedGET(url: components.url!)
            let decoded = try JSONDecoder().decode(YTVideosListResponse.self, from: data)
            results.append(contentsOf: decoded.items.map { $0.toVideoItem() })
        }

        return results
    }

    func searchVideos(query: String, pageToken: String?) async throws -> VideoPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return VideoPage(items: [], nextPageToken: nil) }
        let apiKey = try requireAvailableAPIKey()

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        var queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "maxResults", value: "25"),
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "key", value: apiKey)
        ]
        if let pageToken, !pageToken.isEmpty {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = queryItems

        let data = try await sendAuthorizedGET(url: components.url!)
        let searchResponse = try JSONDecoder().decode(YTSearchListResponse.self, from: data)

        let ids = searchResponse.items.compactMap(\.id.videoId)
        guard !ids.isEmpty else {
            return VideoPage(items: [], nextPageToken: searchResponse.nextPageToken)
        }

        // Enrich search items via 1-unit videos.list batch so duration & playability are populated.
        let detailed = try await fetchVideoDetails(videoIds: ids)
        let detailedById = Dictionary(uniqueKeysWithValues: detailed.map { ($0.id, $0) })
        let ordered = ids.compactMap { detailedById[$0] }

        return VideoPage(items: ordered, nextPageToken: searchResponse.nextPageToken)
    }

    func resolveChannelId(fromInput input: String) async throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Self.extractDirectChannelID(from: trimmed) {
            return direct
        }

        let handle = Self.extractHandle(from: trimmed)
        if let handle {
            if let apiKey = try? requireAvailableAPIKey() {
                var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
                components.queryItems = [
                    URLQueryItem(name: "part", value: "id"),
                    URLQueryItem(name: "forHandle", value: handle),
                    URLQueryItem(name: "key", value: apiKey)
                ]
                let data = try await sendAuthorizedGET(url: components.url!)
                let response = try JSONDecoder().decode(YTChannelsListResponse.self, from: data)
                if let resolved = response.items.first?.id {
                    return resolved
                }
            }
            // Fallback to HTML meta lookup when API key is missing, quota-exhausted, or unresolved.
            if let resolved = try await resolveChannelIDFromHTML(handleOrURL: trimmed) {
                return resolved
            }
        } else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            if let resolved = try await resolveChannelIDFromHTML(handleOrURL: trimmed) {
                return resolved
            }
        }

        throw VideoDataError.channelNotFound(input)
    }

    // MARK: - Quota Calculation (America/Los_Angeles Midnight)

    static func nextLosAngelesMidnight(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        let laTimeZone = TimeZone(identifier: "America/Los_Angeles") ?? TimeZone(secondsFromGMT: -28_800)!
        calendar.timeZone = laTimeZone

        let startOfTodayLA = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfTodayLA)
            ?? date.addingTimeInterval(86_400)
    }

    // MARK: - Private Helpers

    private func syncKeyChangeIfNeeded() {
        let currentKey = keychain.loadAPIKey()
        if currentKey != lastObservedAPIKey {
            lastObservedAPIKey = currentKey
            quotaResetAt = nil
        }
    }

    private func requireAvailableAPIKey() throws -> String {
        syncKeyChangeIfNeeded()
        if let resetAt = currentQuotaResetDate() {
            throw VideoDataError.quotaExceeded(resetAt: resetAt)
        }
        guard let key = lastObservedAPIKey, !key.isEmpty else {
            throw VideoDataError.invalidAPIKey
        }
        return key
    }

    private func sendAuthorizedGET(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(bundleIdentifierProvider(), forHTTPHeaderField: "X-Ios-Bundle-Identifier")

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await httpClient.perform(request, coalesce: true)
        } catch let urlErr as URLError where urlErr.code == .notConnectedToInternet {
            throw VideoDataError.networkUnavailable
        }

        if (200...299).contains(response.statusCode) {
            return data
        }

        if let errPayload = try? JSONDecoder().decode(YTAPIErrorEnvelope.self, from: data) {
            let reasons = Set(errPayload.error.errors.map(\.reason))
            if response.statusCode == 403 &&
                (reasons.contains("quotaExceeded") || reasons.contains("dailyLimitExceeded")) {
                let resetAt = Self.nextLosAngelesMidnight(after: now())
                quotaResetAt = resetAt
                throw VideoDataError.quotaExceeded(resetAt: resetAt)
            }
            if reasons.contains("keyInvalid") ||
                reasons.contains("accessNotConfigured") ||
                reasons.contains("ipRefererBlocked") ||
                response.statusCode == 400 ||
                response.statusCode == 401 {
                throw VideoDataError.invalidAPIKey
            }
            throw VideoDataError.httpError(statusCode: response.statusCode, message: errPayload.error.message)
        }

        throw VideoDataError.httpError(statusCode: response.statusCode, message: "YouTube API request failed")
    }

    private func resolveChannelIDFromHTML(handleOrURL: String) async throws -> String? {
        let urlString: String
        if handleOrURL.hasPrefix("http://") || handleOrURL.hasPrefix("https://") {
            urlString = handleOrURL
        } else {
            let normalized = handleOrURL.hasPrefix("@") ? handleOrURL : "@\(handleOrURL)"
            urlString = "https://www.youtube.com/\(normalized)"
        }
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await httpClient.perform(request, coalesce: true)
        guard (200...299).contains(response.statusCode) else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        return Self.extractChannelIDFromMetaHTML(html)
    }

    private static func extractDirectChannelID(from input: String) -> String? {
        if let match = input.range(of: #"UC[A-Za-z0-9_-]{22}"#, options: .regularExpression) {
            if input == String(input[match]) || input.contains("/channel/") {
                return String(input[match])
            }
        }
        return nil
    }

    private static func extractHandle(from input: String) -> String? {
        if input.hasPrefix("@") {
            return input.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        }
        if let url = URL(string: input),
           let segment = url.pathComponents.first(where: { $0.hasPrefix("@") }) {
            return segment
        }
        return nil
    }

    private static func extractChannelIDFromMetaHTML(_ html: String) -> String? {
        let patterns = [
            #"itemprop="channelId"\s+content="(UC[A-Za-z0-9_-]{22})""#,
            #""externalId"\s*:\s*"(UC[A-Za-z0-9_-]{22})""#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, range: range),
               match.numberOfRanges > 1,
               let swiftRange = Range(match.range(at: 1), in: html) {
                return String(html[swiftRange])
            }
        }
        return nil
    }
}

// MARK: - YouTube Data API v3 DTOs

private struct YTAPIErrorEnvelope: Decodable {
    let error: YTAPIErrorBody
    struct YTAPIErrorBody: Decodable {
        let message: String
        let errors: [YTAPIErrorItem]
    }
    struct YTAPIErrorItem: Decodable {
        let reason: String
    }
}

private struct YTSearchListResponse: Decodable {
    let nextPageToken: String?
    let items: [YTSearchItem]
    struct YTSearchItem: Decodable {
        let id: YTSearchID
    }
    struct YTSearchID: Decodable {
        let videoId: String?
    }
}

private struct YTChannelsListResponse: Decodable {
    let items: [YTChannelIDItem]
    struct YTChannelIDItem: Decodable {
        let id: String
    }
}

private struct YTVideosListResponse: Decodable {
    let items: [YTVideoResource]

    struct YTVideoResource: Decodable {
        let id: String
        let snippet: YTSnippet
        let contentDetails: YTContentDetails?
        let status: YTStatus?
        let liveStreamingDetails: YTLiveStreamingDetails?

        func toVideoItem() -> VideoItem {
            let liveState = snippet.liveBroadcastContent ?? "none"
            let isLiveOrUpcoming = (liveState == "live" || liveState == "upcoming")
            let parsedDuration = contentDetails?.duration.flatMap {
                ISO8601DurationParser.parse($0, isLiveOrUpcoming: isLiveOrUpcoming)
            }

            let playability: VideoPlayability
            if status?.privacyStatus == "private" {
                playability = .restricted(.privateOrDeleted)
            } else if contentDetails?.contentRating?.ytRating == "ytAgeRestricted" {
                playability = .restricted(.ageRestricted)
            } else if status?.embeddable == false {
                playability = .restricted(.embedDisabled)
            } else if liveState == "live" {
                let viewers = liveStreamingDetails?.concurrentViewers.flatMap(Int.init)
                playability = .live(concurrentViewers: viewers)
            } else if liveState == "upcoming" {
                let scheduled = liveStreamingDetails?.scheduledStartTime.flatMap {
                    ISO8601DateFormatter().date(from: $0)
                }
                playability = .upcoming(scheduledStart: scheduled)
            } else {
                playability = .playable
            }

            let thumbStr = snippet.thumbnails?.high?.url
                ?? snippet.thumbnails?.medium?.url
                ?? snippet.thumbnails?.default?.url
            let published = snippet.publishedAt.flatMap {
                ISO8601DateFormatter().date(from: $0)
            } ?? Date()

            let isShortHint: Bool? = parsedDuration.map { $0 > 0 && $0 <= 60 }

            return VideoItem(
                id: id,
                title: snippet.title,
                channelId: snippet.channelId,
                channelTitle: snippet.channelTitle,
                duration: parsedDuration,
                thumbnailURL: thumbStr.flatMap(URL.init(string:)),
                publishedAt: published,
                playability: playability,
                isShortHint: isShortHint
            )
        }
    }

    struct YTSnippet: Decodable {
        let title: String
        let channelId: String
        let channelTitle: String
        let publishedAt: String?
        let liveBroadcastContent: String?
        let thumbnails: YTThumbnails?
    }

    struct YTThumbnails: Decodable {
        let `default`: YTThumb?
        let medium: YTThumb?
        let high: YTThumb?
    }

    struct YTThumb: Decodable {
        let url: String
    }

    struct YTContentDetails: Decodable {
        let duration: String?
        let contentRating: YTContentRating?
    }

    struct YTContentRating: Decodable {
        let ytRating: String?
    }

    struct YTStatus: Decodable {
        let privacyStatus: String?
        let embeddable: Bool?
    }

    struct YTLiveStreamingDetails: Decodable {
        let scheduledStartTime: String?
        let concurrentViewers: String?
    }
}
