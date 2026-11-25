import Foundation

/// Multicast `AsyncStream` broadcaster preventing unicast subscriber contention or continuation leaks.
@MainActor
final class EngineEventBroadcaster {
    private var continuations: [UUID: AsyncStream<PlaybackEngineEvent>.Continuation] = [:]

    init() {}

    func makeStream() -> AsyncStream<PlaybackEngineEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    func send(_ event: PlaybackEngineEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func finishAll() {
        let active = Array(continuations.values)
        continuations.removeAll()
        for continuation in active {
            continuation.finish()
        }
    }
}
