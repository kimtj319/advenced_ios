import SwiftData
import SwiftUI

@main
struct YouTubeAdvancedApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    @State private var dependencies: AppDependencies?

    var body: some Scene {
        WindowGroup {
            if isRunningUnitTests {
                EmptyView()
            } else if let deps = dependencies {
                AppRootView(
                    bootstrapResult: deps.bootstrapResult,
                    coordinator: deps.coordinator,
                    repository: deps.repository,
                    persistence: deps.persistence,
                    importer: deps.importer,
                    keychain: deps.keychain,
                    resolver: deps.resolver,
                    filterService: deps.filterService
                )
            } else {
                ProgressView()
                    .task {
                        if dependencies == nil {
                            dependencies = AppDependencies.makeLive()
                        }
                    }
            }
        }
    }
}

@MainActor
private final class AppDependencies {
    let bootstrapResult: AppContainerBootstrapResult
    let persistence: PersistenceWorker
    let importer: SubscriptionImporter
    let keychain: KeychainStore
    let repository: CompositeVideoRepository
    let resolver: PlayableSourceResolver
    let filterService: FeedFilterService
    let coordinator: PlaybackCoordinator

    private init(
        bootstrapResult: AppContainerBootstrapResult,
        persistence: PersistenceWorker,
        importer: SubscriptionImporter,
        keychain: KeychainStore,
        repository: CompositeVideoRepository,
        resolver: PlayableSourceResolver,
        filterService: FeedFilterService,
        coordinator: PlaybackCoordinator
    ) {
        self.bootstrapResult = bootstrapResult
        self.persistence = persistence
        self.importer = importer
        self.keychain = keychain
        self.repository = repository
        self.resolver = resolver
        self.filterService = filterService
        self.coordinator = coordinator
    }

    static func makeLive() -> AppDependencies {
        let bootstrap = AppContainerFactory.makeContainer()
        let persistence = PersistenceWorker(modelContainer: bootstrap.container)
        let importer = SubscriptionImporter(persistence: persistence)
        let keychain = KeychainStore()
        let httpClient = HTTPResilienceClient()

        let rssProvider = RSSFeedProvider(httpClient: httpClient)
        let apiProvider = YouTubeDataAPIv3Provider(httpClient: httpClient, keychain: keychain)
        let repository = CompositeVideoRepository(rssProvider: rssProvider, apiProvider: apiProvider)

        let defaults = UserDefaults.standard
        let savedKind = defaults.string(forKey: "endpointKind").flatMap(StreamEndpointKind.init(rawValue:)) ?? .webEmbedOnly
        let savedURL = defaults.string(forKey: "endpointURLString") ?? ""
        let preferHLS = defaults.object(forKey: "endpointPreferHLS") as? Bool ?? true
        let fallbackWeb = defaults.object(forKey: "endpointFallbackWeb") as? Bool ?? true
        let endpointSettings = StreamEndpointSettings(
            kind: savedKind,
            endpointURLString: savedURL,
            preferHLS: preferHLS,
            fallbackToWebEmbedOnFailure: fallbackWeb
        )

        let resolver = PlayableSourceResolver(httpClient: httpClient, initialSettings: endpointSettings)
        let recovery = StreamRecoveryController(resolver: resolver)
        let ruleArbitrator = PlaybackRuleArbitrator()
        let queueManager = QueueManager()
        let nowPlayingManager = NowPlayingManager()
        let audioSessionManager = AudioSessionManager()
        let sponsorBlockClient = SponsorBlockClient(httpClient: httpClient)
        let returnDislikeClient = ReturnDislikeClient(httpClient: httpClient)
        let regexCache = RegexCacheActor()
        let filterService = FeedFilterService(regexCache: regexCache)

        let coordinator = PlaybackCoordinator(
            nativeEngine: AVPlayerEngine(),
            webEngine: WKWebViewEngine(),
            resolver: resolver,
            recoveryController: recovery,
            ruleArbitrator: ruleArbitrator,
            queueManager: queueManager,
            nowPlayingManager: nowPlayingManager,
            audioSessionManager: audioSessionManager,
            persistence: persistence,
            sponsorBlockClient: sponsorBlockClient,
            returnDislikeClient: returnDislikeClient
        )

        return AppDependencies(
            bootstrapResult: bootstrap,
            persistence: persistence,
            importer: importer,
            keychain: keychain,
            repository: repository,
            resolver: resolver,
            filterService: filterService,
            coordinator: coordinator
        )
    }
}
