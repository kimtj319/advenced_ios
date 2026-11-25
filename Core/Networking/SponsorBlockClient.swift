import CryptoKit
import Foundation

protocol SponsorBlockClientProtocol: Sendable {
    func fetchSegments(for videoID: String, categories: [SponsorCategory]) async -> [SponsorSegment]
}

/// Fetches SponsorBlock segments via k-anonymity 4-hex SHA-256 prefix without blocking playback.
actor SponsorBlockClient: SponsorBlockClientProtocol {
    private let httpClient: HTTPResilienceClient
    private let now: @Sendable () -> Date
    private var cache: [String: (segments: [SponsorSegment], cachedAt: Date)] = [:]
    private let cacheTTL: TimeInterval = 1_800 // 30 minutes

    init(
        httpClient: HTTPResilienceClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.httpClient = httpClient
        self.now = now
    }

    static func sha256HexPrefix4(for videoID: String) -> String {
        let digest = SHA256.hash(data: Data(videoID.utf8))
        let fullHex = digest.map { String(format: "%02x", $0) }.joined()
        return String(fullHex.prefix(4))
    }

    func fetchSegments(
        for videoID: String,
        categories: [SponsorCategory] = [.sponsor, .selfpromo, .interaction, .intro, .outro, .poiHighlight]
    ) async -> [SponsorSegment] {
        let currentDate = now()
        let cacheKey = "\(videoID)|\(categories.map(\.rawValue).sorted().joined(separator: ","))"
        if let entry = cache[cacheKey], currentDate.timeIntervalSince(entry.cachedAt) < cacheTTL {
            return entry.segments
        }

        let prefix4 = Self.sha256HexPrefix4(for: videoID)
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(prefix4)")!
        let catsJSON = encodeJSONStringArray(categories.map(\.rawValue))
        let actionsJSON = encodeJSONStringArray([
            SponsorActionType.skip.rawValue,
            SponsorActionType.mute.rawValue,
            SponsorActionType.poi.rawValue,
            SponsorActionType.full.rawValue
        ])
        components.queryItems = [
            URLQueryItem(name: "categories", value: catsJSON),
            URLQueryItem(name: "actionTypes", value: actionsJSON)
        ]

        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.5

        do {
            let (data, response) = try await httpClient.perform(request, coalesce: true)
            if response.statusCode == 404 {
                cache[cacheKey] = ([], currentDate)
                return []
            }
            guard (200...299).contains(response.statusCode) else {
                return []
            }

            let decoded = try JSONDecoder().decode([SBPrefixVideoDTO].self, from: data)
            let matched = decoded
                .first(where: { $0.videoID == videoID })?
                .segments
                .compactMap { dto -> SponsorSegment? in
                    guard dto.segment.count == 2,
                          let category = SponsorCategory(rawValue: dto.category),
                          let action = SponsorActionType(rawValue: dto.actionType) else {
                        return nil
                    }
                    let start = dto.segment[0]
                    let end = dto.segment[1]
                    guard start.isFinite, end.isFinite, start >= 0 else { return nil }
                    if action != .poi && action != .full && end <= start {
                        return nil
                    }
                    return SponsorSegment(
                        uuid: dto.UUID,
                        videoID: videoID,
                        startTime: start,
                        endTime: end,
                        category: category,
                        actionType: action
                    )
                } ?? []

            cache[cacheKey] = (matched, currentDate)
            return matched
        } catch {
            return []
        }
    }

    private func encodeJSONStringArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

private struct SBPrefixVideoDTO: Decodable {
    let videoID: String
    let segments: [SBSegmentDTO]

    struct SBSegmentDTO: Decodable {
        let UUID: String
        let category: String
        let actionType: String
        let segment: [Double]
    }
}
