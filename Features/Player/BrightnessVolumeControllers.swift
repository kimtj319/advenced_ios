import MediaPlayer
import Observation
import os
import SwiftUI
import UIKit

/// Multi-scene safe brightness controller that restores system brightness on exit or Control Center override.
@MainActor
@Observable
final class BrightnessController {
    private weak var screen: UIScreen?
    private var originalBrightness: CGFloat?
    private var playerBrightness: CGFloat?
    private var isApplyingProgrammaticChange = false
    private let observerTasksLock = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])

    init() {}

    func attach(to windowScene: UIWindowScene?) {
        screen = windowScene?.screen
        let hasObservers = observerTasksLock.withLock { !$0.isEmpty }
        guard !hasObservers else { return }

        let resignTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.willResignActiveNotification) {
                guard !Task.isCancelled else { break }
                self?.restoreOriginalBrightness(keepPlayerPreference: true)
            }
        }

        let activeTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                guard !Task.isCancelled else { break }
                self?.reapplyPlayerBrightnessIfNeeded()
            }
        }

        let brightnessTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIScreen.brightnessDidChangeNotification) {
                guard !Task.isCancelled else { break }
                guard let self, !self.isApplyingProgrammaticChange, let screen = self.screen else { continue }
                // Respect Control Center adjustments made manually by the user.
                if self.originalBrightness != nil {
                    self.originalBrightness = screen.brightness
                    self.playerBrightness = screen.brightness
                }
            }
        }

        observerTasksLock.withLock {
            $0.append(contentsOf: [resignTask, activeTask, brightnessTask])
        }
    }

    @discardableResult
    func adjust(by delta: CGFloat) -> CGFloat {
        guard let screen else { return 0.5 }
        if originalBrightness == nil {
            originalBrightness = screen.brightness
        }
        let base = playerBrightness ?? screen.brightness
        let next = min(max(base + delta, 0.0), 1.0)
        apply(next, to: screen)
        playerBrightness = next
        return next
    }

    func restoreOriginalBrightness(keepPlayerPreference: Bool = false) {
        guard let screen, let original = originalBrightness else { return }
        apply(original, to: screen)
        originalBrightness = nil
        if !keepPlayerPreference {
            playerBrightness = nil
        }
    }

    private func reapplyPlayerBrightnessIfNeeded() {
        guard let screen, let saved = playerBrightness else { return }
        originalBrightness = screen.brightness
        apply(saved, to: screen)
    }

    private func apply(_ value: CGFloat, to screen: UIScreen) {
        isApplyingProgrammaticChange = true
        screen.brightness = value
        isApplyingProgrammaticChange = false
    }

    deinit {
        observerTasksLock.withLock { tasks in
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }
}

/// Safe hardware volume slider bridge falling back to a local clamped no-op on simulators.
@MainActor
final class SystemVolumeController {
    private weak var volumeSlider: UISlider?
    private(set) var fallbackLevel: Float = 0.5

    init() {}

    func bind(to volumeView: MPVolumeView) {
        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            volumeSlider = slider
            fallbackLevel = slider.value
        }
    }

    @discardableResult
    func adjust(by delta: Float) -> Float {
        guard let slider = volumeSlider else {
            fallbackLevel = min(max(fallbackLevel + delta, 0.0), 1.0)
            return fallbackLevel
        }
        let next = min(max(slider.value + delta, 0.0), 1.0)
        slider.setValue(next, animated: false)
        slider.sendActions(for: .valueChanged)
        fallbackLevel = next
        return next
    }
}

struct VolumeBridgeView: UIViewRepresentable {
    let controller: SystemVolumeController

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.alpha = 0.01
        view.isHidden = false
        controller.bind(to: view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        controller.bind(to: uiView)
    }
}
