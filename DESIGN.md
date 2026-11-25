# iOS YouTube Advanced 클라이언트 설계 문서 (Swift / SwiftUI)

## 1. 프로젝트 개요 및 목표
- **목표**: iOS(iPhone)용 고기능 커스텀 YouTube 클라이언트 설계 (개인 사용 / 학습 / 사이드로딩 목적)
- **기술 스택**: Swift 5 언어 모드 (`SWIFT_VERSION: "5.0"`, `SWIFT_STRICT_CONCURRENCY: complete`), SwiftUI (`@Observable`), Swift Concurrency (`async/await`), AVFoundation / AVKit / MediaPlayer / WebKit / CryptoKit, SwiftData
- **최소 지원 버전**: iOS 17.0+ (`@Observable`, `SwiftData`, `UIWindowScene.requestGeometryUpdate`, `.defersSystemGestures(on:)`)
- **배포 방식**: Windows 로컬 작성 → GitHub Actions(`macos-15`, XcodeGen) 시뮬레이터 단위 테스트 및 미서명 `.ipa` 아카이브 → AltStore / SideStore / Sideloadly 사이드로딩

> **범위 및 재생 모델 원칙**
> 본 설계는 공식 앱 바이너리 변조나 DRM 우회가 아닌, **독립적인 Clean-Room 네이티브 SwiftUI 앱 아키텍처**를 기준으로 작성되었습니다.
> - **`AVPlayerEngine` (네이티브 풀 기능)**: 사용자가 직접 지정한 HLS(`.m3u8`) / muxed MP4·M4A 스트림 URL 또는 자가 호스팅/로컬 호환 인스턴스(Piped/Invidious 등) 엔드포인트를 재생할 때 사용합니다. (`AVPlayer`는 분리된 DASH video+audio WebM/VP9 스트림을 네이티브 병합 재생하지 않습니다.)
> - **`WKWebViewEngine` (기본 호환 모드)**: 별도 스트림 엔드포인트가 없는 일반 YouTube 영상은 공식 IFrame 임베드(`https://www.youtube-nocookie.com` origin, `playsinline=1`)로 재생합니다.

---

## 2. 핵심 기능 명세 (Core Features)

### 2.1 커스텀 플레이어 UX & 제스처 중재 (Player)
동일 축(수직) 제스처 간섭과 iOS 시스템 엣지(제어 센터/알림 센터/홈 인디케이터) 충돌을 막기 위해 영역 분리 및 UIKit 제스처 중재기를 사용합니다.
- **영역 분리형 제스처 컨트롤 (`PlayerGestureOverlay`)**
  - **안전 제외 영역**: 상·하단 `safeAreaInsets + 14pt` 시스템 엣지 및 하단 타임라인 스크러버(`64pt`)는 배경 제스처 인식에서 제외.
  - **컨트롤 오버레이 히트테스트 분리**: 재생/일시정지·스크러버 등 실제 버튼이 차지한 영역은 SwiftUI 컨트롤이 우선 처리하고, 빈 배경 탭/제스처만 `PlayerGestureOverlay`로 전달.
  - **인라인(Portrait) 모드**: 밝기/볼륨 스와이프 비활성화 → 상향 스와이프(풀스크린 진입), 하향 스와이프(미니플레이어 축소).
  - **풀스크린 모드**: 좌측 32%(밝기), 우측 32%(볼륨), 중앙 36%(하향 스와이프 시 풀스크린 해제). 수직 판별 각도 가드(`|vy| > |vx| * 1.25`) 적용.
  - **시스템 밝기/볼륨 연동 (`BrightnessController`, `VolumeBridgeView`)**: `UIScreen.main` 대신 `window.windowScene?.screen` 사용, `UIScreen.brightnessDidChangeNotification` 감시(제어 센터 수동 변경 존중), `willResignActive`/풀스크린 종료 시 원래 밝기 복원. 볼륨은 `alpha = 0.01`, `frame = CGRect(x: -1000, y: -1000, width: 1, height: 1)` `MPVolumeView` 내부 `UISlider` 브리지 사용(시뮬레이터 등 `UISlider` 부재 시 안전 no-op).
  - **단일 탭 vs 더블 탭 누적 탐색 & 롱프레스 2.0x**:
    - 기본 상태: 단일 탭 = 컨트롤 HUD 토글, 좌/우 더블 탭 = `700ms` 누적 탐색 모드(`isSeekAccumulating`) 진입 + 즉시 ±10초 탐색.
    - 누적 탐색 중: 3번째 탭부터 단일 탭 대기 지연 없이 즉시 ±10초 누적, 마지막 탭 후 `700ms` 경과 시 일반 모드 복귀.
    - 롱프레스(`minimumPressDuration = 0.35s`, `allowableMovement = 18pt`): `.began` 시 현재 `userPreferredRate`를 스냅샷 저장 후 `2.0x` 전환, `.ended`/`.cancelled`/`.failed` 모든 종료 상태에서 `userPreferredRate`로 복원.
  - **오리엔테이션 & 시스템 제스처 지연**:
    - SwiftUI 플레이어 컨테이너에 `.defersSystemGestures(on: displayMode == .fullscreen ? [.top, .bottom] : [])` 적용.
    - `OrientationManager` + `AppDelegate`(`@UIApplicationDelegateAdaptor`) 연동으로 `supportedInterfaceOrientationsFor`를 제어하고, `UIWindowScene.requestGeometryUpdate(.iOS(interfaceOrientations:))`와 레이아웃 전환을 직렬화.
- **세밀한 재생 설정 (`EngineCapabilities` 기반 동적 UI)**
  - `AVPlayerEngine`: `0.25x` ~ `3.0x` (0.05x/0.1x 단위), 화질/오디오 트랙 선택, 정밀 A-B 구간 반복(`B - A >= 1.0s` 가드).
  - `WKWebViewEngine`: `0.25x` ~ `2.0x` 이산 프리셋(`0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0`), HTML5 PiP, ~250ms JS 타임 폴링 기반 탐색/루프(지원 한계 UI 배지 안내).
  - **라이브 스트림 안전 처리**: `durationInfo`가 `.unknown` 또는 `.live`일 때 일반 `0...duration` `Slider` 바인딩 금지(`● LIVE` 배지 표시 + `.live(let range)`에서 `range != nil`일 때만 DVR 시크 허용).
- **단일 영속 렌더 호스트 (`PlayerRenderHostView`) & 레이아웃 규칙 (`PlayerDisplayMode`)**
  - `AppRootView` 최상위 `ZStack`에 단일 영속 `PlayerRenderHostView`를 배치하고, `PlayerDisplayMode`(`.hidden`, `.inline`, `.miniPlayer`, `.fullscreen`)에 따라 `frame`/`offset`/`cornerRadius`/`opacity`만 애니메이션합니다(`matchedGeometryEffect`나 조건부 `if/switch` 뷰 분기 사용 금지 — `UIViewRepresentable` 재생성으로 인한 PiP 중단 및 `WKWebView` 리로드 방지).
  - **모드별 좌표·안전영역 규칙**:
    - `.hidden`: `opacity(0)`, `allowsHitTesting(false)`, `frame(width: 1, height: 1)`.
    - `.inline`: 상세 화면(`PlayerDetailOverlayView`) 상단(`safeAreaInsets.top` 직하단)에 `width: containerWidth, height: containerWidth * 9.0 / 16.0`, `cornerRadius: 0`으로 배치. 상세 화면 내부는 상단에 동일한 `16:9` 투명 레이아웃 플레이스홀더(`Color.clear.aspectRatio(16/9, contentMode: .fit)`)를 두고 그 아래에 메타데이터/RYD/북마크/큐 `ScrollView`를 배치하여 영상 영역과 스크롤 콘텐츠가 겹치지 않게 합니다.
    - `.miniPlayer`: 탭바 상단(`bottom = tabBarHeight(49pt) + safeAreaInsets.bottom`)에 높이 `64pt` 미니플레이어 바를 도킹하고, `PlayerRenderHostView`는 미니플레이어 좌측 슬롯(`width: 114, height: 64, cornerRadius: 6`)으로 프레임을 축소합니다(우측 영역은 제목·채널명·재생/일시정지·닫기 버튼).
    - `.fullscreen`: `frame(width: screenWidth, height: screenHeight)`, `.ignoresSafeArea(.all)`, `cornerRadius: 0`.

### 2.2 백그라운드 재생 및 PiP (Picture-in-Picture)
- `AVAudioSession`: `.playback`, `.mode = .moviePlayback`, `options: []` (`.mixWithOthers` 배제 — 자동 PiP 비활성화 방지).
- `AVPictureInPictureController` 연동 및 백그라운드 전환 시 `playerLayer.player` 안전 분기:
  - `handleBackgroundTransition(backgroundAudioEnabled:autoPiPEnabled:)`: `autoPiPEnabled == false && !isPiPActive && backgroundAudioEnabled == true`인 경우에만 `playerLayer.player = nil` 분리, 포그라운드 복귀 시 재연결.
- **NowPlaying 소유권 인계 (`NowPlayingManager`)**:
  - `AVPlayerEngine`(`capabilities.contains(.managesNowPlaying)`) 활성화 시 `NowPlayingManager.acquireOwnership(for:video:)`를 호출하여 `MPRemoteCommandCenter` 핸들러 토큰을 등록하고 상태 전이·시크·배속·아트워크(`currentVideoID` 일치 검증)를 갱신합니다.
  - `WKWebViewEngine`으로 전환하거나 재생 종료(`stopAndClear()`) 시 반드시 `NowPlayingManager.relinquishOwnership()`을 먼저 호출해 (1) 진행 중인 아트워크 다운로드 `Task` 취소, (2) 등록된 모든 `MPRemoteCommandCenter` 타겟 토큰(`removeTarget`) 해제, (3) `MPNowPlayingInfoCenter.default().nowPlayingInfo = nil` 초기화를 수행함으로써 WebContent 프로세스의 `MediaSession`과 리모트 커맨드가 충돌하지 않도록 보장합니다.

