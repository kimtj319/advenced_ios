import SwiftUI
import UIKit

/// Detailed player view providing the 16:9 placeholder aligned to `PlayerRenderHostView`, HUD controls, and metadata.
struct PlayerDetailOverlayView: View {
    let coordinator: PlaybackCoordinator
    let persistence: any PersistenceWorkerProtocol
    let brightnessController: BrightnessController
    let volumeController: SystemVolumeController

    @State private var showControlsHUD = true
    @State private var hudAutoHideTask: Task<Void, Never>?
    @State private var seekIndicatorText: String?
    @State private var seekIndicatorTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var scrubPosition: TimeInterval = 0

    @State private var bookmarks: [BookmarkDTO] = []
    @State private var showAddBookmarkSheet = false
    @State private var newBookmarkNote = ""

    var body: some View {
        VStack(spacing: 0) {
            if coordinator.displayMode == .inline {
                inlineVideoControlBox
                ScrollView {
                    metadataAndQueueSection
                        .padding()
                }
                .background(Color(uiColor: .systemBackground))
            } else if coordinator.displayMode == .fullscreen {
                fullscreenControlBox
            }
        }
        .sheet(isPresented: $showAddBookmarkSheet) {
            addBookmarkSheet
        }
        .task(id: coordinator.currentVideo?.id) {
            await loadBookmarks()
        }
        .onChange(of: coordinator.displayMode) { _, newMode in
            if newMode != .fullscreen {
                brightnessController.restoreOriginalBrightness()
            }
        }
    }

    // MARK: - Video Surface Overlay & Controls

    private var inlineVideoControlBox: some View {
        ZStack {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            videoOverlayLayers(isFullscreen: false)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    private var fullscreenControlBox: some View {
        ZStack {
            Color.clear
                .ignoresSafeArea()
            videoOverlayLayers(isFullscreen: true)
        }
    }

    private func videoOverlayLayers(isFullscreen: Bool) -> some View {
        ZStack {
            PlayerGestureOverlay(
                isFullscreen: isFullscreen,
                excludedBottomHeight: 64,
                onWindowSceneAttached: { scene in
                    brightnessController.attach(to: scene)
                },
                onGestureEvent: { event in
                    handleGesture(event, isFullscreen: isFullscreen)
                }
            )

            VolumeBridgeView(controller: volumeController)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)

            if coordinator.isTempSpeedBoostActive {
                VStack {
                    Text("2.0x 배속 재생 중")
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 14)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            if let seekIndicatorText {
                Text(seekIndicatorText)
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.65), in: Capsule())
                    .allowsHitTesting(false)
            }

            if showControlsHUD {
                controlsHUD(isFullscreen: isFullscreen)
            }
        }
    }

