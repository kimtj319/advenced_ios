import Foundation

protocol ReturnDislikeClientProtocol: Sendable {
    func fetchMetrics(for videoID: String) async -> DislikeState
}

/// Fetches Return YouTube Dislike metrics while distinguishing `.unavailable` from zero dislikes.
actor ReturnDislikeClient: ReturnDislikeClientProtocol {
    private let httpClient: HTTPResilienceClient
    private let now: @Sendable () -> Date
    private var cache: [String: (metrics: DislikeMetrics, cachedAt: Date)] = [:]
    private let cacheTTL: TimeInterval = 900 // 15 minutes

    init(
        httpClient: HTTPResilienceClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.httpClient = httpClient
        self.now = now
    }

    func fetchMetrics(for videoID: String) async -> DislikeState {
        let currentDate = now()
        if let entry = cache[videoID], currentDate.timeIntervalSince(entry.cachedAt) < cacheTTL {
            return .available(entry.metrics)
        }

        var components = URLComponents(string: "https://returnyoutubedislikeapi.com/votes")!
        components.queryItems = [URLQueryItem(name: "videoId", value: videoID)]
        guard let url = components.url else { return .unavailable }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3.5

        do {
            let (data, response) = try await httpClient.perform(request, coalesce: true)
            guard (200...299).contains(response.statusCode) else {
                return .unavailable
            }
            let dto = try JSONDecoder().decode(RYDResponseDTO.self, from: data)
            let metrics = DislikeMetrics(
                videoID: videoID,
                likes: max(0, dto.likes),
                dislikes: max(0, dto.dislikes),
                viewCount: max(0, dto.viewCount),
                rating: dto.rating
            )
            cache[videoID] = (metrics, currentDate)
            return .available(metrics)
        } catch {
            return .unavailable
        }
    }
}

private struct RYDResponseDTO: Decodable {
    let likes: Int
    let dislikes: Int
    let viewCount: Int64
    let rating: Double
}