### 2.3 커뮤니티 데이터 및 UX 확장
- **SponsorBlock 연동**: `CryptoKit.SHA256` 해시의 **앞 4자리 hex 문자열(`4 hex chars`, 2바이트)** prefix API 호출(`GET /api/skipSegments/{sha256Prefix4}?categories=[...]&actionTypes=["skip","mute","poi","full"]`).
  - 주의: `SHA256.hash(data: Data(videoID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(4)`로 정확히 4글자 hex를 추출해야 합니다(`digest.prefix(4)`는 4바이트=8글자 hex가 되므로 금지).
  - HTTP `404`를 정상 빈 결과(`[]`)로 캐싱 처리, 응답 배열에서 `item.videoID == targetVideoID` 필터링, `.poi`(포인트 하이라이트, `startTime == endTime`)는 `SponsorHighlightPoint`로 분리, `.full`은 자동 스킵에서 제외하고 배지로만 노출.
- **Return YouTube Dislike (RYD) 연동**: `DislikeState` (`.loading` / `.available(DislikeMetrics)` / `.unavailable`) 3상태 모델로 장애 시 "0개" 오표시 방지.
- **피드 필터링 (Clean Feed)**: Shorts 숨김(`isShortHint == true` 또는 `duration <= 60`), 키워드/정규식(저장 전 `NSRegularExpression` 문법 검증 + Thread-safe `RegexCacheActor` 캐싱) 필터, 시작 탭 설정.

### 2.4 로컬 데이터 및 개인화
- **로컬 구독 관리**: YouTube RSS Feed(`0 unit`, 디스크 캐시 지원) + OPML/YouTube Takeout CSV 가져오기(`UTType(filenameExtension: "opml") ?? .xml`, `startAccessingSecurityScopedResource()`, UTF-8 BOM 제거·RFC 4180 따옴표 이스케이프 파싱·행 단위 부분 실패 복구 리포트 `SubscriptionImportResult` 지원).
- **시청 기록 & 이어보기**: `lastPosition` 스로틀링 저장(10초 간격 & 5초 이상 변화 시, 일시정지/시크/백그라운드 진입/종료 시 즉시 플러시).
- **로컬 재생목록 & 타임스탬프 북마크**: `LocalPlaylistEntity`, `PlaylistItemEntity`(`sortOrder` 명시), `BookmarkEntity`.

---

## 3. 시스템 아키텍처

Clean Architecture + MVVM 패턴 기반으로 레이어를 분리하고, Swift 5 Strict Concurrency(`complete`) 하에서 컴파일/런타임 안전성을 보장합니다. 모든 모듈 경로는 섹션 4의 실제 디렉토리 트리와 1:1 대응합니다.

```text
+-----------------------------------------------------------------------+
|                    Presentation Layer (App/, Features/)               |
|  SwiftUI Views (@MainActor), AppRootView, PlayerRenderHostView,       |
|  PlayerGestureOverlay (UIKit), BrightnessController, OrientationMgr   |
+-----------------------------------+-----------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------+
|                       Domain Layer (Core/Domain/)                     |
|  PlaybackCoordinator (@MainActor @Observable, activeLoadID, dual-eng),|
|  PlaybackRuleArbitrator (A-B Loop > SponsorBlock, mute resync),       |
|  QueueManager, FeedFilterService, RegexCacheActor                     |
+-----------------------------------+-----------------------------------+
                                    |
            +-----------------------+-----------------------+
            v                                               v
+-----------------------------------+   +-------------------------------+
| Media Engine Layer (MediaEngine/) |   |   Data Layer (Core/Models/,   |
|  PlayerEngineProtocol             |   |   Core/Networking/,           |
|   ├─ AVPlayerEngine (Native)      |   |   Core/Persistence/)          |
|   └─ WKWebViewEngine (IFrame)     |   |  CompositeVideoRepository     |
|  PlayableSourceResolver           |   |   ├─ RSSFeedProvider (Disk)   |
|  StreamRecoveryController         |   |   └─ YouTubeDataAPIv3Provider |
|  EngineEventBroadcaster           |   |  SponsorBlockClient (CB)      |
|  AudioSessionManager              |   |  ReturnDislikeClient (CB)     |
|  NowPlayingManager                |   |  PersistenceWorker (Actor)    |
+-----------------------------------+   +-------------------------------+
```

### 3.1 레이어별 상세 계약 (Concrete Contracts)

#### A. Shared Models (`Core/Models/`)
모든 도메인·데이터 전달 모델은 `Sendable` 및 `Equatable`을 준수합니다.

1. **영상 및 재생 소스 모델 (`Core/Models/VideoModels.swift`)**
   ```swift
   enum VideoPlayability: Sendable, Equatable, Codable {
       case playable
       case live(concurrentViewers: Int?)
       case upcoming(scheduledStart: Date?)
       case restricted(RestrictionReason)

       enum RestrictionReason: String, Sendable, Equatable, Codable {
           case privateOrDeleted, regionBlocked, ageRestricted, embedDisabled
       }
   }

   struct VideoItem: Identifiable, Sendable, Equatable, Codable {
       let id: String
       let title: String
       let channelId: String
       let channelTitle: String
       let duration: TimeInterval?        // RSS 피드에서는 nil 허용, 상세 조회 후 보강
       let thumbnailURL: URL?
       let publishedAt: Date
       let playability: VideoPlayability
       let isShortHint: Bool?
   }

   struct VideoPage: Sendable, Equatable {
       let items: [VideoItem]
       let nextPageToken: String?
   }

   enum PlayableSource: Sendable, Equatable {
       case direct(url: URL, format: DirectStreamFormat, headers: [String: String])
       case webEmbed(videoID: String, baseURL: URL) // 기본 baseURL: https://www.youtube-nocookie.com

       enum DirectStreamFormat: String, Sendable, Equatable, Codable {
           case hls, muxedMP4, audioOnly
       }
   }

   enum PlayerDisplayMode: Sendable, Equatable {
       case hidden
       case inline
       case miniPlayer
       case fullscreen
   }
   ```

2. **스트림 엔드포인트 설정 모델 (`Core/Models/StreamEndpointSettings.swift`)**
   ```swift
   enum StreamEndpointKind: String, Sendable, Equatable, Codable, CaseIterable {
       case webEmbedOnly      // 기본값: 항상 WKWebViewEngine (youtube-nocookie.com) 사용
       case pipedAPI          // GET {baseURL}/streams/{videoId} -> hls 또는 muxed MPEG_4 추출
       case invidiousAPI      // GET {baseURL}/api/v1/videos/{videoId} -> hlsUrl 또는 formatStreams(mp4) 추출
       case customTemplate    // 예: https://my.host/stream/{videoId}.m3u8 ({videoId} 치환)
   }

   struct StreamEndpointSettings: Sendable, Equatable, Codable {
       var kind: StreamEndpointKind = .webEmbedOnly
       var endpointURLString: String = ""
       var preferHLS: Bool = true
       var fallbackToWebEmbedOnFailure: Bool = true
   }
   ```

3. **재생 상태 및 오류 모델 (`Core/Models/PlaybackModels.swift`)**
   ```swift
   enum DurationInfo: Equatable, Sendable {
       case unknown
       case finite(TimeInterval)
       case live(seekableRange: ClosedRange<TimeInterval>?)

       var finiteSeconds: TimeInterval? {
           if case .finite(let d) = self, d.isFinite, d > 0 { return d }
           return nil
       }
   }

   enum PauseReason: Equatable, Sendable {
       case user, audioSessionInterruption, audioRouteDisconnected, bufferingTimeout
   }

   enum PlaybackState: Equatable, Sendable {
       case idle
       case loading(loadID: UUID)
       case playing
       case paused(reason: PauseReason)
       case buffering(wasPlaying: Bool)
       case ended
       case failed(PlaybackError)
   }

   enum PlaybackError: Error, Equatable, Sendable {
       case sourceResolutionFailed(String)
       case streamExpired(httpStatus: Int)
       case networkUnavailable
       case unsupportedMediaFormat(osStatus: Int32)
       case mediaServicesReset
       case playbackFailed(domain: String, code: Int, message: String)
       case webViewBridgeFailed(String)
   }

   struct ABLoopRange: Equatable, Sendable {
       let pointA: TimeInterval
       let pointB: TimeInterval

       init?(pointA: TimeInterval, pointB: TimeInterval) {
           guard pointA.isFinite, pointB.isFinite, pointA >= 0, (pointB - pointA) >= 1.0 else {
               return nil
           }
           self.pointA = pointA
           self.pointB = pointB
       }
   }
   ```

