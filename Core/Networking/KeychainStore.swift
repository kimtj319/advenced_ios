import Foundation
import os
import Security

protocol KeychainStoreProtocol: Sendable {
    func loadAPIKey() -> String?
    func saveAPIKey(_ key: String) throws
    func deleteAPIKey() throws
    func changeStream() -> AsyncStream<Void>
}

enum KeychainStoreError: Error, LocalizedError, Sendable {
    case encodingFailed
    case securityError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "API 키를 인코딩할 수 없습니다."
        case .securityError(let status):
            return "Keychain 오류가 발생했습니다 (OSStatus: \(status))."
        }
    }
}

/// Resigning-compatible Keychain store omitting Keychain Access Group so free-ID sideloading works.
final class KeychainStore: KeychainStoreProtocol, @unchecked Sendable {
    private let service: String
    private let account: String
    private let lock = OSAllocatedUnfairLock<[UUID: AsyncStream<Void>.Continuation]>(initialState: [:])

    init(
        service: String = Bundle.main.bundleIdentifier ?? "com.personal.ytadvanced.app",
        account: String = "youtube_data_api_v3_key"
    ) {
        self.service = service
        self.account = account
    }

    func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteAPIKey()
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainStoreError.encodingFailed
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let existingStatus = SecItemCopyMatching(baseQuery as CFDictionary, nil)
        let status: OSStatus
        if existingStatus == errSecSuccess {
            status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        } else {
            var addQuery = baseQuery
            for (k, v) in attributes { addQuery[k] = v }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw KeychainStoreError.securityError(status)
        }
        notifyChange()
    }

    func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.securityError(status)
        }
        notifyChange()
    }

    func changeStream() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            lock.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = $0.removeValue(forKey: id) }
            }
        }
    }

    private func notifyChange() {
        let continuations = lock.withLock { Array($0.values) }
        for continuation in continuations {
            continuation.yield(())
        }
    }
}

/// Thread-safe in-memory keychain implementation for unit tests.
final class InMemoryKeychainStore: KeychainStoreProtocol, @unchecked Sendable {
    private struct State {
        var apiKey: String?
        var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(initialAPIKey: String? = nil) {
        self.lock = OSAllocatedUnfairLock(initialState: State(apiKey: initialAPIKey))
    }

    func loadAPIKey() -> String? {
        lock.withLock { $0.apiKey }
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let continuations = lock.withLock { state -> [AsyncStream<Void>.Continuation] in
            state.apiKey = trimmed.isEmpty ? nil : trimmed
            return Array(state.continuations.values)
        }
        continuations.forEach { $0.yield(()) }
    }

    func deleteAPIKey() throws {
        let continuations = lock.withLock { state -> [AsyncStream<Void>.Continuation] in
            state.apiKey = nil
            return Array(state.continuations.values)
        }
        continuations.forEach { $0.yield(()) }
    }

    func changeStream() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            lock.withLock { $0.continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = $0.continuations.removeValue(forKey: id) }
            }
        }
    }
}
