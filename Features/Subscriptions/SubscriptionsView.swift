import SwiftUI

/// Local subscription feed & channel management without Google account sign-in.
struct SubscriptionsView: View {
    let repository: CompositeVideoRepository
    let persistence: any PersistenceWorkerProtocol
    let filterService: FeedFilterService
    let coordinator: PlaybackCoordinator

    @AppStorage("hideShorts") private var hideShorts: Bool = true
    @State private var channels: [SubscribedChannelDTO] = []
    @State private var selectedChannelID: String?
    @State private var feedVideos: [VideoItem] = []
    @State private var showAddChannelSheet = false
    @State private var channelInput = ""
    @State private var channelNameInput = ""
    @State private var addChannelError: String?
    @State private var isResolving = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !channels.isEmpty {
                    channelStrip
                    Divider()
                }

                List {
                    ForEach(Array(feedVideos.enumerated()), id: \.element.id) { index, video in
                        VideoRowView(video: video)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                coordinator.playQueue(feedVideos, startIndex: index)
                            }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await reloadAll(forceRefresh: true)
                }
            }
            .navigationTitle("구독")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        channelInput = ""
                        channelNameInput = ""
                        addChannelError = nil
                        showAddChannelSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddChannelSheet) {
                addChannelSheet
            }
            .task {
                await reloadAll(forceRefresh: false)
            }
            .task {
                for await domain in persistence.changeStream() {
                    if domain == .subscriptions || domain == .filterRules {
                        await reloadAll(forceRefresh: false)
                    }
                }
            }
        }
    }

    private var channelStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("전체") {
                    selectedChannelID = nil
                    Task { await reloadFeedOnly(forceRefresh: false) }
                }
                .buttonStyle(.borderedProminent)
                .tint(selectedChannelID == nil ? .red : .gray)

                ForEach(channels) { channel in
                    Button(channel.name) {
                        selectedChannelID = channel.channelId
                        Task { await reloadFeedOnly(forceRefresh: false) }
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedChannelID == channel.channelId ? .red : .primary)
                    .contextMenu {
                        Button("구독 삭제", role: .destructive) {
                            Task {
                                try? await persistence.deleteSubscription(channelId: channel.channelId)
                                if selectedChannelID == channel.channelId {
                                    selectedChannelID = nil
                                }
                                await reloadAll(forceRefresh: false)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var addChannelSheet: some View {
        NavigationStack {
            Form {
                Section("채널 정보") {
                    TextField("채널 URL, @핸들 또는 UC... ID", text: $channelInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("표시 이름 (선택)", text: $channelNameInput)
                }

                if let addChannelError {
                    Section {
                        Text(addChannelError)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("구독 채널 추가")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { showAddChannelSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("추가") {
                        Task { await resolveAndSaveChannel() }
                    }
                    .disabled(isResolving || channelInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func resolveAndSaveChannel() async {
        isResolving = true
        defer { isResolving = false }
        addChannelError = nil

        do {
            let resolvedID = try await repository.resolveChannelId(fromInput: channelInput)
            let name = channelNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let dto = SubscribedChannelDTO(
                channelId: resolvedID,
                name: name.isEmpty ? resolvedID : name,
                avatarURLString: nil,
                addedAt: .now,
                lastSyncedAt: nil,
                etag: nil
            )
            try await persistence.upsertSubscriptions([dto])
            showAddChannelSheet = false
            await reloadAll(forceRefresh: false)
        } catch {
            addChannelError = error.localizedDescription
        }
    }

    private func reloadAll(forceRefresh: Bool) async {
        channels = (try? await persistence.fetchSubscriptions()) ?? []
        await reloadFeedOnly(forceRefresh: forceRefresh)
    }

    private func reloadFeedOnly(forceRefresh: Bool) async {
        let targetIDs: [String]
        if let selectedChannelID {
            targetIDs = [selectedChannelID]
        } else {
            targetIDs = channels.map(\.channelId)
        }
        guard !targetIDs.isEmpty else {
            feedVideos = []
            return
        }

        let raw = await repository.fetchCombinedSubscriptionFeed(channelIds: targetIDs, forceRefresh: forceRefresh)
        let rules = (try? await persistence.fetchFilterRules()) ?? []
        feedVideos = await filterService.filter(videos: raw, rules: rules, hideShorts: hideShorts)
    }
}
