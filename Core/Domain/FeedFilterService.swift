import Foundation

/// Applies Clean Feed rules (Shorts removal + keyword/regex filtering) to video feeds.
struct FeedFilterService: Sendable {
    private let regexCache: RegexCacheActor

    init(regexCache: RegexCacheActor) {
        self.regexCache = regexCache
    }

    func filter(
        videos: [VideoItem],
        rules: [FilterRuleDTO],
        hideShorts: Bool
    ) async -> [VideoItem] {
        let activeRules = rules.filter(\.isEnabled)
        var filtered: [VideoItem] = []
        filtered.reserveCapacity(videos.count)

        for video in videos {
            if hideShorts && isLikelyShort(video) {
                continue
            }
            if await matchesAnyRule(video: video, rules: activeRules) {
                continue
            }
            filtered.append(video)
        }
        return filtered
    }

    private func isLikelyShort(_ video: VideoItem) -> Bool {
        if video.isShortHint == true {
            return true
        }
        if let duration = video.duration, duration > 0, duration <= 60 {
            return true
        }
        return false
    }

    private func matchesAnyRule(video: VideoItem, rules: [FilterRuleDTO]) async -> Bool {
        for rule in rules {
            let candidates: [String]
            switch rule.targetScope {
            case .titleOnly:
                candidates = [video.title]
            case .channelNameOnly:
                candidates = [video.channelTitle]
            case .all:
                candidates = [video.title, video.channelTitle]
            }

            if rule.isRegex {
                for text in candidates {
                    if await regexCache.matches(pattern: rule.keyword, in: text) {
                        return true
                    }
                }
            } else {
                for text in candidates {
                    if text.localizedCaseInsensitiveContains(rule.keyword) {
                        return true
                    }
                }
            }
        }
        return false
    }
}
