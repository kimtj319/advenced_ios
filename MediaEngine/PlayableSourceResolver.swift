import Foundation

protocol StreamResolverProtocol: Sendable {
    func resolve(video: VideoItem, bypassCache: Bool) async throws -> PlayableSource
    func updateSettings(_ settings: StreamEndpointSettings) async
}

enum StreamEndpointValidationError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL
    case remoteHTTPNotAllowed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "유효한 URL 형식이 아닙니다."
        case .remoteHTTPNotAllowed:
            return "원격 서버는 HTTPS만 허용됩니다(로컬 네트워크만 HTTP 허용)."
        }
    }
}

/// Validates user-configured endpoints: HTTPS for remote hosts, HTTP only for local/RFC-1918 networks.
struct StreamEndpointValidator: Sendable {
    static func validate(urlString: String) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            throw StreamEndpointValidationError.invalidURL
        }

        if scheme == "https" {
            return url
        }
        if scheme == "http" && isAllowedLocalHost(host) {
            return url
        }
        throw StreamEndpointValidationError.remoteHTTPNotAllowed
    }

    static func isAllowedLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return true
        }
        let parts = host.split(separator: ".")
        guard parts.count == 4,
              let a = Int(parts[0]),
              let b = Int(parts[1]),
              let c = Int(parts[2]),
              let d = Int(parts[3]),
              (0...255).contains(a),
              (0...255).contains(b),
              (0...255).contains(c),
              (0...255).contains(d) else {
            return false
        }

        // RFC 1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
        if a == 10 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        return false
    }
}

/// Resolves `VideoItem` into a `PlayableSource` via Piped, Invidious, custom templates, or IFrame embed.
actor PlayableSourceResolver: StreamResolverProtocol {
    private static let defaultEmbedBaseURL = URL(string: "https://www.youtube-nocookie.com")!
    private let httpClient: HTTPResilienceClient
    private let now: @Sendable () -> Date
    private var settings: StreamEndpointSettings
    private var cache: [String: (source: PlayableSource, resolvedAt: Date)] = [:]
    private let cacheTTL: TimeInterval = 600

    init(
        httpClient: HTTPResilienceClient,
        initialSettings: StreamEndpointSettings = StreamEndpointSettings(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.httpClient = httpClient
        self.settings = initialSettings
        self.now = now
    }

    func updateSettings(_ newSettings: StreamEndpointSettings) async {
        self.settings = newSettings
        self.cache.removeAll()
    }

    func resolve(video: VideoItem, bypassCache: Bool) async throws -> PlayableSource {
        let currentDate = now()
        if bypassCache {
            cache.removeValue(forKey: video.id)
        } else if let entry = cache[video.id], currentDate.timeIntervalSince(entry.resolvedAt) < cacheTTL {
            return entry.source
        }

        if settings.kind == .webEmbedOnly {
            let embed = PlayableSource.webEmbed(videoID: video.id, baseURL: Self.defaultEmbedBaseURL)
            cache[video.id] = (embed, currentDate)
            return embed
        }

        do {
            let resolved = try await resolveDirectSource(for: video)
            cache[video.id] = (resolved, currentDate)
            return resolved
        } catch {
            // Only fall back to webEmbed on initial load; bypassCache (recovery) must propagate failure.
            if !bypassCache && settings.fallbackToWebEmbedOnFailure {
                return .webEmbed(videoID: video.id, baseURL: Self.defaultEmbedBaseURL)
            }
            if let playbackError = error as? PlaybackError {
                throw playbackError
            }
            throw PlaybackError.sourceResolutionFailed(error.localizedDescription)
        }
    }

    private func resolveDirectSource(for video: VideoItem) async throws -> PlayableSource {
        switch settings.kind {
        case .webEmbedOnly:
            return .webEmbed(videoID: video.id, baseURL: Self.defaultEmbedBaseURL)

        case .customTemplate:
            let substituted = settings.endpointURLString.replacingOccurrences(of: "{videoId}", with: video.id)
            let validURL = try StreamEndpointValidator.validate(urlString: substituted)
            let format: PlayableSource.DirectStreamFormat = validURL.pathExtension.lowercased() == "m3u8"
                ? .hls
                : .muxedMP4
            return .direct(url: validURL, format: format, headers: [:])

        case .pipedAPI:
            let baseURL = try StreamEndpointValidator.validate(urlString: settings.endpointURLString)
            let endpoint = baseURL.appendingPathComponent("streams").appendingPathComponent(video.id)
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 3.5

            let (data, response) = try await httpClient.perform(request, coalesce: true)
            guard (200...299).contains(response.statusCode) else {
                throw PlaybackError.sourceResolutionFailed("Piped HTTP \(response.statusCode)")
            }
            let payload = try JSONDecoder().decode(PipedStreamPayload.self, from: data)
            if settings.preferHLS, let hlsString = payload.hls, let hlsURL = URL(string: hlsString) {
                return .direct(url: hlsURL, format: .hls, headers: [:])
            }
            let muxed = payload.videoStreams
                .filter { $0.videoOnly == false && $0.format?.uppercased() == "MPEG_4" }
                .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
                .first
            if let streamURLString = muxed?.url, let streamURL = URL(string: streamURLString) {
                return .direct(url: streamURL, format: .muxedMP4, headers: [:])
            }
            throw PlaybackError.sourceResolutionFailed("No compatible HLS or muxed MP4 stream found")

        case .invidiousAPI:
            let baseURL = try StreamEndpointValidator.validate(urlString: settings.endpointURLString)
            let endpoint = baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("v1")
                .appendingPathComponent("videos")
                .appendingPathComponent(video.id)
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 3.5

            let (data, response) = try await httpClient.perform(request, coalesce: true)
            guard (200...299).contains(response.statusCode) else {
                throw PlaybackError.sourceResolutionFailed("Invidious HTTP \(response.statusCode)")
            }
            let payload = try JSONDecoder().decode(InvidiousVideoPayload.self, from: data)
            if settings.preferHLS, let hlsString = payload.hlsUrl, let hlsURL = URL(string: hlsString) {
                return .direct(url: hlsURL, format: .hls, headers: [:])
            }
            let muxed = payload.formatStreams
                .filter { $0.container?.lowercased() == "mp4" }
                .last
            if let streamURLString = muxed?.url, let streamURL = URL(string: streamURLString) {
                return .direct(url: streamURL, format: .muxedMP4, headers: [:])
            }
            throw PlaybackError.sourceResolutionFailed("No compatible HLS or MP4 stream found")
        }
    }
}

private struct PipedStreamPayload: Decodable {
    let hls: String?
    let videoStreams: [PipedVideoStream]

    struct PipedVideoStream: Decodable {
        let url: String?
        let format: String?
        let videoOnly: Bool?
        let height: Int?
    }
}

private struct InvidiousVideoPayload: Decodable {
    let hlsUrl: String?
    let formatStreams: [InvidiousFormatStream]

    struct InvidiousFormatStream: Decodable {
        let url: String?
        let container: String?
    }
}
