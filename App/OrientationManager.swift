import Observation
import UIKit

/// Manages supported interface orientations and serializes geometry update requests on iOS 17+.
@MainActor
@Observable
final class OrientationManager {
    static let shared = OrientationManager()

    private(set) var allowedOrientations: UIInterfaceOrientationMask = .portrait
    private(set) var isTransitioningOrientation: Bool = false

    init() {}

    /// Updates the allowed orientation mask and requests a window scene geometry transition.
    func lock(to mask: UIInterfaceOrientationMask, in windowScene: UIWindowScene? = nil) async {
        allowedOrientations = mask

        let targetScene = windowScene ?? activeWindowScene()
        guard let targetScene else { return }

        isTransitioningOrientation = true
        defer { isTransitioningOrientation = false }

        targetScene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()

        let preferredOrientation: UIInterfaceOrientationMask
        if mask.contains(.landscape) && !mask.contains(.portrait) {
            preferredOrientation = .landscapeRight
        } else {
            preferredOrientation = mask
        }

        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: preferredOrientation)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            targetScene.requestGeometryUpdate(preferences) { _ in
                // Geometry update may fail on simulator or constrained multitasking scenes; safe to continue.
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                continuation.resume()
            }
        }
    }

    func setFullscreen(_ fullscreen: Bool, in windowScene: UIWindowScene? = nil) async {
        await lock(to: fullscreen ? .landscape : .portrait, in: windowScene)
    }

    private func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }
}
