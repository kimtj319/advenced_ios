import Foundation

/// Strategy used by `PlayableSourceResolver` to resolve video playback sources.
enum StreamEndpointKind: String, Sendable, Equatable, Codable, CaseIterable {
    case webEmbedOnly
    case pipedAPI
    case invidiousAPI
    case customTemplate
}

/// User-configured stream resolution settings.
struct StreamEndpointSettings: Sendable, Equatable, Codable {
    var kind: StreamEndpointKind = .webEmbedOnly
    var endpointURLString: String = ""
    var preferHLS: Bool = true
    var fallbackToWebEmbedOnFailure: Bool = true
}
