import Foundation
import os
import XCTest
@testable import YouTubeAdvanced

private final class MockHTTPTransport: HTTPTransportProtocol, @unchecked Sendable {
    private struct State {
        var requests: [URLRequest] = []
        var handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.lock = OSAllocatedUnfairLock(initialState: State(handler: handler))
    }

    var requestCount: Int {
        lock.withLock { $0.requests.count }
    }

    func setHandler(_ handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        lock.withLock { $0.handler = handler }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler = lock.withLock { state -> (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) in
            state.requests.append(request)
            return state.handler
        }
        return try await handler(request)
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Date>

    init(_ initial: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.lock = OSAllocatedUnfairLock(initialState: initial)
    }

    var now: Date {
        lock.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

final class SponsorBlockClientTests: XCTestCase {
    func testSHA256HexPrefix4_ReturnsExactlyFourHexCharacters() {
        let prefix = SponsorBlockClient.sha256HexPrefix4(for: "dQw4w9WgXcQ")
        XCTAssertEqual(prefix.count, 4)
        let isHex = prefix.allSatisfy { $0.isHexDigit }
        XCTAssertTrue(isHex)
    }

    func testFetchSegments_FiltersMatchingVideoIDFromHashCollisionResponse() async {
        let payload = """
        [
          {
            "videoID": "otherVideo99",
            "segments": [
              { "UUID": "u-other", "category": "sponsor", "actionType": "skip", "segment": [5.0, 25.0] }
            ]
          },
          {
            "videoID": "targetVid01",
            "segments": [
              { "UUID": "u-match-1", "category": "sponsor", "actionType": "skip", "segment": [10.0, 30.0] },
              { "UUID": "u-match-2", "category": "poi_highlight", "actionType": "poi", "segment": [42.0, 42.0] }
            ]
          }
        ]
        """

        let transport = MockHTTPTransport { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(payload.utf8), response)
        }
        let resilience = HTTPResilienceClient(transport: transport)
        let client = SponsorBlockClient(httpClient: resilience)

        let segments = await client.fetchSegments(for: "targetVid01")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(Set(segments.map(\.uuid)), ["u-match-1", "u-match-2"])
    }

    func testFetchSegments_HTTP404_CachesEmptyResultWithoutTrippingCircuitBreaker() async {
        let transport = MockHTTPTransport { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        let resilience = HTTPResilienceClient(transport: transport)
        let client = SponsorBlockClient(httpClient: resilience)

        let first = await client.fetchSegments(for: "noSegments1")
        let second = await client.fetchSegments(for: "noSegments1")
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testCircuitBreaker_OpensAfterThree5xxFailuresAndRecoversAfterFiveMinutes() async {
        let clock = MutableClock()
        let transport = MockHTTPTransport { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        let resilience = HTTPResilienceClient(transport: transport, now: { clock.now }, circuitBreakerDuration: 300)
        let client = SponsorBlockClient(httpClient: resilience, now: { clock.now })

        // 3 consecutive 503 failures open the circuit breaker.
        _ = await client.fetchSegments(for: "vidA")
        _ = await client.fetchSegments(for: "vidB")
        _ = await client.fetchSegments(for: "vidC")
        XCTAssertEqual(transport.requestCount, 3)

        // 4th call while circuit is open does NOT hit transport.
        let blocked = await client.fetchSegments(for: "vidD")
        XCTAssertTrue(blocked.isEmpty)
        XCTAssertEqual(transport.requestCount, 3)

        // Advance virtual clock by +301 seconds -> half-open probe succeeds.
        clock.advance(by: 301)
        transport.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        let recovered = await client.fetchSegments(for: "vidE")
        XCTAssertTrue(recovered.isEmpty)
        XCTAssertEqual(transport.requestCount, 4)
    }
}
