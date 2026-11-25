import SwiftUI

/// Search view supporting YouTube Data API v3 pagination and graceful quota reset notices.
struct SearchView: View {
    let repository: CompositeVideoRepository
    let persistence: any PersistenceWorkerProtocol
    let filterService: FeedFilterService
    let coordinator: PlaybackCoordinator

    @AppStorage("hideShorts") private var hideShorts: Bool = true
    @State private var query = ""
    @State private var results: [VideoItem] = []
    @State private var nextPageToken: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.caption)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12))
                }

                List {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, video in
                        VideoRowView(video: video)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                coordinator.playQueue(results, startIndex: index)
                            }
                            .onAppear {
                                if index == results.count - 1 {
                                    Task { await loadMoreIfNeeded() }
                                }
                            }
                    }

                    if isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if results.isEmpty && isLoading {
                        ProgressView("검색 중...")
                    } else if results.isEmpty && query.isEmpty {
                        ContentUnavailableView(
                            "영상 검색",
                            systemImage: "magnifyingglass",
                            description: Text("설정에서 YouTube Data API v3 키를 등록하면 검색을 사용할 수 있습니다.")
                        )
                    }
                }
            }
            .navigationTitle("검색")
            .searchable(text: $query, prompt: "YouTube 검색")
            .onSubmit(of: .search) {
                Task { await performSearch() }
            }
        }
    }

    private func performSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        nextPageToken = nil
        defer { isLoading = false }

        do {
            let page = try await repository.searchVideos(query: trimmed, pageToken: nil)
            let rules = (try? await persistence.fetchFilterRules()) ?? []
            results = await filterService.filter(videos: page.items, rules: rules, hideShorts: hideShorts)
            nextPageToken = page.nextPageToken
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMoreIfNeeded() async {
        guard !isLoading,
              !isLoadingMore,
              let token = nextPageToken,
              !token.isEmpty else {
            return
        }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await repository.searchVideos(query: query, pageToken: token)
            let rules = (try? await persistence.fetchFilterRules()) ?? []
            let filtered = await filterService.filter(videos: page.items, rules: rules, hideShorts: hideShorts)
            let existingIDs = Set(results.map(\.id))
            results.append(contentsOf: filtered.filter { !existingIDs.contains($0.id) })
            nextPageToken = page.nextPageToken
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
