import SwiftUI

/// Local library displaying watch history, ordered local playlists, and timestamped bookmarks.
struct LibraryView: View {
    let persistence: any PersistenceWorkerProtocol
    let coordinator: PlaybackCoordinator

    @State private var history: [WatchHistoryDTO] = []
    @State private var playlists: [LocalPlaylistDTO] = []
    @State private var bookmarks: [BookmarkDTO] = []
    @State private var showCreatePlaylistSheet = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("최근 시청 기록") {
                    if history.isEmpty {
                        Text("시청 기록이 없습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(history) { entry in
                            Button {
                                let item = VideoItem(
                                    id: entry.videoId,
                                    title: entry.title,
                                    channelId: entry.channelId,
                                    channelTitle: entry.channelName,
                                    duration: entry.duration > 0 ? entry.duration : nil,
                                    thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(entry.videoId)/hqdefault.jpg")
                                )
                                coordinator.play(video: item)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    HStack {
                                        Text(entry.channelName)
                                        Spacer()
                                        Text(formatTime(entry.lastPosition))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    if entry.duration > 0 {
                                        ProgressView(value: min(1.0, max(0.0, entry.lastPosition / entry.duration)))
                                            .tint(.red)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    if playlists.isEmpty {
                        Text("로컬 재생목록이 없습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(playlists) { playlist in
                            NavigationLink(playlist.name) {
                                PlaylistDetailView(
                                    playlist: playlist,
                                    persistence: persistence,
                                    coordinator: coordinator
                                )
                            }
                        }
                        .onDelete { offsets in
                            Task {
                                for idx in offsets {
                                    try? await persistence.deletePlaylist(id: playlists[idx].id)
                                }
                                await reloadLibrary()
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("로컬 재생목록")
                        Spacer()
                        Button("새 재생목록") {
                            newPlaylistName = ""
                            showCreatePlaylistSheet = true
                        }
                        .font(.caption)
                    }
                }

                Section("북마크") {
                    if bookmarks.isEmpty {
                        Text("저장된 타임스탬프 북마크가 없습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bookmarks) { bm in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(bm.note)
                                        .font(.subheadline)
                                    Text("Video: \(bm.videoId) · \(formatTime(bm.timestamp))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .onDelete { offsets in
                            Task {
                                for idx in offsets {
                                    try? await persistence.deleteBookmark(id: bookmarks[idx].id)
                                }
                                await reloadLibrary()
                            }
                        }
                    }
                }
            }
            .navigationTitle("보관함")
            .sheet(isPresented: $showCreatePlaylistSheet) {
                NavigationStack {
                    Form {
                        TextField("재생목록 이름", text: $newPlaylistName)
                    }
                    .navigationTitle("새 재생목록")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("취소") { showCreatePlaylistSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("생성") {
                                Task {
                                    _ = try? await persistence.createPlaylist(name: newPlaylistName)
                                    showCreatePlaylistSheet = false
                                    await reloadLibrary()
                                }
                            }
                        }
                    }
                }
            }
            .task {
                await reloadLibrary()
            }
            .task {
                for await domain in persistence.changeStream() {
                    if domain == .watchHistory || domain == .playlists || domain == .bookmarks {
                        await reloadLibrary()
                    }
                }
            }
        }
    }

    private func reloadLibrary() async {
        history = (try? await persistence.fetchRecentWatchHistory(limit: 100)) ?? []
        playlists = (try? await persistence.fetchPlaylists()) ?? []
        bookmarks = (try? await persistence.fetchAllBookmarks()) ?? []
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PlaylistDetailView: View {
    let playlist: LocalPlaylistDTO
    let persistence: any PersistenceWorkerProtocol
    let coordinator: PlaybackCoordinator

    @State private var items: [PlaylistItemDTO]

    init(
        playlist: LocalPlaylistDTO,
        persistence: any PersistenceWorkerProtocol,
        coordinator: PlaybackCoordinator
    ) {
        self.playlist = playlist
        self.persistence = persistence
        self.coordinator = coordinator
        _items = State(initialValue: playlist.items)
    }

    var body: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button(item.title) {
                    let queue = items.map {
                        VideoItem(
                            id: $0.videoId,
                            title: $0.title,
                            channelId: "",
                            channelTitle: playlist.name
                        )
                    }
                    coordinator.playQueue(queue, startIndex: index)
                }
            }
            .onMove { source, destination in
                items.move(fromOffsets: source, toOffset: destination)
                let orderedIds = items.map(\.videoId)
                Task {
                    try? await persistence.reorderPlaylistItems(playlistId: playlist.id, orderedVideoIds: orderedIds)
                }
            }
        }
        .navigationTitle(playlist.name)
        .toolbar {
            EditButton()
        }
    }
}