4. **SponsorBlock & RYD 모델 (`Core/Models/CommunityModels.swift`)**
   ```swift
   enum SponsorCategory: String, Sendable, Equatable, Codable, CaseIterable {
       case sponsor
       case selfpromo
       case interaction
       case intro
       case outro
       case preview
       case musicOfftopic = "music_offtopic"
       case filler
       case poiHighlight = "poi_highlight"
   }

   enum SponsorActionType: String, Sendable, Equatable, Codable {
       case skip, mute, poi, full
   }

   struct SponsorSegment: Identifiable, Sendable, Equatable, Codable {
       var id: String { uuid }
       let uuid: String
       let videoID: String
       let startTime: TimeInterval
       let endTime: TimeInterval
       let category: SponsorCategory
       let actionType: SponsorActionType
   }

   struct MergedSkipInterval: Identifiable, Sendable, Equatable {
       let id: String
       let startTime: TimeInterval
       let endTime: TimeInterval
       let categories: [SponsorCategory]
       let sourceUUIDs: [String]
   }

   struct SponsorHighlightPoint: Identifiable, Sendable, Equatable {
       var id: String { uuid }
       let uuid: String
       let timestamp: TimeInterval
   }

   struct DislikeMetrics: Sendable, Equatable, Codable {
       let videoID: String
       let likes: Int
       let dislikes: Int
       let viewCount: Int64
       let rating: Double
   }

   enum DislikeState: Sendable, Equatable {
       case loading
       case available(DislikeMetrics)
       case unavailable
   }
   ```

5. **SwiftData 브리지용 `Sendable` DTO & 임포트 결과 (`Core/Models/PersistenceDTOs.swift`)**
   ```swift
   struct WatchHistoryDTO: Identifiable, Sendable, Equatable {
       var id: String { videoId }
       let videoId: String
       let title: String
       let channelId: String
       let channelName: String
       let lastPosition: TimeInterval
       let duration: TimeInterval
       let watchedAt: Date
   }

   struct SubscribedChannelDTO: Identifiable, Sendable, Equatable {
       var id: String { channelId }
       let channelId: String
       let name: String
       let avatarURLString: String?
       let addedAt: Date
       let lastSyncedAt: Date?
       let etag: String?
   }

   struct BookmarkDTO: Identifiable, Sendable, Equatable {
       let id: UUID
       let videoId: String
       let timestamp: TimeInterval
       let note: String
       let createdAt: Date
   }

   enum FilterTargetScope: String, Sendable, Equatable, Codable, CaseIterable {
       case titleOnly, channelNameOnly, all
   }

   struct FilterRuleDTO: Identifiable, Sendable, Equatable {
       let id: UUID
       let keyword: String
       let isRegex: Bool
       let targetScope: FilterTargetScope
       let isEnabled: Bool
   }

   struct PlaylistItemDTO: Identifiable, Sendable, Equatable {
       var id: String { "\(playlistId.uuidString):\(videoId):\(sortOrder)" }
       let playlistId: UUID
       let videoId: String
       let title: String
       let sortOrder: Int
       let addedAt: Date
   }

   struct LocalPlaylistDTO: Identifiable, Sendable, Equatable {
       let id: UUID
       let name: String
       let createdAt: Date
       let items: [PlaylistItemDTO]
   }

   enum PersistenceChangeDomain: Sendable, Equatable {
       case watchHistory, subscriptions, bookmarks, filterRules, playlists
   }

   struct SubscriptionImportRowError: Sendable, Equatable {
       let lineOrElementIndex: Int
       let rawValue: String
       let reason: String
   }

   struct SubscriptionImportResult: Sendable, Equatable {
       let importedCount: Int
       let duplicateSkippedCount: Int
       let failedRows: [SubscriptionImportRowError]
   }
   ```

---

#### B. Domain Layer (`Core/Domain/`)

1. **`QueueManager` (`Core/Domain/QueueManager.swift`)**
   ```swift
   enum RepeatMode: Sendable, Equatable { case off, all, one }

   enum QueuePreviousAction: Equatable, Sendable {
       case restartCurrent       // currentPlaybackTime > 3.0s
       case playPrevious(VideoItem)
       case none
   }

   @MainActor
   protocol QueueManagerProtocol: AnyObject {
       var items: [VideoItem] { get }
       var currentIndex: Int? { get }
       var currentItem: VideoItem? { get }
       var repeatMode: RepeatMode { get set }
       var isShuffled: Bool { get set }
       func replaceQueue(with items: [VideoItem], startIndex: Int)
       func enqueueNext(_ item: VideoItem)
       func append(_ item: VideoItem)
       func remove(at index: Int)
       func move(from source: IndexSet, to destination: Int)
       func advanceToNext() -> VideoItem?
       func previousAction(currentPlaybackTime: TimeInterval) -> QueuePreviousAction
   }
   ```

2. **`PlaybackRuleArbitrator` (`Core/Domain/PlaybackRuleArbitrator.swift`)**
   ```swift
   enum RuleArbitrationAction: Equatable, Sendable {
       case none
       case seekTo(TimeInterval, reason: SeekReason)
       case setSystemMute(Bool)

       enum SeekReason: Equatable, Sendable {
           case abLoopWrap
           case sponsorSkip(category: SponsorCategory, segmentUUID: String)
       }
   }
   ```
   - **병합 및 분리 규칙**:
     - `.skip` 세그먼트는 시작 시각 기준 오름차순 정렬 후 중첩되거나 `0.5s` 이내로 인접한 구간(`next.startTime <= current.endTime + 0.5`)을 단일 `MergedSkipInterval`로 병합합니다(연쇄 시크 루프 방지).
     - `.poi` 세그먼트는 `SponsorHighlightPoint(uuid: segment.uuid, timestamp: segment.startTime)`로 분리하여 타임라인 마커 및 "하이라이트로 이동" 액션에만 사용합니다.
     - `.full` 세그먼트는 자동 스킵에서 제외하고 UI 배지로만 노출합니다.
   - **경계 옵저버 & 우선순위**:
     - `A-B Loop`가 활성화된 경우 `pointB` 경계가 모든 `SponsorBlock` 스킵보다 우선합니다(`A-B Loop > SponsorBlock`).
     - `AVPlayerEngine`에서는 모든 활성 경계 시각(`pointB`, `MergedSkipInterval.startTime`, `.mute` 구간의 `startTime`/`endTime`)을 오름차순 중복 제거하여 `engine.updateBoundaryObservers(times:onCrossed:)`로 등록합니다.
     - **고배속(`3.0x`) 영상 끝지점 루프 보장**: `pointB`가 영상 종료 시각 근처(`duration - 0.3s` 이내)일 때 `didPlayToEnd` 이벤트가 경계 옵저버보다 먼저 도착하면, `.ended`로 전이하지 않고 즉시 `pointA`로 루프 시크 후 재생을 유지합니다.
   - **`.mute` 상태 재동기화 (`evaluateMuteState(at:)`)**:
     - 사용자가 `.mute` 구간 내부에서 구간 외부로 수동 시크하거나, 반대로 외부에서 내부로 시크하거나, SponsorBlock 설정 토글 변경, 또는 `stopAndClear()` 호출 시 경계 통과 여부와 무관하게 **현재 재생 시각 `t`가 활성 `.mute` 구간 내부(`startTime <= t < endTime`)에 있는지 즉시 재계산**하여 `isSystemMutedBySponsor`를 갱신합니다(음소거 고착 방지).

3. **`PlaybackCoordinator` (`Core/Domain/PlaybackCoordinator.swift`)**
   - **듀얼 엔진 DI 생성자 계약**:
     ```swift
     @MainActor
     @Observable
     final class PlaybackCoordinator {
         init(
             nativeEngine: any PlayerEngineProtocol,
             webEngine: any PlayerEngineProtocol,
             resolver: any StreamResolverProtocol,
             recoveryController: StreamRecoveryController,
             ruleArbitrator: PlaybackRuleArbitrator,
             queueManager: any QueueManagerProtocol,
             nowPlayingManager: any NowPlayingManagerProtocol,
             audioSessionManager: any AudioSessionManagerProtocol,
             persistence: any PersistenceWorkerProtocol,
             sponsorBlockClient: any SponsorBlockClientProtocol,
             returnDislikeClient: any ReturnDislikeClientProtocol
         )
     }
     ```
   - **빠른 영상 전환 Race 차단 (`activeLoadID`)**:
     - 사용자가 새 영상을 선택하면 즉시:
       1. 이전 `loadTask?.cancel()` 및 `eventSubscriptionTask?.cancel()`
       2. 신규 `let loadID = UUID(); self.activeLoadID = loadID` 발급 및 `state = .loading(loadID: loadID)` 전환
       3. 현재 활성 엔진의 `stopAndClear()` 즉시 호출(이전 오디오 잔류 차단) 및 `ruleArbitrator.reset()`
       4. 비동기 작업(`resolver.resolve`, `persistence.fetchWatchHistory`, `engine.load`, `sponsorBlockClient.fetchSegments`, `returnDislikeClient.fetchMetrics`)의 모든 `await` 복귀 지점마다 `try Task.checkCancellation()` 및 `guard self.activeLoadID == loadID else { return }` 검증.
   - **듀얼 엔진 전환 시퀀스 (`switchActiveEngine(for source: PlayableSource)`)**:
     - `source`가 `.direct`이면 `nativeEngine`(`AVPlayerEngine`), `.webEmbed`이면 `webEngine`(`WKWebViewEngine`)을 `targetEngine`으로 선택합니다.
     - `activeEngine !== targetEngine`일 때 반드시 다음 순서를 준수합니다:
       1. `previousEngine.stopAndClear()` 호출 (`StreamRecoveryController`에 의한 장애 폴백 시에는 `await previousEngine.teardown()`까지 완료 대기)
       2. `nowPlayingManager.relinquishOwnership()` 호출 (이전 엔진의 `MPRemoteCommandCenter` 타겟 토큰 및 `nowPlayingInfo` 완전 해제)
       3. `renderSurface?.setActiveSurface(source.isDirect ? .avPlayerLayer : .webView)` 및 `targetEngine.attachRenderSurface(renderSurface)` 호출
       4. `activeEngine = targetEngine` 교체 후 `targetEngine.eventStream()` 구독 시작
       5. `targetEngine.capabilities.contains(.managesNowPlaying)`인 경우에만 `nowPlayingManager.acquireOwnership(for: targetEngine, video: currentVideo)` 호출
   - **이어보기 위치(`resumePos`) 판별 안전성**:
     - `PersistenceWorker.fetchWatchPosition(videoId:)`로 조회한 `resumePos`는 `video.duration`이 `nil`(RSS 진입 등)일 수 있으므로, `video.duration`이 있으면 즉시 검사하고 없으면 엔진의 `.durationChanged(let info)` 이벤트에서 `info.finiteSeconds`가 확정된 직후 `resumePos > 3.0 && resumePos < (finiteDuration - 5.0)`일 때만 초기 시크를 수행합니다.

