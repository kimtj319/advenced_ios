import SwiftUI
import UIKit

/// Home tab displaying merged subscription feeds with Clean Feed filtering applied.
struct HomeFeedView: View {
    let repository: CompositeVideoRepository
    let persistence: any PersistenceWorkerProtocol
    let filterService: FeedFilterService
    let coordinator: PlaybackCoordinator

    @AppStorage("hideShorts") private var hideShorts: Bool = true
    @State private var videos: [VideoItem] = []
    @State private var isLoading = false
    @State private var hasSubscriptions = true

    var body: some View {
        NavigationStack {
            Group {
                if !hasSubscriptions {
                    ContentUnavailableView(
                        "구독 채널이 없습니다",
                        systemImage: "play.rectangle.on.rectangle",
                        description: Text("구독 탭에서 채널을 추가하거나 설정에서 OPML/CSV 파일을 가져오세요.")
                    )
                } else if videos.isEmpty && isLoading {
                    ProgressView("피드 불러오는 중...")
                } else if videos.isEmpty {
                    ContentUnavailableView(
                        "표시할 영상이 없습니다",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("필터 규칙에 의해 모든 영상이 숨겨졌거나 최신 피드가 없습니다.")
                    )
                } else {
                    List(Array(videos.enumerated()), id: \.element.id) { index, video in
                        VideoRowView(video: video)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                coordinator.playQueue(videos, startIndex: index)
                            }
                            .contextMenu {
                                Button("다음에 재생") {
                                    coordinator.queueManager.enqueueNext(video)
                                }
                                Button("대기열 끝에 추가") {
                                    coordinator.queueManager.append(video)
                                }
                            }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await reloadFeed(forceRefresh: true)
                    }
                }
            }
            .navigationTitle("홈")
            .task {
                await reloadFeed(forceRefresh: false)
            }
            .task {
                for await domain in persistence.changeStream() {
                    if domain == .subscriptions || domain == .filterRules {
                        await reloadFeed(forceRefresh: false)
                    }
                }
            }
            .onChange(of: hideShorts) { _, _ in
                Task { await reloadFeed(forceRefresh: false) }
            }
        }
    }

    private func reloadFeed(forceRefresh: Bool) async {
        isLoading = true
        defer { isLoading = false }

        let subscriptions = (try? await persistence.fetchSubscriptions()) ?? []
        hasSubscriptions = !subscriptions.isEmpty
        guard !subscriptions.isEmpty else {
            videos = []
            return
        }

        let rawVideos = await repository.fetchCombinedSubscriptionFeed(
            channelIds: subscriptions.map(\.channelId),
            forceRefresh: forceRefresh
        )
        let rules = (try? await persistence.fetchFilterRules()) ?? []
        videos = await filterService.filter(videos: rawVideos, rules: rules, hideShorts: hideShorts)
    }
}

struct VideoRowView: View {
    let video: VideoItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: video.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(16 / 9, contentMode: .fill)
                default:
                    Rectangle().fill(Color(uiColor: .secondarySystemBackground))
                }
            }
            .frame(width: 128, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(video.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if case .live = video.playability {
                        Text("LIVE")
                            .font(.caption2.bold())
                            .foregroundStyle(.red)
                    } else if let dur = video.duration, dur > 0 {
                        Text(formatDuration(dur))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(video.publishedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
