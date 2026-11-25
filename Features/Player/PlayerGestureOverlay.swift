import SwiftUI
import UIKit

enum PlayerGestureEvent {
    case toggleControls
    case seekStep(seconds: TimeInterval, isLeft: Bool)
    case speedBoostChanged(active: Bool)
    case brightnessDelta(CGFloat)
    case volumeDelta(Float)
    case verticalTransition(translationY: CGFloat, velocityY: CGFloat, ended: Bool)
}

enum FullscreenPanZone: Equatable {
    case brightness
    case centerVertical
    case volume
}

/// UIKit gesture arbitrator preventing vertical pan, system edge, and double-tap conflicts.
struct PlayerGestureOverlay: UIViewRepresentable {
    let isFullscreen: Bool
    let excludedBottomHeight: CGFloat
    let onWindowSceneAttached: @MainActor (UIWindowScene?) -> Void
    let onGestureEvent: @MainActor (PlayerGestureEvent) -> Void

    static func isExcludedTouchLocation(
        _ location: CGPoint,
        bounds: CGRect,
        safeAreaInsets: UIEdgeInsets,
        excludedBottomHeight: CGFloat
    ) -> Bool {
        if location.y < safeAreaInsets.top + 14 {
            return true
        }
        let bottomExclusion = max(safeAreaInsets.bottom + 14, excludedBottomHeight)
        if location.y > bounds.height - bottomExclusion {
            return true
        }
        return false
    }

    static func fullscreenPanZone(xRatio: CGFloat) -> FullscreenPanZone {
        if xRatio < 0.32 {
            return .brightness
        } else if xRatio > 0.68 {
            return .volume
        } else {
            return .centerVertical
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> GestureArbitratorUIView {
        let view = GestureArbitratorUIView()
        view.backgroundColor = .clear
        view.onWindowAttached = onWindowSceneAttached
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: GestureArbitratorUIView, context: Context) {
        context.coordinator.parent = self
        uiView.onWindowAttached = onWindowSceneAttached
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerGestureOverlay

        private var activeZone: ActivePanZone = .none
        private var lastTranslation: CGPoint = .zero
        private var isSeekAccumulating = false
        private var seekResetTask: Task<Void, Never>?

        private enum ActivePanZone {
            case none
            case brightness
            case volume
            case verticalTransition
        }

        init(parent: PlayerGestureOverlay) {
            self.parent = parent
        }

        func attach(to view: UIView) {
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            singleTap.numberOfTapsRequired = 1
            singleTap.delegate = self

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self

            singleTap.require(toFail: doubleTap)

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.35
            longPress.allowableMovement = 18
            longPress.delegate = self

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self

            view.addGestureRecognizer(singleTap)
            view.addGestureRecognizer(doubleTap)
            view.addGestureRecognizer(longPress)
            view.addGestureRecognizer(pan)
        }

        @objc private func handleSingleTap(_ gr: UITapGestureRecognizer) {
            guard let view = gr.view else { return }
            if isSeekAccumulating {
                triggerSeekStep(x: gr.location(in: view).x, width: view.bounds.width)
            } else {
                parent.onGestureEvent(.toggleControls)
            }
        }

        @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            guard let view = gr.view else { return }
            triggerSeekStep(x: gr.location(in: view).x, width: view.bounds.width)
        }

        private func triggerSeekStep(x: CGFloat, width: CGFloat) {
            let ratio = x / max(width, 1)
            let isLeft = ratio < 0.40
            let isRight = ratio > 0.60
            guard isLeft || isRight else {
                parent.onGestureEvent(.toggleControls)
                return
            }

            isSeekAccumulating = true
            seekResetTask?.cancel()
            seekResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                self?.isSeekAccumulating = false
            }

            parent.onGestureEvent(.seekStep(seconds: isLeft ? -10 : 10, isLeft: isLeft))
        }

        @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            switch gr.state {
            case .began:
                parent.onGestureEvent(.speedBoostChanged(active: true))
            case .ended, .cancelled, .failed:
                // Guarantee preferred playback speed restoration on any interruption.
                parent.onGestureEvent(.speedBoostChanged(active: false))
            default:
                break
            }
        }

        @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
            guard let view = gr.view else { return }
            let translation = gr.translation(in: view)
            let velocity = gr.velocity(in: view)

            switch gr.state {
            case .began:
                lastTranslation = .zero
                if !parent.isFullscreen {
                    activeZone = .verticalTransition
                } else {
                    let ratio = gr.location(in: view).x / max(view.bounds.width, 1)
                    switch PlayerGestureOverlay.fullscreenPanZone(xRatio: ratio) {
                    case .brightness:
                        activeZone = .brightness
                    case .volume:
                        activeZone = .volume
                    case .centerVertical:
                        activeZone = .verticalTransition
                    }
                }

            case .changed:
                let dy = translation.y - lastTranslation.y
                lastTranslation = translation
                let normalized = -dy / max(view.bounds.height * 0.6, 180)
                switch activeZone {
                case .brightness:
                    parent.onGestureEvent(.brightnessDelta(normalized))
                case .volume:
                    parent.onGestureEvent(.volumeDelta(Float(normalized)))
                case .verticalTransition:
                    parent.onGestureEvent(.verticalTransition(translationY: translation.y, velocityY: velocity.y, ended: false))
                case .none:
                    break
                }

            case .ended, .cancelled, .failed:
                if activeZone == .verticalTransition {
                    parent.onGestureEvent(.verticalTransition(translationY: translation.y, velocityY: velocity.y, ended: true))
                }
                activeZone = .none

            default:
                break
            }
        }

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = gestureRecognizer.view else { return false }
            let loc = touch.location(in: view)
            return !PlayerGestureOverlay.isExcludedTouchLocation(
                loc,
                bounds: view.bounds,
                safeAreaInsets: view.safeAreaInsets,
                excludedBottomHeight: parent.excludedBottomHeight
            )
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let view = gestureRecognizer.view else { return false }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let vel = pan.velocity(in: view)
                return abs(vel.y) > abs(vel.x) * 1.25
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

final class GestureArbitratorUIView: UIView {
    var onWindowAttached: (@MainActor (UIWindowScene?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onWindowAttached?(self.window?.windowScene)
        }
    }
}