    private func controlsHUD(isFullscreen: Bool) -> some View {
        VStack(spacing: 0) {
            // Top Bar
            HStack(spacing: 12) {
                Button {
                    if isFullscreen {
                        coordinator.setDisplayMode(.inline)
                    } else {
                        coordinator.setDisplayMode(.miniPlayer)
                    }
                } label: {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "chevron.down")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                }

                if coordinator.isUsingCompatibilityWebMode {
                    Text("호환 모드 (IFrame Embed)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.85), in: Capsule())
                }

                if coordinator.hasFullVideoSponsorBadge {
                    Text("영상 전체 스폰서 포함")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.85), in: Capsule())
                }

                Spacer()

                if coordinator.activeCapabilities.contains(.nativePiP) {
                    Button {
                        coordinator.startPiP()
                    } label: {
                        Image(systemName: "pip.enter")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, isFullscreen ? 12 : 6)

            Spacer()

            // Center Transport Controls
            HStack(spacing: 36) {
                Button {
                    coordinator.playPreviousInQueue()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }

                Button {
                    coordinator.togglePlayPause()
                    scheduleHUDAutoHide()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.white)
                }

                Button {
                    coordinator.playNextInQueue()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
            }

            Spacer()

            // Bottom Timeline & Fullscreen Toggle (64pt exclusion zone)
            VStack(spacing: 6) {
                timelineRow
                HStack {
                    speedMenu
                    Spacer()
                    Button {
                        coordinator.setDisplayMode(isFullscreen ? .inline : .fullscreen)
                    } label: {
                        Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, isFullscreen ? 16 : 8)
            .frame(minHeight: 64)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .background(Color.black.opacity(0.28))
    }

    @ViewBuilder
    private var timelineRow: some View {
        switch coordinator.durationInfo {
        case .finite(let total) where total.isFinite && total > 0:
            HStack(spacing: 8) {
                Text(formatTime(isScrubbing ? scrubPosition : coordinator.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)

                ZStack(alignment: .leading) {
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubPosition : min(coordinator.currentTime, total) },
                            set: { newVal in
                                isScrubbing = true
                                scrubPosition = newVal
                            }
                        ),
                        in: 0...total,
                        onEditingChanged: { editing in
                            if !editing {
                                let target = scrubPosition
                                isScrubbing = false
                                Task { await coordinator.seek(to: target, isManual: true) }
                            }
                        }
                    )
                    .tint(.red)

                    GeometryReader { geo in
                        ForEach(coordinator.mergedSkipIntervals) { seg in
                            let x = CGFloat(seg.startTime / total) * geo.size.width
                            let w = max(2, CGFloat((seg.endTime - seg.startTime) / total) * geo.size.width)
                            Rectangle()
                                .fill(Color.green.opacity(0.75))
                                .frame(width: w, height: 4)
                                .offset(x: x, y: geo.size.height / 2 - 2)
                                .allowsHitTesting(false)
                        }
                        ForEach(coordinator.highlightPoints) { poi in
                            let x = CGFloat(poi.timestamp / total) * geo.size.width
                            Circle()
                                .fill(Color.purple)
                                .frame(width: 7, height: 7)
                                .offset(x: x - 3.5, y: geo.size.height / 2 - 3.5)
                                .allowsHitTesting(false)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .frame(height: 28)

                Text(formatTime(total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
            }

        case .live(let seekableRange):
            HStack(spacing: 8) {
                Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.15), in: Capsule())

                if let range = seekableRange, range.upperBound > range.lowerBound {
                    Slider(
                        value: Binding(
                            get: { min(max(coordinator.currentTime, range.lowerBound), range.upperBound) },
                            set: { newVal in
                                Task { await coordinator.seek(to: newVal, isManual: true) }
                            }
                        ),
                        in: range
                    )
                    .tint(.red)
                } else {
                    Spacer()
                }
            }

        case .unknown, .finite:
            HStack {
                Text(formatTime(coordinator.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                Spacer()
                ProgressView()
                    .tint(.white)
            }
        }
    }

    private var speedMenu: some View {
        Menu {
            let rates: [Float] = coordinator.activeCapabilities.contains(.arbitraryPlaybackRate)
                ? [0.25, 0.5, 0.75, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
                : [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

            ForEach(rates, id: \.self) { rateValue in
                Button {
                    coordinator.setUserPreferredRate(rateValue)
                } label: {
                    if abs(coordinator.userPreferredRate - rateValue) < 0.01 {
                        Label(String(format: "%.2gx", rateValue), systemImage: "checkmark")
                    } else {
                        Text(String(format: "%.2gx", rateValue))
                    }
                }
            }
        } label: {
            Text(String(format: "%.2gx", coordinator.userPreferredRate))
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.2), in: Capsule())
        }
    }

    // MARK: - Metadata, RYD, A-B Loop, Bookmarks & Queue

    private var metadataAndQueueSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let video = coordinator.currentVideo {
                Text(video.title)
                    .font(.headline)
                Text(video.channelTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            dislikeMetricsView

            if case .failed(let err) = coordinator.playbackState {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(String(describing: err))
                        .font(.caption)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if !coordinator.highlightPoints.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(coordinator.highlightPoints) { poi in
                            Button {
                                Task { await coordinator.seek(to: poi.timestamp, isManual: true) }
                            } label: {
                                Label("하이라이트 \(formatTime(poi.timestamp))", systemImage: "sparkles")
                                    .font(.caption.bold())
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                        }
                    }
                }
            }

            playbackCapabilityControls
            bookmarksSection
            queueSection
        }
    }

    @ViewBuilder
    private var dislikeMetricsView: some View {
        switch coordinator.dislikeState {
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("평가 정보 불러오는 중...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .available(let metrics):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) {
                    Label("\(metrics.likes.formatted())", systemImage: "hand.thumbsup")
                    Label("\(metrics.dislikes.formatted())", systemImage: "hand.thumbsdown")
                    Spacer()
                    Text("조회수 \(metrics.viewCount.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)

                ProgressView(value: metrics.likeRatio)
                    .tint(.blue)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

        case .unavailable:
            HStack(spacing: 12) {
                Label("-", systemImage: "hand.thumbsup")
                Label("-", systemImage: "hand.thumbsdown")
                Text("RYD 집계 불가")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }

    private var playbackCapabilityControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("재생 제어 및 구간 반복")
                .font(.subheadline.bold())

            HStack(spacing: 8) {
                Button("A 설정") {
                    coordinator.setPointA()
                }
                .buttonStyle(.bordered)

                Button("B 설정") {
                    coordinator.setPointB()
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.pendingLoopPointA == nil)

                if coordinator.abLoopRange != nil || coordinator.pendingLoopPointA != nil {
                    Button("반복 해제") {
                        coordinator.clearABLoop()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            if let loop = coordinator.abLoopRange {
                Text("A-B 반복 활성: \(formatTime(loop.pointA)) ~ \(formatTime(loop.pointB))")
                    .font(.caption)
                    .foregroundStyle(.blue)
            } else if let a = coordinator.pendingLoopPointA {
                Text("A 지점 설정됨: \(formatTime(a)) (B는 1초 이상 뒤로 지정)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if coordinator.activeCapabilities.contains(.qualitySelection),
               !coordinator.availableQualities.isEmpty {
                HStack {
                    Text("화질")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("화질", selection: Binding(
                        get: { coordinator.selectedQuality?.id ?? "auto" },
                        set: { id in
                            if let match = coordinator.availableQualities.first(where: { $0.id == id }) {
                                Task { await coordinator.selectQuality(match) }
                            }
                        }
                    )) {
                        ForEach(coordinator.availableQualities) { quality in
                            Text(quality.label).tag(quality.id)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if coordinator.activeCapabilities.contains(.audioTrackSelection),
               coordinator.availableAudioTracks.count > 1 {
                Menu("오디오 트랙: \(coordinator.selectedAudioTrack?.displayName ?? "기본")") {
                    ForEach(coordinator.availableAudioTracks) { track in
                        Button(track.displayName) {
                            Task { await coordinator.selectAudioTrack(track) }
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("타임스탬프 북마크")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    newBookmarkNote = ""
                    showAddBookmarkSheet = true
                } label: {
                    Label("현재 시각 저장", systemImage: "bookmark.fill")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
            }

            if bookmarks.isEmpty {
                Text("저장된 북마크가 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bookmarks) { bm in
                    HStack {
                        Button {
                            Task { await coordinator.seek(to: bm.timestamp, isManual: true) }
                        } label: {
                            HStack {
                                Text(formatTime(bm.timestamp))
                                    .font(.caption.monospacedDigit().bold())
                                    .foregroundStyle(.blue)
                                Text(bm.note)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task {
                                try? await persistence.deleteBookmark(id: bm.id)
                                await loadBookmarks()
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("재생 대기열 (\(coordinator.queueManager.items.count))")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    coordinator.queueManager.isShuffled.toggle()
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(coordinator.queueManager.isShuffled ? Color.red : Color.secondary)
                }
                Button {
                    let modes = RepeatMode.allCases
                    if let idx = modes.firstIndex(of: coordinator.queueManager.repeatMode) {
                        coordinator.queueManager.repeatMode = modes[(idx + 1) % modes.count]
                    }
                } label: {
                    Image(systemName: coordinator.queueManager.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(coordinator.queueManager.repeatMode == .off ? Color.secondary : Color.red)
                }
            }

            ForEach(Array(coordinator.queueManager.items.enumerated()), id: \.element.id) { index, item in
                HStack {
                    Button {
                        coordinator.playQueue(coordinator.queueManager.items, startIndex: index)
                    } label: {
                        HStack {
                            if coordinator.queueManager.currentIndex == index {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.red)
                            }
                            VStack(alignment: .leading) {
                                Text(item.title)
                                    .font(.caption.bold())
                                    .lineLimit(1)
                                Text(item.channelTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var addBookmarkSheet: some View {
        NavigationStack {
            Form {
                Section("타임스탬프: \(formatTime(coordinator.currentTime))") {
                    TextField("메모를 입력하세요", text: $newBookmarkNote)
                }
            }
            .navigationTitle("북마크 추가")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { showAddBookmarkSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        guard let video = coordinator.currentVideo else { return }
                        let dto = BookmarkDTO(
                            id: UUID(),
                            videoId: video.id,
                            timestamp: coordinator.currentTime,
                            note: newBookmarkNote.isEmpty ? "북마크" : newBookmarkNote,
                            createdAt: .now
                        )
                        Task {
                            try? await persistence.addBookmark(dto)
                            await loadBookmarks()
                            showAddBookmarkSheet = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var isPlaying: Bool {
        if case .playing = coordinator.playbackState { return true }
        return false
    }

    private func handleGesture(_ event: PlayerGestureEvent, isFullscreen: Bool) {
        switch event {
        case .toggleControls:
            showControlsHUD.toggle()
            if showControlsHUD {
                scheduleHUDAutoHide()
            }
        case .seekStep(let seconds, _):
            showSeekFeedback(seconds >= 0 ? "+\(Int(seconds))초" : "\(Int(seconds))초")
            Task { await coordinator.seekRelative(seconds) }
        case .speedBoostChanged(let active):
            coordinator.setTemporarySpeedBoost(active)
        case .brightnessDelta(let delta):
            let level = brightnessController.adjust(by: delta)
            showSeekFeedback("밝기 \(Int(level * 100))%")
        case .volumeDelta(let delta):
            let level = volumeController.adjust(by: delta)
            showSeekFeedback("볼륨 \(Int(level * 100))%")
        case .verticalTransition(let translationY, let velocityY, let ended):
            guard ended else { return }
            if !isFullscreen {
                if translationY < -45 || velocityY < -450 {
                    coordinator.setDisplayMode(.fullscreen)
                } else if translationY > 45 || velocityY > 450 {
                    coordinator.setDisplayMode(.miniPlayer)
                }
            } else if translationY > 55 || velocityY > 500 {
                coordinator.setDisplayMode(.inline)
            }
        }
    }

    private func scheduleHUDAutoHide() {
        hudAutoHideTask?.cancel()
        hudAutoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, isPlaying, !isScrubbing else { return }
            showControlsHUD = false
        }
    }

    private func showSeekFeedback(_ text: String) {
        seekIndicatorText = text
        seekIndicatorTask?.cancel()
        seekIndicatorTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            seekIndicatorText = nil
        }
    }

    private func loadBookmarks() async {
        guard let videoId = coordinator.currentVideo?.id else {
            bookmarks = []
            return
        }
        bookmarks = (try? await persistence.fetchBookmarks(videoId: videoId)) ?? []
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
