import Foundation

enum VideoDataError: Error, LocalizedError, Sendable, Equatable {
    case quotaExceeded(resetAt: Date)
    case invalidAPIKey
    case channelNotFound(String)
    case httpError(statusCode: Int, message: String)
    case networkUnavailable
    case parsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .quotaExceeded(let resetAt):
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "YouTube API 할당량을 초과했습니다. 리셋 예정: \(formatter.string(from: resetAt))"
        case .invalidAPIKey:
            return "유효하지 않거나 제한된 YouTube Data API 키입니다."
        case .channelNotFound(let input):
            return "채널을 찾을 수 없습니다: \(input)"
        case .httpError(let code, let message):
            return "네트워크 오류 (HTTP \(code)): \(message)"
        case .networkUnavailable:
            return "네트워크 연결을 확인할 수 없습니다."
        case .parsingFailed(let detail):
            return "응답 데이터를 해석할 수 없습니다: \(detail)"
        }
    }
}

protocol VideoDataProvider: Sendable {
    func fetchChannelFeed(channelId: String, forceRefresh: Bool) async throws -> [VideoItem]
    func fetchVideoDetails(videoIds: [String]) async throws -> [VideoItem]
    func searchVideos(query: String, pageToken: String?) async throws -> VideoPage
    func resolveChannelId(fromInput input: String) async throws -> String
}

/// Parses YouTube Data API v3 ISO-8601 duration strings such as `PT1H2M30S`, `P1DT2H`, or `P0D`.
struct ISO8601DurationParser: Sendable {
    private static let pattern = #"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"#

    static func parse(_ raw: String, isLiveOrUpcoming: Bool = false) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range) else {
            return nil
        }

        func captureInt(at index: Int) -> Int {
            let subRange = match.range(at: index)
            guard subRange.location != NSNotFound,
                  let swiftRange = Range(subRange, in: trimmed) else {
                return 0
            }
            return Int(trimmed[swiftRange]) ?? 0
        }

        let days = captureInt(at: 1)
        let hours = captureInt(at: 2)
        let minutes = captureInt(at: 3)
        let seconds = captureInt(at: 4)

        let total = TimeInterval(days * 86_400 + hours * 3_600 + minutes * 60 + seconds)
        if total <= 0 && isLiveOrUpcoming {
            return nil
        }
        return total > 0 ? total : (isLiveOrUpcoming ? nil : 0)
    }
}
