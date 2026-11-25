import Foundation

protocol SubscriptionImporterProtocol: Sendable {
    func importOPML(data: Data) async throws -> SubscriptionImportResult
    func importTakeoutCSV(data: Data) async throws -> SubscriptionImportResult
    func importFromFileURL(_ url: URL) async throws -> SubscriptionImportResult
}

enum SubscriptionImportError: Error, LocalizedError, Sendable {
    case unreadableFile
    case unsupportedEncoding
    case emptyInput

    var errorDescription: String? {
        switch self {
        case .unreadableFile: return "선택한 파일을 읽을 수 없습니다."
        case .unsupportedEncoding: return "지원하지 않는 텍스트 인코딩입니다."
        case .emptyInput: return "가져올 구독 데이터가 비어 있습니다."
        }
    }
}

/// Parses OPML and YouTube Takeout CSV files with partial-failure recovery.
struct SubscriptionImporter: SubscriptionImporterProtocol {
    private let persistence: any PersistenceWorkerProtocol

    init(persistence: any PersistenceWorkerProtocol) {
        self.persistence = persistence
    }

    func importFromFileURL(_ url: URL) async throws -> SubscriptionImportResult {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SubscriptionImportError.unreadableFile
        }

        let ext = url.pathExtension.lowercased()
        if ext == "opml" || ext == "xml" {
            return try await importOPML(data: data)
        }
        if ext == "csv" {
            return try await importTakeoutCSV(data: data)
        }

        // Sniff leading content when extension is missing or `.txt`.
        let head = String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("<") {
            return try await importOPML(data: data)
        }
        return try await importTakeoutCSV(data: data)
    }

    func importOPML(data: Data) async throws -> SubscriptionImportResult {
        guard !data.isEmpty else { throw SubscriptionImportError.emptyInput }
        let helper = OPMLParserHelper()
        let parsed = helper.parse(data: data)
        return try await commitParsedChannels(candidates: parsed.candidates, initialFailures: parsed.failures)
    }

    func importTakeoutCSV(data: Data) async throws -> SubscriptionImportResult {
        guard !data.isEmpty else { throw SubscriptionImportError.emptyInput }
        guard var text = decodeText(data) else {
            throw SubscriptionImportError.unsupportedEncoding
        }

        // Strip UTF-8 BOM if present.
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }

        let rows = parseRFC4180CSV(text)
        guard !rows.isEmpty else { throw SubscriptionImportError.emptyInput }

        var candidates: [(line: Int, dto: SubscribedChannelDTO)] = []
        var failures: [SubscriptionImportRowError] = []

        var idColumnIndex: Int?
        var urlColumnIndex: Int?
        var titleColumnIndex: Int?
        var startRow = 0

        if let firstRow = rows.first, isHeaderRow(firstRow) {
            startRow = 1
            for (idx, cell) in firstRow.enumerated() {
                let norm = cell.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if norm.contains("channel id") || norm.contains("채널 id") || norm == "id" {
                    idColumnIndex = idx
                } else if norm.contains("channel url") || norm.contains("채널 url") || norm == "url" {
                    urlColumnIndex = idx
                } else if norm.contains("channel title") || norm.contains("채널 제목") || norm.contains("title") || norm == "name" {
                    titleColumnIndex = idx
                }
            }
        }

        for rowIndex in startRow..<rows.count {
            let fields = rows[rowIndex]
            let lineNumber = rowIndex + 1

            // Skip completely blank lines.
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }

            let rawLine = fields.joined(separator: ",")
            let rawIdField = idColumnIndex.flatMap { $0 < fields.count ? fields[$0] : nil }
            let rawUrlField = urlColumnIndex.flatMap { $0 < fields.count ? fields[$0] : nil }
            let rawTitleField = titleColumnIndex.flatMap { $0 < fields.count ? fields[$0] : nil }

            let resolvedChannelId = Self.extractChannelID(from: rawIdField)
                ?? Self.extractChannelID(from: rawUrlField)
                ?? fields.lazy.compactMap { Self.extractChannelID(from: $0) }.first

            guard let channelId = resolvedChannelId else {
                failures.append(
                    SubscriptionImportRowError(
                        lineOrElementIndex: lineNumber,
                        rawValue: rawLine,
                        reason: "유효한 YouTube Channel ID(UC...)를 찾을 수 없습니다."
                    )
                )
                continue
            }

            let fallbackTitle = fields.last?.trimmingCharacters(in: .whitespacesAndNewlines)
            let channelName: String
            if let explicit = rawTitleField?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
                channelName = explicit
            } else if let fallback = fallbackTitle, !fallback.isEmpty, fallback != channelId {
                channelName = fallback
            } else {
                channelName = channelId
            }

            let dto = SubscribedChannelDTO(
                channelId: channelId,
                name: channelName,
                avatarURLString: nil,
                addedAt: .now,
                lastSyncedAt: nil,
                etag: nil
            )
            candidates.append((lineNumber, dto))
        }

        return try await commitParsedChannels(candidates: candidates, initialFailures: failures)
    }

    // MARK: - Helpers

    private func commitParsedChannels(
        candidates: [(line: Int, dto: SubscribedChannelDTO)],
        initialFailures: [SubscriptionImportRowError]
    ) async throws -> SubscriptionImportResult {
        let existingIds = Set((try await persistence.fetchSubscriptions()).map(\.channelId))
        var seenInBatch = Set<String>()
        var toInsert: [SubscribedChannelDTO] = []
        var duplicateSkippedCount = 0

        for candidate in candidates {
            let cid = candidate.dto.channelId
            if existingIds.contains(cid) || seenInBatch.contains(cid) {
                duplicateSkippedCount += 1
                continue
            }
            seenInBatch.insert(cid)
            toInsert.append(candidate.dto)
        }

        if !toInsert.isEmpty {
            try await persistence.upsertSubscriptions(toInsert)
        }

        return SubscriptionImportResult(
            importedCount: toInsert.count,
            duplicateSkippedCount: duplicateSkippedCount,
            failedRows: initialFailures
        )
    }

    private func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
        return nil
    }

    private func isHeaderRow(_ row: [String]) -> Bool {
        let joined = row.joined(separator: " ").lowercased()
        return joined.contains("channel id")
            || joined.contains("channel url")
            || joined.contains("channel title")
            || joined.contains("채널 id")
            || joined.contains("채널 url")
            || joined.contains("채널 제목")
    }

    /// RFC 4180 state machine supporting quoted commas, `""` escapes, and CRLF/LF newlines.
    private func parseRFC4180CSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false

        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]

            if inQuotes {
                if ch == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex && text[next] == "\"" {
                        currentField.append("\"")
                        index = text.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(ch)
                }
            } else {
                if ch == "\"" && currentField.isEmpty {
                    inQuotes = true
                } else if ch == "," {
                    currentRow.append(currentField)
                    currentField = ""
                } else if ch == "\r" {
                    let next = text.index(after: index)
                    if next < text.endIndex && text[next] == "\n" {
                        index = next
                    }
                    currentRow.append(currentField)
                    rows.append(currentRow)
                    currentRow = []
                    currentField = ""
                } else if ch == "\n" {
                    currentRow.append(currentField)
                    rows.append(currentRow)
                    currentRow = []
                    currentField = ""
                } else {
                    currentField.append(ch)
                }
            }

            index = text.index(after: index)
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            rows.append(currentRow)
        }

        return rows
    }

    nonisolated static func extractChannelID(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Direct UC... 24-char channel ID match.
        if let range = trimmed.range(of: #"UC[A-Za-z0-9_-]{22}"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        return nil
    }
}

