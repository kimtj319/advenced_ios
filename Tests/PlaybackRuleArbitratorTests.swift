import Foundation
import XCTest
@testable import YouTubeAdvanced

final class PlaybackRuleArbitratorTests: XCTestCase {
    @MainActor
    func testMergeSkipIntervals_OverlappingAndWithinHalfSecond_MergesIntoSingleInterval() {
        let arbitrator = PlaybackRuleArbitrator()
        let segments = [
            SponsorSegment(uuid: "s1", videoID: "v1", startTime: 10.0, endTime: 20.0, category: .sponsor, actionType: .skip),
            SponsorSegment(uuid: "s2", videoID: "v1", startTime: 18.0, endTime: 25.0, category: .selfpromo, actionType: .skip),
            SponsorSegment(uuid: "s3", videoID: "v1", startTime: 25.0, endTime: 30.0, category: .intro, actionType: .skip),
            SponsorSegment(uuid: "s4", videoID: "v1", startTime: 30.4, endTime: 35.0, category: .outro, actionType: .skip)
        ]

        arbitrator.configure(segments: segments, enabledCategories: Set(SponsorCategory.allCases))
        XCTAssertEqual(arbitrator.mergedSkipIntervals.count, 1)
        XCTAssertEqual(arbitrator.mergedSkipIntervals.first?.startTime, 10.0)
        XCTAssertEqual(arbitrator.mergedSkipIntervals.first?.endTime, 35.0)
        XCTAssertEqual(arbitrator.mergedSkipIntervals.first?.sourceUUIDs, ["s1", "s2", "s3", "s4"])
    }

    @MainActor
    func testPOIAndFullSegments_AreExcludedFromAutoSkipAndSeparated() {
        let arbitrator = PlaybackRuleArbitrator()
        let segments = [
            SponsorSegment(uuid: "poi1", videoID: "v1", startTime: 45.0, endTime: 45.0, category: .poiHighlight, actionType: .poi),
            SponsorSegment(uuid: "full1", videoID: "v1", startTime: 0.0, endTime: 0.0, category: .sponsor, actionType: .full)
        ]

        arbitrator.configure(segments: segments, enabledCategories: Set(SponsorCategory.allCases))
        XCTAssertTrue(arbitrator.mergedSkipIntervals.isEmpty)
        XCTAssertEqual(arbitrator.highlightPoints.count, 1)
        XCTAssertEqual(arbitrator.highlightPoints.first?.timestamp, 45.0)
        XCTAssertTrue(arbitrator.hasFullVideoSponsor)
    }

    @MainActor
    func testABLoopTakesPrecedenceOverSponsorSkip() {
        let arbitrator = PlaybackRuleArbitrator()
        let segments = [
            SponsorSegment(uuid: "s1", videoID: "v1", startTime: 20.0, endTime: 40.0, category: .sponsor, actionType: .skip)
        ]
        arbitrator.configure(segments: segments, enabledCategories: Set(SponsorCategory.allCases))
        arbitrator.abLoopRange = ABLoopRange(pointA: 15.0, pointB: 25.0)

        let actions = arbitrator.evaluateBoundaryCrossed(at: 25.0)
        XCTAssertEqual(actions.first, .seekTo(15.0, reason: .abLoopWrap))
    }

    @MainActor
    func testDidPlayToEnd_WhenABLoopActiveNearEnd_WrapsToPointA() {
        let arbitrator = PlaybackRuleArbitrator()
        arbitrator.abLoopRange = ABLoopRange(pointA: 12.0, pointB: 59.8)

        let action = arbitrator.handleDidPlayToEnd(duration: 60.0)
        XCTAssertEqual(action, .seekTo(12.0, reason: .abLoopWrap))
    }

    @MainActor
    func testManualSeekOutOfMuteSegment_ImmediatelyUnmutesSystemMute() {
        let arbitrator = PlaybackRuleArbitrator()
        let segments = [
            SponsorSegment(uuid: "m1", videoID: "v1", startTime: 50.0, endTime: 60.0, category: .sponsor, actionType: .mute)
        ]
        arbitrator.configure(segments: segments, enabledCategories: Set(SponsorCategory.allCases))

        let enterActions = arbitrator.evaluateBoundaryCrossed(at: 50.0)
        XCTAssertEqual(enterActions, [.setSystemMute(true)])
        XCTAssertTrue(arbitrator.isSystemMutedBySponsor)

        let exitAction = arbitrator.evaluateMuteState(at: 80.0)
        XCTAssertEqual(exitAction, .setSystemMute(false))
        XCTAssertFalse(arbitrator.isSystemMutedBySponsor)
    }

    @MainActor
    func testQueueManagerAndRegexFilter() async {
        let queue = QueueManager()
        let v1 = VideoItem(id: "v1", title: "SwiftUI Basics", channelId: "c1", channelTitle: "Dev", duration: 120)
        let v2 = VideoItem(id: "v2", title: "Quick Short", channelId: "c1", channelTitle: "Dev", duration: 45)
        let v3 = VideoItem(id: "v3", title: "Sponsored Leak", channelId: "c2", channelTitle: "News", duration: 300)

        queue.replaceQueue(with: [v1, v2, v3], startIndex: 1)
        XCTAssertEqual(queue.previousAction(currentPlaybackTime: 4.5), .restartCurrent)
        XCTAssertEqual(queue.previousAction(currentPlaybackTime: 1.2), .playPrevious(v1))

        XCTAssertFalse(RegexCacheActor.validatePattern("[invalid"))
        XCTAssertTrue(RegexCacheActor.validatePattern("leak"))

        let filter = FeedFilterService(regexCache: RegexCacheActor())
        let rules = [FilterRuleDTO(id: UUID(), keyword: "leak", isRegex: true, targetScope: .titleOnly, isEnabled: true)]
        let visible = await filter.filter(videos: [v1, v2, v3], rules: rules, hideShorts: true)
        XCTAssertEqual(visible.map(\.id), ["v1"])
    }
}