4. **`FeedFilterService` & `RegexCacheActor` (`Core/Domain/FeedFilterService.swift`, `Core/Domain/RegexCacheActor.swift`)**
   - `RegexCacheActor`는 `actor`로 격리되어 `[String: NSRegularExpression]` 딕셔너리를 보관하며, 패턴 컴파일 실패 시 오류를 반환합니다(`NSCache`를 `nonisolated(unsafe)`로 노출하지 않음).
   - `FeedFilterService`는 (1) `hideShorts == true`일 때 `video.isShortHint == true || (video.duration != nil && video.duration! > 0 && video.duration! <= 60)` 항목을 제외하고, (2) 활성화된 `FilterRuleDTO`의 키워드(대소문자 무시 부분 일치) 및 정규식(`RegexCacheActor` 매칭)으로 `FilterTargetScope`를 필터링합니다.

---

#### C. Media Engine Layer (`MediaEngine/`)

1. **렌더 서피스 & 다중 소비자 `PlayerEngineProtocol` (`MediaEngine/PlayerEngineProtocol.swift`)**
   - `MediaEngine` 계층이 SwiftUI 뷰(`PlayerRenderHostView`)에 역방향 의존하지 않고 단위 테스트에서 `MockRenderSurface`를 주입할 수 있도록 `@MainActor protocol PlayerRenderSurfaceProtocol`을 정의합니다.
   ```swift
   enum ActiveRenderSurface: Sendable, Equatable {
       case none
       case avPlayerLayer
       case webView
   }

   @MainActor
   protocol PlayerRenderSurfaceProtocol: AnyObject {
       var playerLayer: AVPlayerLayer { get }
       func attachWebView(_ webView: WKWebView)
       func setActiveSurface(_ surface: ActiveRenderSurface)
   }

   struct EngineCapabilities: OptionSet, Sendable {
       let rawValue: Int
       static let arbitraryPlaybackRate = EngineCapabilities(rawValue: 1 << 0)
       static let nativePiP             = EngineCapabilities(rawValue: 1 << 1)
       static let backgroundAudio       = EngineCapabilities(rawValue: 1 << 2)
       static let qualitySelection      = EngineCapabilities(rawValue: 1 << 3)
       static let audioTrackSelection   = EngineCapabilities(rawValue: 1 << 4)
       static let precisionBoundaries   = EngineCapabilities(rawValue: 1 << 5)
       static let managesNowPlaying     = EngineCapabilities(rawValue: 1 << 6)
   }

   struct QualityOption: Identifiable, Hashable, Sendable {
       let id: String
       let label: String
       let height: Int
       let fps: Float
       let codec: String
   }

   struct AudioTrackOption: Identifiable, Hashable, Sendable {
       let id: String
       let languageCode: String
       let displayName: String
   }

   enum PlaybackEngineEvent: Sendable, Equatable {
       case stateChanged(PlaybackState)
       case timeUpdated(currentTime: TimeInterval, bufferedTime: TimeInterval)
       case durationChanged(DurationInfo)
       case didPlayToEnd
       case streamLikelyExpired(httpStatus: Int)
       case pipStateChanged(isActive: Bool, isPossible: Bool)
   }

   enum SeekPrecision: Sendable { case exact, fast }

   @MainActor
   protocol PlayerEngineProtocol: AnyObject {
       var capabilities: EngineCapabilities { get }
       var state: PlaybackState { get }
       var currentTime: TimeInterval { get }
       var bufferedTime: TimeInterval { get }
       var durationInfo: DurationInfo { get }
       var rate: Float { get }
       var availableQualities: [QualityOption] { get }
       var selectedQuality: QualityOption? { get }
       var availableAudioTracks: [AudioTrackOption] { get }
       var selectedAudioTrack: AudioTrackOption? { get }

       func eventStream() -> AsyncStream<PlaybackEngineEvent>
       func attachRenderSurface(_ surface: (any PlayerRenderSurfaceProtocol)?)
       func load(source: PlayableSource, startAt: TimeInterval?) async throws
       func stopAndClear()
       func play()
       func pause(reason: PauseReason)
       @discardableResult
       func seek(to time: TimeInterval, precision: SeekPrecision) async -> Bool
       func setRate(_ rate: Float)
       func setMuted(_ muted: Bool)
       func selectQuality(_ quality: QualityOption) async throws
       func selectAudioTrack(_ track: AudioTrackOption) async throws
       func updateBoundaryObservers(times: [TimeInterval], onCrossed: @escaping @MainActor (TimeInterval) -> Void)
       func startPiP()
       func stopPiP()
       func handleBackgroundTransition(backgroundAudioEnabled: Bool, autoPiPEnabled: Bool)
       func handleForegroundTransition()
       func teardown() async
   }
   ```

2. **`PlayableSourceResolver` (`MediaEngine/PlayableSourceResolver.swift`)**
   ```swift
   protocol StreamResolverProtocol: Sendable {
       func resolve(video: VideoItem, bypassCache: Bool) async throws -> PlayableSource
       func updateSettings(_ settings: StreamEndpointSettings) async
   }
   ```
   - **엔드포인트 검증 규칙 (`StreamEndpointValidator`)**:
     - 원격 호스트는 반드시 `https://` 스킴만 허용합니다.
     - `http://` 스킴은 `Info.plist`의 `NSAllowsLocalNetworking: true`에 부합하는 로컬 네트워크 호스트(`localhost`, `127.0.0.1`, `::1`, `.local` 접미사, 또는 RFC 1918 사설 IPv4 대역 `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`)인 경우에만 허용합니다.
   - **해석(Resolution) 로직**:
     - `.webEmbedOnly`: 즉시 `.webEmbed(videoID: video.id, baseURL: URL(string: "https://www.youtube-nocookie.com")!)` 반환.
     - `.pipedAPI`: `GET {baseURL}/streams/{video.id}` 호출(타임아웃 `3.5s`). 응답 JSON에서 `preferHLS == true`이고 `hls` URL이 유효하면 `.direct(url: hlsURL, format: .hls, headers: [:])` 반환; 그렇지 않으면 `videoStreams` 배열에서 `videoOnly == false && format == "MPEG_4"`인 최고 화질 항목을 `.direct(url: url, format: .muxedMP4, headers: [:])`로 반환.
     - `.invidiousAPI`: `GET {baseURL}/api/v1/videos/{video.id}` 호출(타임아웃 `3.5s`). 응답 JSON의 `hlsUrl`(`.hls`) 또는 `formatStreams` 중 `container == "mp4"`(`.muxedMP4`) 추출.
     - `.customTemplate`: 템플릿의 `{videoId}`를 `video.id`로 치환 후 확장자(`.m3u8` -> `.hls`, 그 외 -> `.muxedMP4`)에 따라 `.direct` 생성.
     - **실패 처리**: `bypassCache == false`인 초기 로드에서 직접 스트림 해석이 실패하고 `settings.fallbackToWebEmbedOnFailure == true`이면 `.webEmbed`를 반환하며, `StreamRecoveryController`가 재발급(`bypassCache == true`)을 요청한 경우에는 `PlaybackError.sourceResolutionFailed`를 throw하여 복구 컨트롤러가 재시도 횟수를 정확히 카운트하도록 합니다.

