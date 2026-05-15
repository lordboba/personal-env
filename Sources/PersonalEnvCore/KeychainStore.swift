import Foundation
import Security

public protocol SecretStoring: Sendable {
    func loadState() throws -> AppState
    func saveState(_ state: AppState) throws
    func loadMetadata() throws -> AppState
    func saveMetadata(_ state: AppState) throws
}

public extension SecretStoring {
    func loadMetadata() throws -> AppState {
        try loadState().redactedForMetadata()
    }

    func saveMetadata(_ state: AppState) throws {}
}

public final class KeychainStore: SecretStoring, @unchecked Sendable {
    private let service: String
    private let account: String
    private let metadataURL: URL
    private let itemLabel = "Personal Env Secret Vault"
    private let operationPrompt = "Access the Personal Env secret vault."
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = "com.tylerxiao.personal-env", account: String = "vault-state", metadataURL: URL? = nil) {
        self.service = service
        self.account = account
        self.metadataURL = metadataURL ?? Self.defaultMetadataURL()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func loadState() throws -> AppState {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseOperationPrompt as String] = operationPrompt

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
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: itemLabel,
            kSecAttrDescription as String: operationPrompt
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            try saveMetadata(state)
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw PersonalEnvError.keychain(secMessage(updateStatus))
        }

        var addQuery = baseQuery(account: account)
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PersonalEnvError.keychain(secMessage(addStatus))
        }
        try saveMetadata(state)
    }

    public func loadMetadata() throws -> AppState {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return AppState()
        }
        let data = try Data(contentsOf: metadataURL)
        let decoded = try decoder.decode(AppState.self, from: data)
        let sanitized = decoded.redactedForMetadata()
        if sanitized != decoded {
            try saveMetadata(sanitized)
        }
        return sanitized
    }

    public func saveMetadata(_ state: AppState) throws {
        let data = try encoder.encode(state.redactedForMetadata())
        try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: metadataURL, options: [.atomic])
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func secMessage(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }

    private static func defaultMetadataURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL
            .appendingPathComponent("com.tylerxiao.personal-env", isDirectory: true)
            .appendingPathComponent("vault-metadata.json")
    }
}

public final class KeychainAuthorizationGrantStore: AuthorizationGrantStoring, @unchecked Sendable {
    private let service: String
    private let account: String
    private let itemLabel = "Personal Env CLI Approval Grants"
    private let operationPrompt = "Check Personal Env CLI approval grants."
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = "com.tylerxiao.personal-env", account: String = "authorization-grants") {
        self.service = service
        self.account = account
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func loadGrants() throws -> [AuthorizationGrant] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseOperationPrompt as String] = operationPrompt

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw PersonalEnvError.keychain(secMessage(status))
        }
        return try decoder.decode([AuthorizationGrant].self, from: data)
    }

    public func saveGrants(_ grants: [AuthorizationGrant]) throws {
        let data = try encoder.encode(grants)
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: itemLabel,
            kSecAttrDescription as String: operationPrompt
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

public final class FileAuthorizationGrantStore: AuthorizationGrantStoring, @unchecked Sendable {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func loadGrants() throws -> [AuthorizationGrant] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        return try decoder.decode([AuthorizationGrant].self, from: Data(contentsOf: url))
    }

    public func saveGrants(_ grants: [AuthorizationGrant]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(grants).write(to: url, options: [.atomic])
    }
}
