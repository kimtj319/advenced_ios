import Foundation

enum RuleArbitrationAction: Equatable, Sendable {
    case none
    case seekTo(TimeInterval, reason: SeekReason)
    case setSystemMute(Bool)

    enum SeekReason: Equatable, Sendable {
        case abLoopWrap
        case sponsorSkip(category: SponsorCategory, segmentUUID: String)
    }
}

/// Arbitrates A-B loop wrapping, SponsorBlock interval merging/skipping, and mute state resync.
@MainActor
final class PlaybackRuleArbitrator {
    private(set) var mergedSkipIntervals: [MergedSkipInterval] = []
    private(set) var muteSegments: [SponsorSegment] = []
    private(set) var highlightPoints: [SponsorHighlightPoint] = []
    private(set) var hasFullVideoSponsor: Bool = false
    var abLoopRange: ABLoopRange?
    private(set) var isSystemMutedBySponsor: Bool = false

    private var suppressedSkipUUIDs: Set<String> = []
    private var lastManualSeekAt: Date?
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func reset() {
        mergedSkipIntervals = []
        muteSegments = []
        highlightPoints = []
        hasFullVideoSponsor = false
        abLoopRange = nil
        isSystemMutedBySponsor = false
        suppressedSkipUUIDs.removeAll()
        lastManualSeekAt = nil
    }

    func configure(segments: [SponsorSegment], enabledCategories: Set<SponsorCategory>) {
        let filtered = segments.filter { enabledCategories.contains($0.category) }

        // Separate .poi, .full, .mute, and .skip.
        highlightPoints = filtered
            .filter { $0.actionType == .poi }
            .sorted { $0.startTime < $1.startTime }
            .map { SponsorHighlightPoint(uuid: $0.uuid, timestamp: $0.startTime) }

        hasFullVideoSponsor = filtered.contains { $0.actionType == .full }

        muteSegments = filtered
            .filter { $0.actionType == .mute && $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }

        let skipSegments = filtered
            .filter { $0.actionType == .skip && $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }

        mergedSkipIntervals = Self.mergeSkipSegments(skipSegments)
    }

    func allBoundaryTimes() -> [TimeInterval] {
        var times: [TimeInterval] = []
        if let loop = abLoopRange {
            times.append(loop.pointB)
        }
        for interval in mergedSkipIntervals {
            times.append(interval.startTime)
        }
        for mute in muteSegments {
            times.append(mute.startTime)
            times.append(mute.endTime)
        }
        let sorted = times.filter { $0.isFinite && $0 >= 0 }.sorted()
        var deduped: [TimeInterval] = []
        for t in sorted {
            if let last = deduped.last, abs(t - last) < 0.05 {
                continue
            }
            deduped.append(t)
        }
        return deduped
    }

    func notifyManualSeek(to targetTime: TimeInterval) {
        lastManualSeekAt = now()
        for interval in mergedSkipIntervals {
            if targetTime >= interval.startTime && targetTime < interval.endTime {
                suppressedSkipUUIDs.formUnion(interval.sourceUUIDs)
            }
        }
    }

    func evaluateBoundaryCrossed(at currentTime: TimeInterval) -> [RuleArbitrationAction] {
        // Priority 1: A-B Loop always overrides SponsorBlock.
        if let loop = abLoopRange, currentTime >= loop.pointB - 0.15 {
            var actions: [RuleArbitrationAction] = [.seekTo(loop.pointA, reason: .abLoopWrap)]
            if let muteAction = evaluateMuteState(at: loop.pointA) {
                actions.append(muteAction)
            }
            return actions
        }

        // Priority 2: SponsorBlock .skip intervals (unless manually sought inside within 2s or suppressed).
        let isWithinRecentManualSeek: Bool = {
            guard let lastManualSeekAt else { return false }
            return now().timeIntervalSince(lastManualSeekAt) < 2.0
        }()

        for interval in mergedSkipIntervals {
            guard currentTime >= interval.startTime - 0.15 && currentTime < interval.endTime - 0.1 else {
                continue
            }

            // Skip intervals that conflict with an active A-B Loop are ignored to prevent ping-pong.
            if let loop = abLoopRange {
                let enclosesA = interval.startTime <= loop.pointA && interval.endTime > loop.pointA
                let escapesB = interval.endTime >= loop.pointB - 0.2
                if enclosesA || escapesB {
                    continue
                }
            }

            let uuids = Set(interval.sourceUUIDs)
            if !uuids.isDisjoint(with: suppressedSkipUUIDs) || isWithinRecentManualSeek {
                suppressedSkipUUIDs.formUnion(uuids)
                continue
            }

            suppressedSkipUUIDs.formUnion(uuids)
            let primaryCategory = interval.categories.first ?? .sponsor
            let primaryUUID = interval.sourceUUIDs.first ?? interval.id
            var actions: [RuleArbitrationAction] = [
                .seekTo(interval.endTime, reason: .sponsorSkip(category: primaryCategory, segmentUUID: primaryUUID))
            ]
            if let muteAction = evaluateMuteState(at: interval.endTime) {
                actions.append(muteAction)
            }
            return actions
        }

        // Priority 3: SponsorBlock .mute boundary check.
        if let muteAction = evaluateMuteState(at: currentTime) {
            return [muteAction]
        }

        return []
    }

    func evaluateMuteState(at currentTime: TimeInterval) -> RuleArbitrationAction? {
        let shouldMute = muteSegments.contains { currentTime >= $0.startTime && currentTime < $0.endTime }
        guard shouldMute != isSystemMutedBySponsor else { return nil }
        isSystemMutedBySponsor = shouldMute
        return .setSystemMute(shouldMute)
    }

    func handleDidPlayToEnd(duration: TimeInterval?) -> RuleArbitrationAction {
        if let loop = abLoopRange {
            return .seekTo(loop.pointA, reason: .abLoopWrap)
        }
        return .none
    }

    // MARK: - Interval Merging

    private static func mergeSkipSegments(_ sorted: [SponsorSegment]) -> [MergedSkipInterval] {
        guard let first = sorted.first else { return [] }

        var result: [MergedSkipInterval] = []
        var currentStart = first.startTime
        var currentEnd = first.endTime
        var currentCategories: [SponsorCategory] = [first.category]
        var currentUUIDs: [String] = [first.uuid]

        for next in sorted.dropFirst() {
            if next.startTime <= currentEnd + 0.5 {
                currentEnd = max(currentEnd, next.endTime)
                if !currentCategories.contains(next.category) {
                    currentCategories.append(next.category)
                }
                currentUUIDs.append(next.uuid)
            } else {
                result.append(
                    MergedSkipInterval(
                        id: currentUUIDs.joined(separator: "+"),
                        startTime: currentStart,
                        endTime: currentEnd,
                        categories: currentCategories,
                        sourceUUIDs: currentUUIDs
                    )
                )
                currentStart = next.startTime
                currentEnd = next.endTime
                currentCategories = [next.category]
                currentUUIDs = [next.uuid]
            }
        }

        result.append(
            MergedSkipInterval(
                id: currentUUIDs.joined(separator: "+"),
                startTime: currentStart,
                endTime: currentEnd,
                categories: currentCategories,
                sourceUUIDs: currentUUIDs
            )
        )
        return result
    }
}