3. **Apple API & Swift 5 Strict Concurrency (`complete`) 필수 준수 규칙**:
   - **`addBoundaryTimeObserver` 정확 계약**: Apple SDK 시그니처는 `addBoundaryTimeObserver(forTimes: [NSValue], queue: DispatchQueue?, using: @escaping () -> Void) -> Any`입니다.
     - 빈 배열(`times.isEmpty`)일 때 `addBoundaryTimeObserver`를 호출하면 `NSInvalidArgumentException` 크래시가 발생하므로 반드시 `guard !times.isEmpty else { return }` 가드를 둡니다.
     - 클로저가 경계 시각을 인자로 받지 않으므로, `queue: .main`으로 등록 후 클로저 내부에서 `MainActor.assumeIsolated { let now = player.currentTime().seconds; ... }`로 현재 시각과 가장 가까운 등록 경계(`|now - boundary| <= 0.25s`)를 찾아 `onCrossed(matchedBoundary)`를 호출합니다.
   - **콜백 격리 경계 (Strict Concurrency 컴파일 보장)**:
     - `.main` 큐가 보장되는 콜백(`addPeriodicTimeObserver(queue: .main)`, `addBoundaryTimeObserver(queue: .main)`, `NotificationCenter.addObserver(..., queue: .main)`): 클로저 내부에서 `Sendable` 값 타입만 추출한 뒤 `MainActor.assumeIsolated { ... }` 블록으로 `@MainActor` 메서드를 호출합니다.
     - 호출 큐가 임의/백그라운드일 수 있는 콜백(`NSKeyValueObservation` 핸들러, `NWPathMonitor.pathUpdateHandler`, `MPRemoteCommandCenter` 핸들러): 절대 `MainActor.assumeIsolated`를 호출하지 않고, 필요한 값 타입만 캡처하여 `Task { @MainActor [weak self] in ... }`로 디스패치합니다.
     - **`AVPlayer.seek` 취소 및 단일 Resume 보장**: `import os`의 `OSAllocatedUnfairLock(initialState: false)`로 `CheckedContinuation<Bool, Never>`가 정확히 1회만 `resume`되도록 보호하고, `withTaskCancellationHandler`의 `onCancel:`(`@Sendable` 컨텍스트)에서는 `Task { @MainActor [weak self] in self?.player.currentItem?.cancelPendingSeeks() }`로 메인 액터에 위임합니다.
   - **`WKWebViewEngine` 필수 설정**:
     - `WKWebViewConfiguration.allowsInlineMediaPlayback = true`, `mediaTypesRequiringUserActionForPlayback = []`, `allowsPictureInPictureMediaPlayback = true`.
     - `loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com")!)` + IFrame `playsinline=1&enablejsapi=1&origin=https://www.youtube-nocookie.com` + `referrerpolicy="strict-origin-when-cross-origin"` (Error 152/153 방지).
     - `WKUserContentController.add(_:name:)`에는 `final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler` 프록시를 사용하여 `WKUserContentController -> Coordinator -> WKWebView` 순환 참조를 차단합니다.

4. **`StreamRecoveryController`, `AudioSessionManager`, `NowPlayingManager`**
   - **`StreamRecoveryController` (`MediaEngine/StreamRecoveryController.swift`)**:
     - 테스트 가능성을 위해 슬리퍼 클로저(`sleeper: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }`)를 주입받습니다.
     - `AVPlayerItemNewErrorLogEntry` / `AVPlayerItemFailedToPlayToEndTime` / HTTP `403`·`410`·`416` 감지 시 현재 재생 시각(`lastKnownTime`)을 스냅샷하고, `resolver.resolve(video: video, bypassCache: true)`로 최대 2회(지연 `0.5s`, `1.5s`) 재시도합니다.
     - 2회 모두 실패하면 `PlaybackCoordinator`에 폴백 신호를 보내 `AVPlayerEngine.teardown()` 완료 후 `WKWebViewEngine`(`.webEmbed`)으로 전환하고 `lastKnownTime`부터 재생을 이어갑니다.
   - **`AudioSessionManager` (`MediaEngine/AudioSessionManager.swift`)**:
     - `@MainActor protocol AudioSessionManagerProtocol: AnyObject`로 추상화.
     - 인터럽션(`.ended` + `.shouldResume`) 시 `try AVAudioSession.sharedInstance().setActive(true)` 선행 후 재생 재개.
     - `routeChangeNotification` `.oldDeviceUnavailable`(이어폰/AirPods 분리) 시 즉시 `pause(reason: .audioRouteDisconnected)`.
     - `mediaServicesWereResetNotification` 수신 시: 오디오 세션 재구성 → 활성 엔진 `teardown()` 및 재생성 → `PlayerRenderSurfaceProtocol` 재연결 → `PlaybackRuleArbitrator` 경계 옵저버 재등록 → 마지막 재생 위치/배속 복원.
   - **`NowPlayingManager` (`MediaEngine/NowPlayingManager.swift`)**:
     - `@MainActor protocol NowPlayingManagerProtocol: AnyObject` (`acquireOwnership(for:video:)`, `updatePlaybackStatus(state:currentTime:duration:rate:)`, `relinquishOwnership()`).

---

#### D. Data & Storage Layer (`Core/Networking/`, `Core/Persistence/`)

1. **`HTTPResilienceClient` & `HTTPTransportProtocol` (`Core/Networking/HTTPResilienceClient.swift`)**
   - 단위 테스트에서 실제 네트워크 없이 응답/지연/오류를 주입할 수 있도록 전송 계층과 시계를 추상화합니다:
     ```swift
     protocol HTTPTransportProtocol: Sendable {
         func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
     }

     extension URLSession: HTTPTransportProtocol {
         func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
             let (data, response) = try await self.data(for: request, delegate: nil)
             guard let http = response as? HTTPURLResponse else {
                 throw URLError(.badServerResponse)
             }
             return (data, http)
         }
     }
     ```
   - `actor HTTPResilienceClient`:
     - `init(transport: any HTTPTransportProtocol = URLSession.shared, now: @escaping @Sendable () -> Date = { Date() })`
     - **취소 안전 In-Flight Request Coalescing**: 동일 `GET` 키에 대해 비구조적 공유 `Task<(Data, HTTPURLResponse), Error>`와 `subscriberCount: Int`를 유지합니다. 개별 호출자가 취소(`onCancel`)되어도 다른 대기 중인 구독자가 남아 있으면 공유 네트워크 `Task`를 취소하지 않고, `subscriberCount == 0`이 될 때만 공유 `Task`를 취소합니다.
     - **호스트별 Circuit Breaker**: 연속 3회 `5xx` 또는 타임아웃(`URLError.timedOut`) 발생 시 해당 호스트를 `5분(300초)`간 `open` 상태로 전환하여 즉시 차단 오류를 반환하고, `now()` 기준 5분 경과 후 `halfOpen` 상태에서 1회 프로브 요청이 성공하면 `closed`로 복귀합니다.

2. **`VideoDataProvider` & `YouTubeDataAPIv3Provider` & `RSSFeedProvider` (`Core/Networking/`)**
   ```swift
   enum VideoDataError: Error, Sendable, Equatable {
       case quotaExceeded(resetAt: Date)
       case invalidAPIKey
       case channelNotFound(String)
       case httpError(statusCode: Int, message: String)
       case networkUnavailable
       case parsingFailed(String)
   }

   protocol VideoDataProvider: Sendable {
       func fetchChannelFeed(channelId: String, forceRefresh: Bool) async throws -> [VideoItem]
       func fetchVideoDetails(videoIds: [String]) async throws -> [VideoItem]
       func searchVideos(query: String, pageToken: String?) async throws -> VideoPage
       func resolveChannelId(fromInput input: String) async throws -> String
   }
   ```
   - **`RSSFeedProvider` (`Core/Networking/RSSFeedProvider.swift`)**:
     - `https://www.youtube.com/feeds/videos.xml?channel_id={channelId}` 호출 (`0 unit`).
     - 다중 채널 새로고침 시 `withThrowingTaskGroup` 슬라이딩 윈도우 패턴으로 **최대 동시 요청 수 4개** 제한.
     - `FileManager.cachesDirectory/RSSCache/{channelId}.json`에 파싱된 `[VideoItem]`, `etag: String?`, `lastModified: String?`, `cachedAt: Date`를 디스크 캐싱(Soft TTL `15분`, Stale-While-Revalidate `24시간`, 조건부 `If-None-Match` → `304 Not Modified` 시 디스크 캐시 반환 및 `cachedAt` 갱신).
     - `XMLParserDelegate`는 `nonisolated final class RSSAtomParserHelper: NSObject, XMLParserDelegate`로 격리하여 호출마다 로컬 인스턴스로 파싱(`actor`가 `NSObject`를 상속하지 않도록 분리).
   - **`YouTubeDataAPIv3Provider` (`Core/Networking/YouTubeDataAPIv3Provider.swift`)**:
     - **배치 상세 조회**: `videos.list(part=snippet,contentDetails,status,liveStreamingDetails&id={commaSeparated50Ids})`로 최대 50개 영상을 `1 unit`에 조회.
     - **ISO-8601 Duration 파서 (`ISO8601DurationParser`)**:
       - YouTube API의 `contentDetails.duration` (`PT1H2M30S`, `PT45S`, `P1DT2H`, 라이브/예정 영상의 `P0D` 등)을 정규식 `^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$`로 파싱하여 초 단위 `TimeInterval`(`days*86400 + hours*3600 + minutes*60 + seconds`)로 변환합니다(`P0D` 또는 `0초`이고 `liveBroadcastContent != "none"`이면 `nil` 반환).
     - **재생 가능 상태(`VideoPlayability`) 매핑**:
       - `status.privacyStatus == "private"` → `.restricted(.privateOrDeleted)`
       - `status.embeddable == false` → `.restricted(.embedDisabled)` (단, `.direct` 스트림 사용 시에는 재생 시도 가능)
       - `contentDetails.contentRating.ytRating == "ytAgeRestricted"` → `.restricted(.ageRestricted)`
       - `snippet.liveBroadcastContent == "live"` → `.live(concurrentViewers: Int(liveStreamingDetails.concurrentViewers ?? ""))`
       - `snippet.liveBroadcastContent == "upcoming"` → `.upcoming(scheduledStart: ISO8601DateFormatter().date(from: liveStreamingDetails.scheduledStartTime))`
       - 그 외 → `.playable`
     - **할당량 차단 및 태평양 표준시 자정 리셋**:
       - HTTP `403` 응답 JSON의 `error.errors[].reason`이 `"quotaExceeded"` 또는 `"dailyLimitExceeded"`이면 `TimeZone(identifier: "America/Los_Angeles")!` 캘린더 기준 **다음 날 00:00:00 PT**를 `quotaResetAt`으로 계산해 저장하고, 그 전까지 API 호출을 차단하며 RSS 폴백으로 동작합니다.
       - 사용자가 `KeychainStore`의 API 키를 변경하거나 삭제하면 즉시 `quotaResetAt = nil`로 리셋합니다.
     - **사이드로딩 리사이닝 호환 헤더**: 모든 요청에 `X-Ios-Bundle-Identifier: Bundle.main.bundleIdentifier ?? ""` 헤더를 자동 첨부합니다.

