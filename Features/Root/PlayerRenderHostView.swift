import AVFoundation
import SwiftUI
import UIKit
import WebKit

/// Backing view layer subclass providing an `AVPlayerLayer` as its primary CALayer.
final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // Guaranteed by `layerClass` override above.
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Persistent UIKit host container holding both `AVPlayerLayer` and `WKWebView` without view recreation.
@MainActor
final class PlayerRenderContainerUIView: UIView, PlayerRenderSurfaceProtocol {
    private let playerLayerView = PlayerLayerUIView()
    private weak var hostedWebView: WKWebView?

    var playerLayer: AVPlayerLayer {
        playerLayerView.playerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        playerLayerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerLayerView)
        NSLayoutConstraint.activate([
            playerLayerView.topAnchor.constraint(equalTo: topAnchor),
            playerLayerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerLayerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerLayerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attachWebView(_ webView: WKWebView) {
        guard hostedWebView !== webView else { return }
        hostedWebView?.removeFromSuperview()
        hostedWebView = webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func setActiveSurface(_ surface: ActiveRenderSurface) {
        switch surface {
        case .none:
            playerLayerView.isHidden = true
            hostedWebView?.isHidden = true
        case .avPlayerLayer:
            playerLayerView.isHidden = false
            hostedWebView?.isHidden = true
        case .webView:
            playerLayerView.isHidden = true
            hostedWebView?.isHidden = false
        }
    }
}

/// Single persistent SwiftUI wrapper kept at `AppRootView` level across all `PlayerDisplayMode` transitions.
struct PlayerRenderHostView: UIViewRepresentable {
    let onSurfaceReady: @MainActor (any PlayerRenderSurfaceProtocol) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PlayerRenderContainerUIView {
        let view = PlayerRenderContainerUIView()
        context.coordinator.notifyOnceIfNeeded(surface: view, callback: onSurfaceReady)
        return view
    }

    func updateUIView(_ uiView: PlayerRenderContainerUIView, context: Context) {
        context.coordinator.notifyOnceIfNeeded(surface: uiView, callback: onSurfaceReady)
    }

    @MainActor
    final class Coordinator {
        private var hasNotified = false

        func notifyOnceIfNeeded(
            surface: any PlayerRenderSurfaceProtocol,
            callback: @MainActor (any PlayerRenderSurfaceProtocol) -> Void
        ) {
            guard !hasNotified else { return }
            hasNotified = true
            callback(surface)
        }
    }
}
