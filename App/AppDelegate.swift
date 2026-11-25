import UIKit

/// Bridges UIApplication orientation queries to the shared `OrientationManager`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let orientationManager: OrientationManager

    override init() {
        self.orientationManager = .shared
        super.init()
    }

    init(orientationManager: OrientationManager) {
        self.orientationManager = orientationManager
        super.init()
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        orientationManager.allowedOrientations
    }
}