3. **`SponsorBlockClient` & `ReturnDislikeClient` (`Core/Networking/SponsorBlockClient.swift`, `Core/Networking/ReturnDislikeClient.swift`)**
   ```swift
   protocol SponsorBlockClientProtocol: Sendable {
       func fetchSegments(for videoID: String, categories: [SponsorCategory]) async -> [SponsorSegment]
   }

   protocol ReturnDislikeClientProtocol: Sendable {
       func fetchMetrics(for videoID: String) async -> DislikeState
   }
   ```
   - 두 클라이언트 모두 타임아웃 `3.5s` 및 `HTTPResilienceClient`의 5분 Circuit Breaker를 적용하며, 실패 시 메인 영상 재생을 절대 블로킹하지 않고 각각 빈 배열 `[]` 및 `.unavailable`을 반환합니다.

4. **SwiftData 영속화 (`Core/Persistence/AppSchemaV1.swift`, `Core/Persistence/PersistenceWorker.swift`)**
   - **iOS 17 단일 스키마 초기화 & 3단계 손상 복구 (`AppContainerFactory`)**:
     - V1 단일 버전 단계에서는 빈 `SchemaMigrationPlan`을 전달하지 않고 `Schema(versionedSchema: AppSchemaV1.self)`로만 초기화합니다.
     - **3단계 복구 정책**:
       1. 테스트 호스트 실행 감지 시(`ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`) 또는 단위 테스트에서는 즉시 `ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)`로 인메모리 컨테이너를 생성합니다.
       2. 일반 실행 시 `ModelConfiguration("YouTubeAdvancedStore", schema: schema, isStoredInMemoryOnly: false, allowsSave: true, groupContainer: .none, cloudKitDatabase: .none)`으로 디스크 컨테이너 생성을 시도합니다.
       3. 디스크 컨테이너 초기화가 throw하면(사이드로딩 재설치 후 스토어 파일 손상 등), 해당 SQLite 파일(`.store`, `.store-shm`, `.store-wal`)을 삭제한 뒤 디스크 컨테이너 생성을 1회 재시도하고(`didRecoverFromCorruptedStore = true`), 이마저 실패하면 `isStoredInMemoryOnly: true` 폴백 컨테이너로 부팅 후 `AppRootView` 상단에 비차단 경고 배너를 표시합니다(런타임 `try!` 크래시 절대 금지).
   - **엔티티 스키마 (`AppSchemaV1`, 6종)**:
     1. `WatchHistoryEntity`: `@Attribute(.unique) var videoId: String`, `var title: String`, `var channelId: String`, `var channelName: String`, `var lastPosition: TimeInterval`, `var duration: TimeInterval`, `var watchedAt: Date`
     2. `SubscribedChannelEntity`: `@Attribute(.unique) var channelId: String`, `var name: String`, `var avatarURLString: String?`, `var addedAt: Date`, `var lastSyncedAt: Date?`, `var etag: String?`
     3. `BookmarkEntity`: `@Attribute(.unique) var id: UUID`, `var videoId: String`, `var timestamp: TimeInterval`, `var note: String`, `var createdAt: Date`
     4. `FilterRuleEntity`: `@Attribute(.unique) var id: UUID`, `var keyword: String`, `var isRegex: Bool`, `var targetScopeRaw: String`, `var isEnabled: Bool`
     5. `LocalPlaylistEntity`: `@Attribute(.unique) var id: UUID`, `var name: String`, `var createdAt: Date`, `@Relationship(deleteRule: .cascade, inverse: \PlaylistItemEntity.playlist) var items: [PlaylistItemEntity]`
     6. `PlaylistItemEntity`: `var videoId: String`, `var title: String`, `var sortOrder: Int`, `var addedAt: Date`, `var playlist: LocalPlaylistEntity?`
   - **수동 `ModelActor` 구현 (`PersistenceWorker`) — Strict Concurrency 필수 보일러플레이트**:
     - `@ModelActor` 매크로 없이 `ModelActor` 프로토콜을 직접 채택할 때는 반드시 `unownedExecutor`를 `modelExecutor.asUnownedSerialExecutor()`로 바인딩해야 `ModelContext` 스레드 친화성 크래시가 발생하지 않습니다:
     ```swift
     protocol PersistenceWorkerProtocol: Sendable {
         func changeStream() -> AsyncStream<PersistenceChangeDomain>
         func upsertWatchHistory(_ dto: WatchHistoryDTO) async throws
         func fetchWatchPosition(videoId: String) async throws -> TimeInterval?
         func fetchRecentWatchHistory(limit: Int) async throws -> [WatchHistoryDTO]
         func upsertSubscriptions(_ channels: [SubscribedChannelDTO]) async throws
         func fetchSubscriptions() async throws -> [SubscribedChannelDTO]
         func deleteSubscription(channelId: String) async throws
         func addBookmark(_ dto: BookmarkDTO) async throws
         func fetchBookmarks(videoId: String) async throws -> [BookmarkDTO]
         func deleteBookmark(id: UUID) async throws
         func upsertFilterRule(_ dto: FilterRuleDTO) async throws
         func fetchFilterRules() async throws -> [FilterRuleDTO]
         func deleteFilterRule(id: UUID) async throws
         func createPlaylist(name: String) async throws -> LocalPlaylistDTO
         func addVideoToPlaylist(playlistId: UUID, videoId: String, title: String) async throws
         func reorderPlaylistItems(playlistId: UUID, orderedVideoIds: [String]) async throws
         func fetchPlaylists() async throws -> [LocalPlaylistDTO]
         func deletePlaylist(id: UUID) async throws
     }

     actor PersistenceWorker: ModelActor, PersistenceWorkerProtocol {
         nonisolated let modelExecutor: any ModelExecutor
         nonisolated let modelContainer: ModelContainer
         nonisolated var unownedExecutor: UnownedSerialExecutor {
             modelExecutor.asUnownedSerialExecutor()
         }

         init(modelContainer: ModelContainer) {
             let context = ModelContext(modelContainer)
             context.autosaveEnabled = false
             self.modelContainer = modelContainer
             self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
         }
         // 모든 upsert는 FetchDescriptor(predicate: ..., fetchLimit: 1) 조회 후 수정 또는 insert -> try modelContext.save() -> changeStream 브로드캐스트
     }
     ```

5. **`SubscriptionImporter` (`Core/Persistence/SubscriptionImporter.swift`)**
   ```swift
   protocol SubscriptionImporterProtocol: Sendable {
       func importOPML(data: Data) async throws -> SubscriptionImportResult
       func importTakeoutCSV(data: Data) async throws -> SubscriptionImportResult
       func importFromFileURL(_ url: URL) async throws -> SubscriptionImportResult
   }
   ```
   - `importFromFileURL`은 `let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }`를 반드시 수행합니다.
   - CSV 파서는 UTF-8 BOM(`0xEF, 0xBB, 0xBF`)을 먼저 제거하고, RFC 4180 큰따옴표 이스케이프(`""`) 및 필드 내 쉼표를 처리하는 상태 머신으로 `Channel ID`(`UC`로 시작하는 24자 ID 검증), `Channel URL`, `Channel Title`(헤더 다국어/공백 변형 대응, 헤더가 없으면 1번째 컬럼에서 `UC[A-Za-z0-9_-]{22}` 정규식 매칭)을 추출합니다. 잘못된 행은 전체 임포트를 중단하지 않고 `SubscriptionImportRowError`에 기록합니다.

---

## 4. 프로젝트 디렉토리 트리 및 빌드/CI 설정

섹션 3의 모든 컴포넌트는 아래 파일 경로와 1:1로 매핑됩니다.

