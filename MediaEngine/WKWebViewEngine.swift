import Foundation
import WebKit

/// Weak proxy breaking the `WKUserContentController -> Handler -> WKWebView` retain cycle.
@MainActor
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: (any WKScriptMessageHandler)?

    init(delegate: any WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

/// Compatibility playback engine wrapping YouTube IFrame API inside `WKWebView`.
@MainActor
final class WKWebViewEngine: NSObject, PlayerEngineProtocol, WKScriptMessageHandler, WKNavigationDelegate {
    let capabilities: EngineCapabilities = []

    private(set) var state: PlaybackState = .idle {
        didSet {
            guard oldValue != state else { return }
            broadcaster.send(.stateChanged(state))
        }
    }
    private(set) var currentTime: TimeInterval = 0
    private(set) var bufferedTime: TimeInterval = 0
    private(set) var durationInfo: DurationInfo = .unknown {
        didSet {
            guard oldValue != durationInfo else { return }
            broadcaster.send(.durationChanged(durationInfo))
        }
    }
    private(set) var rate: Float = 1.0
    let availableQualities: [QualityOption] = []
    let selectedQuality: QualityOption? = nil
    let availableAudioTracks: [AudioTrackOption] = []
    let selectedAudioTrack: AudioTrackOption? = nil

    private static let supportedDiscreteRates: [Float] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private static let bridgeName = "ytBridge"

    private let broadcaster = EngineEventBroadcaster()
    private var webView: WKWebView?
    private weak var renderSurface: (any PlayerRenderSurfaceProtocol)?

    private var activeLoadID = UUID()
    private var pendingStartAt: TimeInterval?
    private var registeredBoundaries: [TimeInterval] = []
    private var boundaryCallback: (@MainActor (TimeInterval) -> Void)?
    private var lastPolledTime: TimeInterval = 0

    override init() {
        super.init()
    }

    func eventStream() -> AsyncStream<PlaybackEngineEvent> {
        broadcaster.makeStream()
    }

    func attachRenderSurface(_ surface: (any PlayerRenderSurfaceProtocol)?) {
        renderSurface = surface
        if let surface, let webView {
            surface.attachWebView(webView)
        }
    }

    func load(source: PlayableSource, startAt: TimeInterval?) async throws {
        guard case .webEmbed(let videoID, let baseURL) = source else {
            throw PlaybackError.sourceResolutionFailed("WKWebViewEngine requires a .webEmbed PlayableSource")
        }

        let loadID = UUID()
        activeLoadID = loadID
        state = .loading(loadID: loadID)
        currentTime = 0
        bufferedTime = 0
        lastPolledTime = 0
        durationInfo = .unknown
        pendingStartAt = startAt

        let wv = ensureWebView()
        renderSurface?.attachWebView(wv)

        let origin = baseURL.absoluteString
        let html = Self.buildEmbedHTML(videoID: videoID, origin: origin, startSeconds: Int(startAt ?? 0))
        wv.loadHTMLString(html, baseURL: baseURL)
    }

    func stopAndClear() {
        activeLoadID = UUID()
        registeredBoundaries.removeAll()
        boundaryCallback = nil
        pendingStartAt = nil
        lastPolledTime = 0
        currentTime = 0
        bufferedTime = 0
        durationInfo = .unknown
        webView?.evaluateJavaScript("if (window.ytPlayer && window.ytPlayer.stopVideo) { window.ytPlayer.stopVideo(); }", completionHandler: nil)
        webView?.loadHTMLString("", baseURL: nil)
        state = .idle
    }

    func play() {
        webView?.evaluateJavaScript("window.ytPlayer && window.ytPlayer.playVideo();", completionHandler: nil)
    }

    func pause(reason: PauseReason) {
        webView?.evaluateJavaScript("window.ytPlayer && window.ytPlayer.pauseVideo();", completionHandler: nil)
        state = .paused(reason: reason)
    }

    @discardableResult
    func seek(to time: TimeInterval, precision: SeekPrecision) async -> Bool {
        let clamped = max(0, time.isFinite ? time : 0)
        lastPolledTime = clamped
        currentTime = clamped
        webView?.evaluateJavaScript("window.ytPlayer && window.ytPlayer.seekTo(\(clamped), true);", completionHandler: nil)
        return true
    }

    func setRate(_ newRate: Float) {
        let clamped = Self.nearestSupportedRate(for: newRate)
        rate = clamped
        webView?.evaluateJavaScript("window.ytPlayer && window.ytPlayer.setPlaybackRate(\(clamped));", completionHandler: nil)
    }

    func setMuted(_ muted: Bool) {
        let js = muted
            ? "window.ytPlayer && window.ytPlayer.mute();"
            : "window.ytPlayer && window.ytPlayer.unMute();"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func selectQuality(_ quality: QualityOption) async throws {}
    func selectAudioTrack(_ track: AudioTrackOption) async throws {}

    func updateBoundaryObservers(
        times: [TimeInterval],
        onCrossed: @escaping @MainActor (TimeInterval) -> Void
    ) {
        registeredBoundaries = times.filter { $0.isFinite && $0 >= 0 }.sorted()
        boundaryCallback = registeredBoundaries.isEmpty ? nil : onCrossed
    }

    func startPiP() {}
    func stopPiP() {}
    func handleBackgroundTransition(backgroundAudioEnabled: Bool, autoPiPEnabled: Bool) {}
    func handleForegroundTransition() {}

    func teardown() async {
        stopAndClear()
        if let webView {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
        }
        webView = nil
        broadcaster.finishAll()
    }

    // MARK: - Software Boundary Emulation & Rate Clamping

    static func nearestSupportedRate(for requested: Float) -> Float {
        supportedDiscreteRates.min(by: { abs($0 - requested) < abs($1 - requested) }) ?? 1.0
    }

    /// Evaluates software boundary crossing between `prevTime` and `currTime` during ~250ms polling.
    func evaluatePolledBoundaries(prevTime: TimeInterval, currTime: TimeInterval) {
        guard !registeredBoundaries.isEmpty, let callback = boundaryCallback else { return }
        for boundary in registeredBoundaries {
            if prevTime < boundary && currTime >= boundary && (currTime - boundary) <= 0.6 {
                callback(boundary)
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.bridgeName,
              let dict = message.body as? [String: Any],
              let event = dict["event"] as? String else {
            return
        }

        switch event {
        case "onReady":
            if let duration = dict["duration"] as? Double, duration.isFinite, duration > 0 {
                durationInfo = .finite(duration)
            }
            if let startAt = pendingStartAt, startAt > 0 {
                pendingStartAt = nil
                Task { @MainActor [weak self] in
                    _ = await self?.seek(to: startAt, precision: .exact)
                }
            }
            play()

        case "onStateChange":
            guard let code = dict["state"] as? Int else { return }
            switch code {
            case 0: // ENDED
                state = .ended
                broadcaster.send(.didPlayToEnd)
            case 1: // PLAYING
                state = .playing
            case 2: // PAUSED
                state = .paused(reason: .user)
            case 3: // BUFFERING
                state = .buffering(wasPlaying: true)
            default:
                break
            }

        case "onTimeUpdate":
            if let time = dict["currentTime"] as? Double, time.isFinite {
                let prev = lastPolledTime
                lastPolledTime = time
                currentTime = max(0, time)
                if let duration = dict["duration"] as? Double, duration.isFinite, duration > 0 {
                    durationInfo = .finite(duration)
                    if let fraction = dict["loadedFraction"] as? Double, fraction.isFinite {
                        bufferedTime = max(0, min(duration, duration * fraction))
                    }
                }
                broadcaster.send(.timeUpdated(currentTime: currentTime, bufferedTime: bufferedTime))
                evaluatePolledBoundaries(prevTime: prev, currTime: currentTime)
            }

        case "onError":
            let code = dict["code"] as? Int ?? -1
            state = .failed(.webViewBridgeFailed("YouTube IFrame error \(code)"))

        default:
            break
        }
    }

    // MARK: - Private Setup

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.userContentController.add(WeakScriptMessageHandler(delegate: self), name: Self.bridgeName)

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.isScrollEnabled = false
        wv.navigationDelegate = self
        self.webView = wv
        return wv
    }

    private static func buildEmbedHTML(videoID: String, origin: String, startSeconds: Int) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <meta name="referrer" content="strict-origin-when-cross-origin">
          <style>
            html, body, #player { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
          </style>
        </head>
        <body>
          <div id="player"></div>
          <script src="https://www.youtube.com/iframe_api"></script>
          <script>
            var ytPlayer = null;
            var pollTimer = null;
            function postBridge(payload) {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ytBridge) {
                window.webkit.messageHandlers.ytBridge.postMessage(payload);
              }
            }
            function onYouTubeIframeAPIReady() {
              ytPlayer = new YT.Player('player', {
                videoId: '\(videoID)',
                host: 'https://www.youtube-nocookie.com',
                playerVars: {
                  playsinline: 1,
                  enablejsapi: 1,
                  rel: 0,
                  start: \(max(0, startSeconds)),
                  origin: '\(origin)'
                },
                events: {
                  onReady: function(e) {
                    postBridge({ event: 'onReady', duration: e.target.getDuration() || 0 });
                    if (pollTimer) clearInterval(pollTimer);
                    pollTimer = setInterval(function() {
                      if (!ytPlayer || !ytPlayer.getCurrentTime) return;
                      postBridge({
                        event: 'onTimeUpdate',
                        currentTime: ytPlayer.getCurrentTime() || 0,
                        duration: ytPlayer.getDuration() || 0,
                        loadedFraction: ytPlayer.getVideoLoadedFraction ? ytPlayer.getVideoLoadedFraction() : 0
                      });
                    }, 250);
                  },
                  onStateChange: function(e) {
                    postBridge({ event: 'onStateChange', state: e.data });
                  },
                  onError: function(e) {
                    postBridge({ event: 'onError', code: e.data });
                  }
                }
              });
            }
          </script>
        </body>
        </html>
        """
    }
}
