import SwiftUI
import UIKit

/// Root container holding the 5-tab UI and the single persistent `PlayerRenderHostView` across all 4 modes.
struct AppRootView: View {
    let bootstrapResult: AppContainerBootstrapResult
    let coordinator: PlaybackCoordinator
    let repository: CompositeVideoRepository
    let persistence: any PersistenceWorkerProtocol
    let importer: any SubscriptionImporterProtocol
    let keychain: any KeychainStoreProtocol
    let resolver: any StreamResolverProtocol
    let filterService: FeedFilterService

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("defaultStartTab") private var defaultStartTab: Int = 0

    @State private var selectedTab: Int = 0
    @State private var didApplyInitialTab = false
    @State private var brightnessController = BrightnessController()
    @State private var volumeController = SystemVolumeController()

    private let tabBarHeight: CGFloat = 49
    private let miniPlayerHeight: CGFloat = 64

    var body: some View {
        GeometryReader { geometry in
            let safeInsets = geometry.safeAreaInsets
            let containerSize = geometry.size

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    recoveryBannerIfNeeded

                    TabView(selection: $selectedTab) {
                        HomeFeedView(
                            repository: repository,
                            persistence: persistence,
                            filterService: filterService,
                            coordinator: coordinator
                        )
                        .tabItem { Label("홈", systemImage: "house.fill") }
                        .tag(0)

                        SubscriptionsView(
                            repository: repository,
                            persistence: persistence,
                            filterService: filterService,
                            coordinator: coordinator
                        )
                        .tabItem { Label("구독", systemImage: "play.square.stack.fill") }
                        .tag(1)

                        SearchView(
                            repository: repository,
                            persistence: persistence,
                            filterService: filterService,
                            coordinator: coordinator
                        )
                        .tabItem { Label("검색", systemImage: "magnifyingglass") }
                        .tag(2)

                        LibraryView(
                            persistence: persistence,
                            coordinator: coordinator
                        )
                        .tabItem { Label("보관함", systemImage: "books.vertical.fill") }
                        .tag(3)

                        SettingsView(
                            keychain: keychain,
                            repository: repository,
                            resolver: resolver,
                            persistence: persistence,
                            importer: importer,
                            coordinator: coordinator
                        )
                        .tabItem { Label("설정", systemImage: "gearshape.fill") }
                        .tag(4)
                    }
                }

                // Inline & Fullscreen detail overlay background & controls
                if coordinator.displayMode == .inline || coordinator.displayMode == .fullscreen {
                    PlayerDetailOverlayView(
                        coordinator: coordinator,
                        persistence: persistence,
                        brightnessController: brightnessController,
                        volumeController: volumeController
                    )
                    .frame(width: containerSize.width, height: containerSize.height)
                    .background(coordinator.displayMode == .fullscreen ? Color.black : Color(uiColor: .systemBackground))
                    .defersSystemGestures(on: coordinator.displayMode == .fullscreen ? [.top, .bottom] : [])
                }

                // Mini-player docked bar above the tab bar
                if coordinator.displayMode == .miniPlayer {
                    miniPlayerBar(containerSize: containerSize, safeBottom: safeInsets.bottom)
                }

                // Single persistent PlayerRenderHostView (never conditionally removed from hierarchy)
                let renderFrame = frameForRenderHost(
                    mode: coordinator.displayMode,
                    containerSize: containerSize,
                    safeInsets: safeInsets
                )
                PlayerRenderHostView { surface in
                    coordinator.attachRenderSurface(surface)
                }
                .frame(width: renderFrame.width, height: renderFrame.height)
                .clipShape(RoundedRectangle(cornerRadius: coordinator.displayMode == .miniPlayer ? 6 : 0))
                .offset(x: renderFrame.minX, y: renderFrame.minY)
                .opacity(coordinator.displayMode == .hidden ? 0 : 1)
                .allowsHitTesting(coordinator.displayMode != .hidden && coordinator.isUsingCompatibilityWebMode)
                .animation(.easeInOut(duration: 0.22), value: coordinator.displayMode)
            }
        }
        .onAppear {
            if !didApplyInitialTab {
                didApplyInitialTab = true
                selectedTab = defaultStartTab
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            coordinator.handleScenePhaseChange(newPhase)
        }
    }

    @ViewBuilder
    private var recoveryBannerIfNeeded: some View {
        if bootstrapResult.isFallbackInMemory {
            Text("로컬 데이터베이스를 복구할 수 없어 임시 메모리 모드로 실행 중입니다.")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.red)
        } else if bootstrapResult.didRecoverFromCorruptedStore {
            Text("손상된 로컬 저장소를 초기화하여 복구했습니다.")
                .font(.caption.bold())
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.yellow)
        }
    }

    private func miniPlayerBar(containerSize: CGSize, safeBottom: CGFloat) -> some View {
        let barY = containerSize.height - tabBarHeight - safeBottom - miniPlayerHeight
        return HStack(spacing: 10) {
            Color.clear
                .frame(width: 114, height: miniPlayerHeight)

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.currentVideo?.title ?? "")
                    .font(.caption.bold())
                    .lineLimit(1)
                Text(coordinator.currentVideo?.channelTitle ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                coordinator.togglePlayPause()
            } label: {
                let isPlaying: Bool = {
                    if case .playing = coordinator.playbackState { return true }
                    return false
                }()
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .padding(8)
            }

            Button {
                coordinator.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .padding(8)
            }
        }
        .padding(.trailing, 8)
        .frame(width: containerSize.width, height: miniPlayerHeight)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture {
            coordinator.setDisplayMode(.inline)
        }
        .offset(y: max(0, barY))
    }

    private func frameForRenderHost(
        mode: PlayerDisplayMode,
        containerSize: CGSize,
        safeInsets: EdgeInsets
    ) -> CGRect {
        switch mode {
        case .hidden:
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .inline:
            let w = max(1, containerSize.width)
            let h = w * 9.0 / 16.0
            return CGRect(x: 0, y: 0, width: w, height: h)
        case .miniPlayer:
            let barY = max(0, containerSize.height - tabBarHeight - safeInsets.bottom - miniPlayerHeight)
            return CGRect(x: 0, y: barY, width: 114, height: miniPlayerHeight)
        case .fullscreen:
            return CGRect(x: 0, y: 0, width: max(1, containerSize.width), height: max(1, containerSize.height))
        }
    }
}
