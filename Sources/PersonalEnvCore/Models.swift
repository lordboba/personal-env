import Foundation

public struct EnvVariable: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var key: String
    public var value: String
    public var scope: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), key: String, value: String, scope: String = "project", updatedAt: Date = Date()) {
        self.id = id
        self.key = key
        self.value = value
        self.scope = scope
        self.updatedAt = updatedAt
    }
}

public struct SecretRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var key: String
    public var value: String
    public var scope: String
    public var valueFingerprint: String
    public var source: String?
    public var updatedAt: Date

    public init(id: UUID = UUID(), key: String, value: String, scope: String = "project", valueFingerprint: String, source: String? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.key = key
        self.value = value
        self.scope = scope
        self.valueFingerprint = valueFingerprint
        self.source = source
        self.updatedAt = updatedAt
    }
}

public struct ProjectSecretUse: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var projectPath: String
    public var dotenvFileName: String
    public var key: String
    public var secretID: UUID?
    public var importedAt: Date
    public var lastSeenAt: Date

    public init(id: UUID = UUID(), projectPath: String, dotenvFileName: String, key: String, secretID: UUID? = nil, importedAt: Date = Date(), lastSeenAt: Date = Date()) {
        self.id = id
        self.projectPath = projectPath
        self.dotenvFileName = dotenvFileName
        self.key = key
        self.secretID = secretID
        self.importedAt = importedAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct DuplicateHint: Identifiable, Equatable, Sendable {
    public enum ConflictState: String, Equatable, Sendable {
        case sameValue
        case conflictingValues
    }

    public var id: String { "\(key)::\(conflictState.rawValue)" }
    public var key: String
    public var projectPaths: [String]
    public var fingerprintMatch: Bool
    public var conflictState: ConflictState

    public init(key: String, projectPaths: [String], fingerprintMatch: Bool, conflictState: ConflictState) {
        self.key = key
        self.projectPaths = projectPaths
        self.fingerprintMatch = fingerprintMatch
        self.conflictState = conflictState
    }
}

public struct EnvVault: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var projectPath: String
    public var dotenvFileName: String?
    public var variables: [EnvVariable]
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, projectPath: String, dotenvFileName: String? = nil, variables: [EnvVariable] = [], updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.projectPath = projectPath
        self.dotenvFileName = dotenvFileName
        self.variables = variables
        self.updatedAt = updatedAt
    }
}

public struct AuditEvent: Identifiable, Codable, Equatable, Sendable {
    public enum EventType: String, Codable, Equatable, Sendable {
        case importSecrets = "import"
        case exportSecrets = "export"
        case scan
        case approval
        case revoke
        case failedAuth = "failed_auth"
        case vaultCreated = "vault_created"
        case vaultRenamed = "vault_renamed"
        case vaultDeleted = "vault_deleted"
        case secretUpdated = "secret_updated"
        case secretDeleted = "secret_deleted"
    }

    public var id: UUID
    public var type: EventType
    public var occurredAt: Date
    public var summary: String
    public var details: [String: String]

    public init(
        id: UUID = UUID(),
        type: EventType,
        occurredAt: Date = Date(),
        summary: String,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.type = type
        self.occurredAt = occurredAt
        self.summary = summary
        self.details = details
    }
}

public struct DetectedDotenvFile: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var fileName: String
    public var path: String
    public var projectPath: String
    public var variables: [EnvVariable]

    public init(fileName: String, path: String, projectPath: String? = nil, variables: [EnvVariable]) {
        self.fileName = fileName
        self.path = path
        self.projectPath = projectPath ?? URL(fileURLWithPath: path).deletingLastPathComponent().path
        self.variables = variables
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public var vaults: [EnvVault]
    public var secrets: [SecretRecord]
    public var projectSecretUses: [ProjectSecretUse]
    public var auditEvents: [AuditEvent]

    public init(
        vaults: [EnvVault] = [],
        secrets: [SecretRecord] = [],
        projectSecretUses: [ProjectSecretUse] = [],
        auditEvents: [AuditEvent] = []
    ) {
        self.vaults = vaults
        self.secrets = secrets
        self.projectSecretUses = projectSecretUses
        self.auditEvents = auditEvents
    }

    private enum CodingKeys: String, CodingKey {
        case vaults
        case secrets
        case projectSecretUses
        case auditEvents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vaults = try container.decodeIfPresent([EnvVault].self, forKey: .vaults) ?? []
        secrets = try container.decodeIfPresent([SecretRecord].self, forKey: .secrets) ?? []
        projectSecretUses = try container.decodeIfPresent([ProjectSecretUse].self, forKey: .projectSecretUses) ?? []
        auditEvents = try container.decodeIfPresent([AuditEvent].self, forKey: .auditEvents) ?? []
    }

    public func redactedForMetadata() -> AppState {
        AppState(
            vaults: vaults.map { vault in
                EnvVault(
                    id: vault.id,
                    name: vault.name,
                    projectPath: vault.projectPath,
                    dotenvFileName: vault.dotenvFileName,
                    variables: vault.variables.map { variable in
                        EnvVariable(
                            id: variable.id,
                            key: variable.key,
                            value: "",
                            scope: variable.scope,
                            updatedAt: variable.updatedAt
                        )
                    },
                    updatedAt: vault.updatedAt
                )
            },
            secrets: [],
            projectSecretUses: projectSecretUses,
            auditEvents: auditEvents
        )
    }
}

public enum PersonalEnvError: Error, LocalizedError, Equatable {
    case vaultNotFound
    case variableNotFound(String)
    case unauthorized
    case invalidRequest(String)
    case keychain(String)
    case authenticationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .vaultNotFound:
            return "Vault not found."
        case .variableNotFound(let key):
            return "Variable not found: \(key)."
        case .unauthorized:
            return "This request is not authorized."
        case .invalidRequest(let message):
            return message
        case .keychain(let message):
            return "Keychain error: \(message)"
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        }
    }
}
