import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// App settings covering YouTube API key, stream endpoints, SponsorBlock, Clean Feed filters, and OPML/CSV import.
struct SettingsView: View {
    let keychain: any KeychainStoreProtocol
    let repository: CompositeVideoRepository
    let resolver: any StreamResolverProtocol
    let persistence: any PersistenceWorkerProtocol
    let importer: any SubscriptionImporterProtocol
    let coordinator: PlaybackCoordinator

    @AppStorage("defaultStartTab") private var defaultStartTab: Int = 0
    @AppStorage("hideShorts") private var hideShorts: Bool = true
    @AppStorage("endpointKind") private var endpointKindRaw: String = StreamEndpointKind.webEmbedOnly.rawValue
    @AppStorage("endpointURLString") private var endpointURLString: String = ""
    @AppStorage("endpointPreferHLS") private var endpointPreferHLS: Bool = true
    @AppStorage("endpointFallbackWeb") private var endpointFallbackWeb: Bool = true

    @State private var apiKeyInput = ""
    @State private var apiKeySavedNotice: String?
    @State private var bundleCopied = false

    @State private var endpointValidationError: String?
    @State private var endpointSavedNotice: String?

    @State private var filterRules: [FilterRuleDTO] = []
    @State private var newRuleKeyword = ""
    @State private var newRuleIsRegex = false
    @State private var newRuleScope: FilterTargetScope = .all

    @State private var showFileImporter = false
    @State private var importResult: SubscriptionImportResult?
    @State private var importError: String?