```text
YouTubeAdvanced/
├── .gitattributes                                   # *.swift, *.yml, *.plist, *.sh, *.json -> eol=lf
├── project.yml                                      # XcodeGen 프로젝트 명세 (App + Tests + Scheme)
├── .github/workflows/
│   └── ios-build.yml                                # macos-15: xcodegen + simulator test + unsigned .ipa
├── App/
│   ├── YouTubeAdvancedApp.swift                     # @main, XCTest 호스트 단락 가드, AppContainerFactory
│   ├── AppDelegate.swift                            # supportedInterfaceOrientationsFor 연동
│   ├── OrientationManager.swift                     # requestGeometryUpdate 직렬화 관리
│   ├── Info.plist                                   # 커스텀 키 전용 (GENERATE_INFOPLIST_FILE: YES 병합)
│   └── Assets.xcassets/
│       ├── Contents.json
│       ├── AccentColor.colorset/Contents.json
│       └── AppIcon.appiconset/Contents.json
├── Core/
│   ├── Models/
│   │   ├── VideoModels.swift                        # VideoItem, VideoPage, VideoPlayability, PlayableSource, PlayerDisplayMode
│   │   ├── StreamEndpointSettings.swift             # StreamEndpointKind, StreamEndpointSettings
│   │   ├── PlaybackModels.swift                     # DurationInfo, PauseReason, PlaybackState, PlaybackError, ABLoopRange
│   │   ├── CommunityModels.swift                    # SponsorCategory, SponsorActionType, SponsorSegment, MergedSkipInterval, DislikeState
│   │   └── PersistenceDTOs.swift                    # WatchHistoryDTO, SubscribedChannelDTO, BookmarkDTO, FilterRuleDTO, LocalPlaylistDTO, SubscriptionImportResult
│   ├── Domain/
│   │   ├── PlaybackCoordinator.swift                # 듀얼 엔진 라우팅, activeLoadID, 이어보기 및 스로틀링 저장 조율
│   │   ├── PlaybackRuleArbitrator.swift             # A-B Loop > SponsorBlock 중재, 구간 병합, .mute 재동기화
│   │   ├── QueueManager.swift                       # QueueManagerProtocol 구현 (셔플/반복/이전·다음)
│   │   ├── FeedFilterService.swift                  # Shorts 및 키워드/정규식 필터링
│   │   └── RegexCacheActor.swift                    # NSRegularExpression 검증 및 스레드 안전 캐시
│   ├── Networking/
│   │   ├── HTTPResilienceClient.swift               # HTTPTransportProtocol, 취소 안전 Coalescing, 5분 Circuit Breaker
│   │   ├── KeychainStore.swift                      # API 키 저장 (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
│   │   ├── VideoDataProvider.swift                  # VideoDataProvider 프로토콜, VideoDataError, ISO8601DurationParser
│   │   ├── RSSFeedProvider.swift                    # 동시성 4 제한, ETag/304 디스크 캐시, RSSAtomParserHelper
│   │   ├── YouTubeDataAPIv3Provider.swift           # 50개 배치 조회, LA 타임존 자정 쿼터 리셋, X-Ios-Bundle-Identifier
│   │   ├── CompositeVideoRepository.swift           # RSS + Data API v3 하이브리드 조합
│   │   ├── SponsorBlockClient.swift                 # SHA-256 4-hex prefix 조회, 404 빈 캐싱, videoID 필터링
│   │   └── ReturnDislikeClient.swift                # RYD 3상태(.loading/.available/.unavailable) 조회
│   └── Persistence/
│       ├── AppSchemaV1.swift                        # VersionedSchema (6개 @Model 엔티티) + AppContainerFactory (3단계 복구)
│       ├── PersistenceWorker.swift                  # 수동 ModelActor (unownedExecutor, autosaveEnabled = false)
│       └── SubscriptionImporter.swift               # OPML & Takeout CSV 파서 (UTF-8 BOM, RFC 4180, 부분 실패 리포트)
├── MediaEngine/
│   ├── PlayerEngineProtocol.swift                   # PlayerEngineProtocol, PlayerRenderSurfaceProtocol, EngineCapabilities
│   ├── PlayableSourceResolver.swift                 # StreamResolverProtocol, StreamEndpointValidator (Piped/Invidious/Custom/Embed)
│   ├── EngineEventBroadcaster.swift                 # 다중 소비자 AsyncStream 멀티캐스터
│   ├── AVPlayerEngine.swift                         # 네이티브 HLS/MP4 재생, KVO/TimeObserver/Seek lock/PiP
│   ├── WKWebViewEngine.swift                        # youtube-nocookie IFrame 브리지, WeakScriptMessageHandler
│   ├── StreamRecoveryController.swift               # 스트림 만료 감지, 2회 백오프 재발급 및 WKWebViewEngine 폴백
│   ├── AudioSessionManager.swift                    # .playback/.moviePlayback, 인터럽션, AirPods 분리, MediaServicesReset
│   └── NowPlayingManager.swift                      # acquireOwnership / relinquishOwnership, MPRemoteCommandCenter 토큰 관리
├── Features/
│   ├── Root/
│   │   ├── AppRootView.swift                        # 메인 TabView + 단일 영속 PlayerRenderHostView + 미니/인라인/풀스크린 전환
│   │   └── PlayerRenderHostView.swift               # UIViewRepresentable + PlayerRenderContainerUIView (PlayerRenderSurfaceProtocol)
│   ├── Home/
│   │   └── HomeFeedView.swift                       # 피드 목록 + Clean Feed 필터 적용
│   ├── Subscriptions/
│   │   └── SubscriptionsView.swift                  # 로컬 구독 피드 및 채널 관리
│   ├── Search/
│   │   └── SearchView.swift                         # 검색 및 페이지네이션(nextPageToken)
│   ├── Player/
│   │   ├── PlayerDetailOverlayView.swift            # 인라인 16:9 플레이스홀더 + 메타데이터/RYD/북마크/큐 + 컨트롤 HUD
│   │   ├── PlayerGestureOverlay.swift               # UIKit 제스처 중재기 (안전 영역 제외, 700ms 누적 시크, 롱프레스 2x)
│   │   └── BrightnessVolumeControllers.swift        # BrightnessController (windowScene.screen) + VolumeBridgeView (MPVolumeView)
│   ├── Library/
│   │   └── LibraryView.swift                        # 시청 기록, 로컬 재생목록, 북마크 관리
│   └── Settings/
│       └── SettingsView.swift                       # API 키(번들 ID 복사), 스트림 엔드포인트, SponsorBlock/필터, OPML/CSV 가져오기
└── Tests/
    ├── PlaybackRuleArbitratorTests.swift            # 구간 병합, A-B Loop > SponsorBlock 우선순위, .mute 재동기화 검증
    ├── SponsorBlockClientTests.swift                # SHA-256 4-hex prefix, 404 캐싱, videoID 필터링, 5분 Circuit Breaker 검증
    ├── SubscriptionImporterTests.swift              # OPML, UTF-8 BOM/따옴표 CSV, 잘못된 행 부분 복구 리포트 검증
    └── PlaybackCoordinatorConcurrencyTests.swift    # 연타 취소(activeLoadID), 듀얼 엔진 전환, StreamRecovery 2회 재시도 후 폴백 검증
```

### 4.1 XcodeGen `project.yml` 및 `App/Info.plist` 충돌 방지 표준 명세

Xcode 16 (`macos-15`)에서 `GENERATE_INFOPLIST_FILE: YES`와 `INFOPLIST_FILE: App/Info.plist`를 병합할 때의 빌드 충돌 및 `xcodebuild test` 스킴 누락을 방지하기 위해 다음 규칙을 **단일 표준**으로 고정합니다:

1. **`project.yml`에서의 `Info.plist` 처리 규칙**:
   - 타겟 정의에 XcodeGen의 `info:` 블록을 사용하지 않습니다(`info:` 블록을 쓰면 `xcodegen generate` 실행 시 XcodeGen이 `App/Info.plist` 파일을 덮어씁니다).
   - 대신 `settings.base`에 `GENERATE_INFOPLIST_FILE: YES`, `INFOPLIST_FILE: App/Info.plist`, `MARKETING_VERSION: "1.0.0"`, `CURRENT_PROJECT_VERSION: "1"`을 선언합니다.
   - **`App/Info.plist`에는 `CFBundle*` 키(`CFBundleIdentifier`, `CFBundleExecutable`, `CFBundleName`, `CFBundlePackageType`, `CFBundleShortVersionString`, `CFBundleVersion`)를 절대 작성하지 않습니다.** (해당 키들은 `GENERATE_INFOPLIST_FILE: YES`가 자동 생성하며, `App/Info.plist`에 중복 기재하면 Xcode 빌드 시 `Multiple commands produce Info.plist` / 키 충돌 오류가 발생합니다.)

2. **표준 `project.yml` 구성**:
   ```yaml
   name: YouTubeAdvanced
   options:
     bundleIdPrefix: com.personal.ytadvanced
     deploymentTarget:
       iOS: "17.0"
     xcodeVersion: "16.0"
     createIntermediateGroups: true
   settings:
     base:
       SWIFT_VERSION: "5.0"
       SWIFT_STRICT_CONCURRENCY: complete
       IPHONEOS_DEPLOYMENT_TARGET: "17.0"
       CODE_SIGN_IDENTITY: ""
       CODE_SIGNING_REQUIRED: NO
   targets:
     YouTubeAdvanced:
       type: application
       platform: iOS
       sources:
         - path: App
         - path: Core
         - path: MediaEngine
         - path: Features
       settings:
         base:
           PRODUCT_BUNDLE_IDENTIFIER: com.personal.ytadvanced.app
           MARKETING_VERSION: "1.0.0"
           CURRENT_PROJECT_VERSION: "1"
           GENERATE_INFOPLIST_FILE: YES
           INFOPLIST_FILE: App/Info.plist
           ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
           ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
           TARGETED_DEVICE_FAMILY: "1"
         configs:
           Debug:
             ENABLE_TESTABILITY: YES
     YouTubeAdvancedTests:
       type: bundle.unit-test
       platform: iOS
       sources:
         - path: Tests
       dependencies:
         - target: YouTubeAdvanced
       settings:
         base:
           PRODUCT_BUNDLE_IDENTIFIER: com.personal.ytadvanced.tests
           GENERATE_INFOPLIST_FILE: YES
           TEST_HOST: "$(BUILT_PRODUCTS_DIR)/YouTubeAdvanced.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/YouTubeAdvanced"
           BUNDLE_LOADER: "$(TEST_HOST)"
   schemes:
     YouTubeAdvanced:
       build:
         targets:
           YouTubeAdvanced: all
           YouTubeAdvancedTests: [test]
       test:
         targets:
           - YouTubeAdvancedTests
   ```

3. **`App/Info.plist` 필수 커스텀 키 (최상위 레벨, `CFBundle*` 제외)**:
   - `UILaunchScreen`: `{}` (빈 딕셔너리 — iPhone 풀 해상도 렌더링 활성화)
   - `UISupportedInterfaceOrientations`: `["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]`
   - `UIBackgroundModes`: `["audio"]`
   - `UIViewControllerBasedStatusBarAppearance`: `true`
   - `NSAppTransportSecurity`: `{ "NSAllowsLocalNetworking": true }`
   - `NSLocalNetworkUsageDescription`: `"로컬 네트워크의 스트림 서버에 연결하기 위해 권한이 필요합니다."` (반드시 최상위 키로 선언, ATS 내부에 중첩 금지)

