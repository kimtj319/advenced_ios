import Foundation

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

enum HTTPResilienceError: Error, Sendable, Equatable {
    case circuitBreakerOpen(host: String, retryAfter: TimeInterval)
    case invalidURL
}

/// Resilient HTTP client providing cancellation-safe GET coalescing and per-host 5-minute circuit breakers.
actor HTTPResilienceClient {
    private struct InFlightEntry {
        let task: Task<(Data, HTTPURLResponse), Error>
        var subscribers: Set<UUID>
    }

    private struct CircuitState {
        var consecutiveFailures: Int = 0
        var openedUntil: Date?
    }

    private let transport: any HTTPTransportProtocol
    private let now: @Sendable () -> Date
    private let circuitBreakerDuration: TimeInterval

    private var inFlight: [String: InFlightEntry] = [:]
    private var circuits: [String: CircuitState] = [:]

    init(
        transport: any HTTPTransportProtocol = URLSession.shared,
        now: @escaping @Sendable () -> Date = { Date() },
        circuitBreakerDuration: TimeInterval = 300
    ) {
        self.transport = transport
        self.now = now
        self.circuitBreakerDuration = circuitBreakerDuration
    }

    func perform(
        _ request: URLRequest,
        coalesce: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host?.lowercased() else {
            throw HTTPResilienceError.invalidURL
        }

        let currentDate = now()
        if let state = circuits[host], let openedUntil = state.openedUntil {
            if currentDate < openedUntil {
                throw HTTPResilienceError.circuitBreakerOpen(
                    host: host,
                    retryAfter: openedUntil.timeIntervalSince(currentDate)
                )
            }
            // Half-open window: allow a probe attempt.
        }

        let method = request.httpMethod?.uppercased() ?? "GET"
        guard coalesce && method == "GET" else {
            return try await executeSingle(request: request, host: host)
        }

        let key = makeCoalesceKey(for: request, url: url)
        let subscriberID = UUID()

        let sharedTask: Task<(Data, HTTPURLResponse), Error>
        if var existing = inFlight[key] {
            existing.subscribers.insert(subscriberID)
            inFlight[key] = existing
            sharedTask = existing.task
        } else {
            let task = Task<(Data, HTTPURLResponse), Error> { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.executeShared(request: request, host: host, coalesceKey: key)
            }
            inFlight[key] = InFlightEntry(task: task, subscribers: [subscriberID])
            sharedTask = task
        }

        return try await withTaskCancellationHandler {
            let result = try await sharedTask.value
            unsubscribe(key: key, subscriberID: subscriberID)
            return result
        } onCancel: {
            Task {
                await self.cancelSubscriber(key: key, subscriberID: subscriberID)
            }
        }
    }

    private func executeShared(
        request: URLRequest,
        host: String,
        coalesceKey: String
    ) async throws -> (Data, HTTPURLResponse) {
        defer { inFlight.removeValue(forKey: coalesceKey) }
        return try await executeSingle(request: request, host: host)
    }

    private func executeSingle(
        request: URLRequest,
        host: String
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport.data(for: request)
            if (500...599).contains(response.statusCode) {
                recordFailure(for: host)
            } else {
                recordSuccess(for: host)
            }
            return (data, response)
        } catch let urlError as URLError {
            if urlError.code == .timedOut || urlError.code == .networkConnectionLost {
                recordFailure(for: host)
            }
            throw urlError
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }
    }

    private func unsubscribe(key: String, subscriberID: UUID) {
        guard var entry = inFlight[key] else { return }
        entry.subscribers.remove(subscriberID)
        if entry.subscribers.isEmpty {
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = entry
        }
    }

    private func cancelSubscriber(key: String, subscriberID: UUID) {
        guard var entry = inFlight[key] else { return }
        entry.subscribers.remove(subscriberID)
        if entry.subscribers.isEmpty {
            inFlight.removeValue(forKey: key)
            entry.task.cancel()
        } else {
            inFlight[key] = entry
        }
    }

    private func recordSuccess(for host: String) {
        circuits[host] = CircuitState(consecutiveFailures: 0, openedUntil: nil)
    }

    private func recordFailure(for host: String) {
        var state = circuits[host] ?? CircuitState()
        state.consecutiveFailures += 1
        if state.consecutiveFailures >= 3 {
            state.openedUntil = now().addingTimeInterval(circuitBreakerDuration)
        }
        circuits[host] = state
    }

    private func makeCoalesceKey(for request: URLRequest, url: URL) -> String {
        let headers = (request.allHTTPHeaderFields ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return "\(url.absoluteString)|\(headers)"
    }
}
