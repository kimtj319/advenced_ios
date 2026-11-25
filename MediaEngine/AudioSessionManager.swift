import AVFoundation
import Foundation

@MainActor
protocol AudioSessionManagerProtocol: AnyObject {
    var onInterruptionBegan: (@MainActor () -> Void)? { get set }
    var onInterruptionEndedShouldResume: (@MainActor () -> Void)? { get set }
    var onRouteDisconnected: (@MainActor () -> Void)? { get set }
    var onMediaServicesReset: (@MainActor () -> Void)? { get set }
    func configurePlaybackSession() throws
    func activateSession() throws
    func startObserving()
    func stopObserving()
}

/// Configures `.playback` audio session (without `.mixWithOthers`) and handles route/interruption events.
@MainActor
final class AudioSessionManager: AudioSessionManagerProtocol {
    var onInterruptionBegan: (@MainActor () -> Void)?
    var onInterruptionEndedShouldResume: (@MainActor () -> Void)?
    var onRouteDisconnected: (@MainActor () -> Void)?
    var onMediaServicesReset: (@MainActor () -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {}

    func configurePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Never include `.mixWithOthers` as it disables automatic inline PiP on iOS.
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
        try session.setActive(true)
    }

    func activateSession() throws {
        try AVAudioSession.sharedInstance().setActive(true)
    }

    func startObserving() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
                let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                Task { @MainActor [weak self] in
                    guard let self,
                          let rawType,
                          let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                    switch type {
                    case .began:
                        self.onInterruptionBegan?()
                    case .ended:
                        let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                        if options.contains(.shouldResume) {
                            do {
                                try self.activateSession()
                                self.onInterruptionEndedShouldResume?()
                            } catch {
                                // Failed to reactivate audio session; leave playback paused safely.
                            }
                        }
                    @unknown default:
                        break
                    }
                }
            }
        )

        observers.append(
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] note in
                let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor [weak self] in
                    guard let self,
                          let rawReason,
                          let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
                          reason == .oldDeviceUnavailable else { return }
                    self.onRouteDisconnected?()
                }
            }
        )

        observers.append(
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? self.configurePlaybackSession()
                    self.onMediaServicesReset?()
                }
            }
        )
    }

    func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}
