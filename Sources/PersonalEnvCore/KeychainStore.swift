import Foundation
import Security

public protocol SecretStoring: Sendable {
    func loadState() throws -> AppState
    func saveState(_ state: AppState) throws
}

public final class KeychainStore: SecretStoring, @unchecked Sendable {
    private let service: String
    private let account: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = "com.tylerxiao.personal-env", account: String = "vault-state") {
        self.service = service
        self.account = account
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func loadState() throws -> AppState {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return AppState()
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw PersonalEnvError.keychain(secMessage(status))
        }
        return try decoder.decode(AppState.self, from: data)
    }

    public func saveState(_ state: AppState) throws {
        let data = try encoder.encode(state)
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw PersonalEnvError.keychain(secMessage(updateStatus))
        }

        var addQuery = baseQuery()
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PersonalEnvError.keychain(secMessage(addStatus))
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func secMessage(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}

public final class FileStateStore: SecretStoring, @unchecked Sendable {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func loadState() throws -> AppState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppState()
        }
        return try decoder.decode(AppState.self, from: Data(contentsOf: url))
    }

    public func saveState(_ state: AppState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: url, options: [.atomic])
    }
}