private nonisolated final class OPMLParserHelper: NSObject, XMLParserDelegate {
    private var candidates: [(line: Int, dto: SubscribedChannelDTO)] = []
    private var failures: [SubscriptionImportRowError] = []
    private var outlineCounter = 0

    func parse(data: Data) -> (candidates: [(line: Int, dto: SubscribedChannelDTO)], failures: [SubscriptionImportRowError]) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        if let error = parser.parserError, candidates.isEmpty {
            failures.append(
                SubscriptionImportRowError(
                    lineOrElementIndex: parser.lineNumber,
                    rawValue: "XML",
                    reason: error.localizedDescription
                )
            )
        }
        return (candidates, failures)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.lowercased() == "outline" else { return }
        // Ignore pure folder outlines that lack any feed/URL attributes.
        let xmlUrl = attributeDict["xmlUrl"] ?? attributeDict["xmlurl"]
        let htmlUrl = attributeDict["htmlUrl"] ?? attributeDict["htmlurl"]
        guard xmlUrl != nil || htmlUrl != nil else { return }

        outlineCounter += 1
        let extractedId = SubscriptionImporter.extractChannelID(from: xmlUrl)
            ?? SubscriptionImporter.extractChannelID(from: htmlUrl)

        guard let channelId = extractedId else {
            failures.append(
                SubscriptionImportRowError(
                    lineOrElementIndex: outlineCounter,
                    rawValue: xmlUrl ?? htmlUrl ?? "",
                    reason: "OPML outline에서 channel_id(UC...)를 추출할 수 없습니다."
                )
            )
            return
        }

        let rawTitle = attributeDict["title"] ?? attributeDict["text"] ?? ""
        let cleanTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let dto = SubscribedChannelDTO(
            channelId: channelId,
            name: cleanTitle.isEmpty ? channelId : cleanTitle,
            avatarURLString: nil,
            addedAt: .now,
            lastSyncedAt: nil,
            etag: nil
        )
        candidates.append((outlineCounter, dto))
    }
}