    private var currentBundleID: String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }

    var body: some View {
        NavigationStack {
            Form {
                apiKeySection
                streamEndpointSection
                playbackAndPiPSection
                sponsorBlockSection
                cleanFeedSection
                subscriptionImportSection
            }
            .navigationTitle("설정")
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [
                    UTType(filenameExtension: "opml") ?? .xml,
                    .xml,
                    .commaSeparatedText,
                    .plainText
                ],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .sheet(item: Binding(
                get: { importResult.map { ImportReportWrapper(result: $0) } },
                set: { if $0 == nil { importResult = nil } }
            )) { wrapper in
                ImportResultSheet(result: wrapper.result) {
                    importResult = nil
                }
            }
            .task {
                apiKeyInput = keychain.loadAPIKey() ?? ""
                filterRules = (try? await persistence.fetchFilterRules()) ?? []
            }
        }
    }

    // MARK: - Sections

    private var apiKeySection: some View {
        Section("YouTube Data API v3") {
            SecureField("개인 API 키 입력", text: $apiKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack {
                Button("API 키 저장") {
                    do {
                        try keychain.saveAPIKey(apiKeyInput)
                        apiKeySavedNotice = "저장되었습니다. 쿼터 차단 상태가 초기화됩니다."
                        Task { await repository.notifyAPIKeyUpdated() }
                    } catch {
                        apiKeySavedNotice = error.localizedDescription
                    }
                }
                Spacer()
                Button("삭제", role: .destructive) {
                    try? keychain.deleteAPIKey()
                    apiKeyInput = ""
                    apiKeySavedNotice = "API 키가 삭제되었습니다."
                    Task { await repository.notifyAPIKeyUpdated() }
                }
            }

            if let apiKeySavedNotice {
                Text(apiKeySavedNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("현재 번들 ID (리사이닝 확인용)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(currentBundleID)
                        .font(.caption.monospaced())
                }
                Spacer()
                Button(bundleCopied ? "복사됨" : "번들 ID 복사") {
                    UIPasteboard.general.string = currentBundleID
                    bundleCopied = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var streamEndpointSection: some View {
        Section("스트림 엔드포인트 (AVPlayer / 호환 모드)") {
            Picker("방식", selection: $endpointKindRaw) {
                Text("WebEmbed 전용 (기본)").tag(StreamEndpointKind.webEmbedOnly.rawValue)
                Text("Piped API").tag(StreamEndpointKind.pipedAPI.rawValue)
                Text("Invidious API").tag(StreamEndpointKind.invidiousAPI.rawValue)
                Text("커스텀 템플릿").tag(StreamEndpointKind.customTemplate.rawValue)
            }

            if endpointKindRaw != StreamEndpointKind.webEmbedOnly.rawValue {
                TextField("https://... 또는 로컬 http://192.168.x.x", text: $endpointURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Toggle("HLS 우선 선택", isOn: $endpointPreferHLS)
                Toggle("실패 시 IFrame Embed 폴백", isOn: $endpointFallbackWeb)

                if let endpointValidationError {
                    Text(endpointValidationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Button("엔드포인트 적용") {
                applyEndpointSettings()
            }

            if let endpointSavedNotice {
                Text(endpointSavedNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var playbackAndPiPSection: some View {
        Section("재생, 백그라운드 & 시작 탭") {
            Toggle(
                "백그라운드 오디오 재생",
                isOn: Binding(
                    get: { coordinator.backgroundAudioEnabled },
                    set: { coordinator.backgroundAudioEnabled = $0 }
                )
            )
            Toggle(
                "백그라운드 전환 시 자동 PiP",
                isOn: Binding(
                    get: { coordinator.autoPiPEnabled },
                    set: { coordinator.autoPiPEnabled = $0 }
                )
            )
            Picker("시작 탭", selection: $defaultStartTab) {
                Text("홈").tag(0)
                Text("구독").tag(1)
                Text("검색").tag(2)
                Text("보관함").tag(3)
                Text("설정").tag(4)
            }
        }
    }

    private var sponsorBlockSection: some View {
        Section("SponsorBlock 카테고리") {
            ForEach(SponsorCategory.allCases, id: \.self) { category in
                Toggle(
                    category.rawValue,
                    isOn: Binding(
                        get: { coordinator.enabledSponsorCategories.contains(category) },
                        set: { enabled in
                            if enabled {
                                coordinator.enabledSponsorCategories.insert(category)
                            } else {
                                coordinator.enabledSponsorCategories.remove(category)
                            }
                        }
                    )
                )
            }
        }
    }

    private var cleanFeedSection: some View {
        Section("Clean Feed & 필터 규칙") {
            Toggle("Shorts 숨김", isOn: $hideShorts)

            VStack(alignment: .leading, spacing: 8) {
                TextField("차단 키워드 또는 정규식", text: $newRuleKeyword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Toggle("정규식(Regex) 사용", isOn: $newRuleIsRegex)

                Picker("적용 대상", selection: $newRuleScope) {
                    Text("전체").tag(FilterTargetScope.all)
                    Text("제목만").tag(FilterTargetScope.titleOnly)
                    Text("채널명만").tag(FilterTargetScope.channelNameOnly)
                }
                .pickerStyle(.segmented)

                if newRuleIsRegex && !newRuleKeyword.isEmpty && !RegexCacheActor.validatePattern(newRuleKeyword) {
                    Text("유효하지 않은 정규식 문법입니다.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("필터 규칙 추가") {
                    let rule = FilterRuleDTO(
                        id: UUID(),
                        keyword: newRuleKeyword.trimmingCharacters(in: .whitespacesAndNewlines),
                        isRegex: newRuleIsRegex,
                        targetScope: newRuleScope,
                        isEnabled: true
                    )
                    Task {
                        try? await persistence.upsertFilterRule(rule)
                        filterRules = (try? await persistence.fetchFilterRules()) ?? []
                        newRuleKeyword = ""
                    }
                }
                .disabled(!canAddFilterRule)
            }

            ForEach(filterRules) { rule in
                HStack {
                    VStack(alignment: .leading) {
                        Text(rule.keyword)
                            .font(.subheadline)
                        Text("\(rule.isRegex ? "Regex" : "Keyword") · \(rule.targetScope.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        Task {
                            try? await persistence.deleteFilterRule(id: rule.id)
                            filterRules = (try? await persistence.fetchFilterRules()) ?? []
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }

    private var subscriptionImportSection: some View {
        Section("구독 가져오기 (OPML / Takeout CSV)") {
            Button("OPML 또는 CSV 파일 선택") {
                importError = nil
                showFileImporter = true
            }

            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Helpers

    private var canAddFilterRule: Bool {
        let trimmed = newRuleKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if newRuleIsRegex {
            return RegexCacheActor.validatePattern(trimmed)
        }
        return true
    }

    private func applyEndpointSettings() {
        endpointValidationError = nil
        endpointSavedNotice = nil
        let kind = StreamEndpointKind(rawValue: endpointKindRaw) ?? .webEmbedOnly

        if kind != .webEmbedOnly {
            let sample = endpointURLString.replacingOccurrences(of: "{videoId}", with: "dQw4w9WgXcQ")
            do {
                _ = try StreamEndpointValidator.validate(urlString: sample)
            } catch {
                endpointValidationError = error.localizedDescription
                return
            }
        }

        let settings = StreamEndpointSettings(
            kind: kind,
            endpointURLString: endpointURLString,
            preferHLS: endpointPreferHLS,
            fallbackToWebEmbedOnFailure: endpointFallbackWeb
        )
        Task {
            await resolver.updateSettings(settings)
            endpointSavedNotice = "스트림 설정이 적용되었습니다."
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    importResult = try await importer.importFromFileURL(url)
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
    }
}

private struct ImportReportWrapper: Identifiable {
    let id = UUID()
    let result: SubscriptionImportResult
}

private struct ImportResultSheet: View {
    let result: SubscriptionImportResult
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("가져오기 요약") {
                    LabeledContent("새로 추가됨", value: "\(result.importedCount)개")
                    LabeledContent("중복 건너뜀", value: "\(result.duplicateSkippedCount)개")
                    LabeledContent("실패한 행", value: "\(result.failedRows.count)개")
                }

                if !result.failedRows.isEmpty {
                    Section("실패 상세") {
                        ForEach(Array(result.failedRows.enumerated()), id: \.offset) { _, err in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("행 #\(err.lineOrElementIndex): \(err.reason)")
                                    .font(.caption.bold())
                                Text(err.rawValue)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("가져오기 결과")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기", action: onDismiss)
                }
            }
        }
    }
}
