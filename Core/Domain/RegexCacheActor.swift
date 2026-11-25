import Foundation

/// Actor-isolated cache for compiled `NSRegularExpression` instances avoiding non-Sendable NSCache leaks.
actor RegexCacheActor {
    private var cache: [String: NSRegularExpression] = [:]

    static func validatePattern(_ pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return (try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])) != nil
    }

    func matches(pattern: String, in text: String) -> Bool {
        let regex: NSRegularExpression
        if let cached = cache[pattern] {
            regex = cached
        } else {
            guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }
            cache[pattern] = compiled
            regex = compiled
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    func clearCache() {
        cache.removeAll()
    }
}