4. **`YouTubeAdvancedApp.swift` 테스트 호스트 단락(Short-Circuit) 가드**:
   - `YouTubeAdvancedTests`는 `TEST_HOST`로 앱 바이너리를 로드하므로, 시뮬레이터에서 테스트 시작 시 `YouTubeAdvancedApp`이 먼저 실행됩니다.
   - 프로덕션 SQLite 파일 잠금, 오디오 세션 활성화, 백그라운드 네트워크 요청이 단위 테스트를 오염시키지 않도록 `YouTubeAdvancedApp`에서 테스트 호스트 여부를 판별해 단락합니다:
     ```swift
     private var isRunningUnitTests: Bool {
         ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
     }
     ```
     `isRunningUnitTests == true`일 때는 `WindowGroup { EmptyView() }`만 렌더링하고 프로덕션 `PlaybackCoordinator`/`AudioSessionManager` 부트스트랩을 건너뜁니다.

5. **CI 워크플로우 (`.github/workflows/ios-build.yml`)**:
   - 러너: **`macos-15`** + `brew install xcodegen` + `xcodegen generate`
   - **Unit Test 단계 (시뮬레이터 동적 UDID 탐색)**:
     - `CODE_SIGNING_ALLOWED=NO`는 arm64 시뮬레이터에서 `xctest` 번들 로더 코드 서명 검증 오류를 유발할 수 있으므로 **`xcodebuild test`에는 전달하지 않고 `xcodebuild archive`에만 전달**합니다.
     - `xcrun simctl list devices available -j`에서 사용 가능한 첫 번째 iPhone 시뮬레이터의 `udid`를 추출해 `-destination "platform=iOS Simulator,id=$SIM_UDID"`로 `xcodebuild test -project YouTubeAdvanced.xcodeproj -scheme YouTubeAdvanced`를 실행합니다.
   - **Unsigned IPA Archive 단계**:
     - `xcodebuild archive -project YouTubeAdvanced.xcodeproj -scheme YouTubeAdvanced -configuration Release -destination "generic/platform=iOS" -archivePath "$RUNNER_TEMP/YouTubeAdvanced.xcarchive" CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO AD_HOC_CODE_SIGNING_ALLOWED=NO`
     - `$RUNNER_TEMP/YouTubeAdvanced.xcarchive/Products/Applications/YouTubeAdvanced.app`을 `Payload/YouTubeAdvanced.app`으로 복사하고 `_CodeSignature` 및 `embedded.mobileprovision` 제거 후 `zip -r -y YouTubeAdvanced-unsigned.ipa Payload`로 패키징합니다.

---

## 5. 예외 시나리오 및 방어 설계 매트릭스 (Audit Summary)

| 영역 | 식별된 예외 / 결함 시나리오 | 보완된 설계 대책 |
| :--- | :--- | :--- |
| **Build / CI** | `macos-14` 은퇴, `SWIFT_VERSION: "5.10"` 오류, `Info.plist` `CFBundle*` 중복 충돌, `schemes.test` 누락, 시뮬레이터 `CODE_SIGNING_ALLOWED=NO` 로더 실패 | `macos-15` + `SWIFT_VERSION: "5.0"` + `GENERATE_INFOPLIST_FILE: YES`(커스텀 키만 `App/Info.plist`에 유지) + `project.yml` 명시적 `schemes.YouTubeAdvanced.test` + `archive`에만 `CODE_SIGNING_ALLOWED=NO` 적용 |
| **Source / Engine** | `PlayableSource` 해석 계약 부재, `AVPlayer` DASH 한계, `WKWebView` 리로드/Error 152, 엔진 전환 시 리모트 커맨드 잔류 | `StreamResolverProtocol` & `StreamEndpointSettings`(Piped/Invidious/Custom/Embed) 명세, 단일 `PlayerRenderHostView`(`PlayerRenderSurfaceProtocol`), 엔진 전환 시 `stopAndClear` → `relinquishOwnership` → `setActiveSurface` → `acquireOwnership` 순서 강제 |
| **Media Engine** | `addBoundaryTimeObserver` 클로저 시그니처 오해/빈 배열 크래시, `AsyncStream` 단일 소비자 | `() -> Void` 콜백 내 `currentTime()` 허용 오차 매칭 + `!times.isEmpty` 가드 + `EngineEventBroadcaster` 멀티캐스트 |
| **Audio / PiP** | Auto-PiP 중 `player = nil` 충돌, AirPods 분리 미정지, `WKWebView` NowPlaying 경합 | `autoPiPEnabled` 분기 가드, `.oldDeviceUnavailable` 일시정지, `managesNowPlaying` capability 분리, PiP 복원 `0.5s` 타임아웃 |
| **Sponsor / Loop** | SHA-256 4바이트(8-hex) 오계산, `.poi` 필터 누락, `.mute` 구간 시크 이탈 시 음소거 고착, 3x 배속 끝지점 루프 누락 | hex 문자열 `.prefix(4)` 명시, `.poi` 분리, 시크·규칙 변경 시 `evaluateMuteState(at:)` 즉시 재계산, `DidPlayToEnd` 시 A-B Loop 우선 처리 |
| **External API** | ISO-8601 `PT#H#M#S` 파싱 누락, `America/Los_Angeles` 자정 리셋 오류, `RSS` `304` 메모리 소멸, Coalescing 연쇄 취소 | `ISO8601DurationParser` 정규식 명세, LA 타임존 자정 리셋 + 키 변경 시 즉시 해제, RSS 디스크 캐시, 비구조적 공유 `Task` + 구독자 카운트, `RSSAtomParserHelper` 분리 |
| **SwiftData** | V1 단일 `SchemaMigrationPlan` 크래시, 수동 `ModelActor` `unownedExecutor` 누락 크래시, 스토어 손상 시 앱 영구 크래시 | V1 `migrationPlan` 생략, 수동 `ModelActor`에 `unownedExecutor` + `autosaveEnabled = false` 명시, `AppContainerFactory` 3단계 복구(디스크 → 손상 파일 삭제 후 재시도 → 인메모리 폴백) |
| **Concurrency / Tests** | Swift 5 Strict Concurrency 콜백 격리 위반, `seek` continuation 이중 resume, `TEST_HOST` 앱 부트스트랩 간섭 | 큐별 `assumeIsolated` vs `Task { @MainActor }`, `OSAllocatedUnfairLock` + `cancelPendingSeeks()` 위임, `HTTPTransportProtocol`/슬리퍼 주입, `XCTestConfigurationFilePath` 단락 가드 |
| **UI / Sideload** | `.opml` `UTType` 누락, 리사이닝 번들 ID 변조, 밝기 제어센터 덮어쓰기 | `UTType(filenameExtension: "opml") ?? .xml`, Keychain Group 미사용, `brightnessDidChangeNotification` 감시, `.defersSystemGestures` |

---

## 6. 단계별 구현 로드맵 (Roadmap)

- **Phase 1: 프로젝트 뼈대 & CI 파이프라인 구축**
  - `.gitattributes`, `project.yml`(App + Hosted Unit Test + Scheme), `App/Info.plist`(커스텀 키 전용), `App/Assets.xcassets`, `.github/workflows/ios-build.yml`(동적 시뮬레이터 테스트 + Unsigned IPA 아카이브), `YouTubeAdvancedApp`(테스트 호스트 단락 가드 포함), `AppDelegate`/`OrientationManager` 스캐폴딩
- **Phase 2: 도메인 모델, 데이터 계층 & SwiftData 영속화**
  - `Core/Models/` 전체 모델 및 DTO, `AppSchemaV1` + `AppContainerFactory`(3단계 복구) + `PersistenceWorker`(수동 `ModelActor`), `KeychainStore`, `HTTPResilienceClient`(`HTTPTransportProtocol`), `RSSFeedProvider`(디스크 캐시), `YouTubeDataAPIv3Provider`(`ISO8601DurationParser`, LA 자정 쿼터 리셋), `CompositeVideoRepository`, `SubscriptionImporter`(OPML/CSV) & `SubscriptionImporterTests`
- **Phase 3: 듀얼 미디어 엔진, 커스텀 플레이어 UX & 백그라운드/PiP**
  - `PlayerEngineProtocol`/`PlayerRenderSurfaceProtocol`, `PlayableSourceResolver`(`StreamEndpointValidator`), `EngineEventBroadcaster`, `AVPlayerEngine`, `WKWebViewEngine`(`WeakScriptMessageHandler`), `StreamRecoveryController`, `AudioSessionManager`, `NowPlayingManager`, `PlayerRenderHostView`, `PlayerGestureOverlay`, `BrightnessVolumeControllers`, `PlaybackCoordinator` & `PlaybackCoordinatorConcurrencyTests`
- **Phase 4: 커뮤니티 확장, 규칙 중재기, 큐/필터 & 전체 통합**
  - `SponsorBlockClient` & `SponsorBlockClientTests`, `ReturnDislikeClient`, `PlaybackRuleArbitrator` & `PlaybackRuleArbitratorTests`, `QueueManager`, `RegexCacheActor`/`FeedFilterService`, 피드/검색/구독/보관함/설정/플레이어 상세 SwiftUI 화면 연결 및 전체 단위 테스트 검증
