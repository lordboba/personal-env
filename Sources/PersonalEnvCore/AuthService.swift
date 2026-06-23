import Foundation
import LocalAuthentication

public enum ApprovalCapability: String, Codable, CaseIterable, Sendable {
    case readSecrets = "read"
    case writeSecrets = "write"
}

public enum ApprovalDestination: Codable, Equatable, Sendable {
    case file(String)
    case stdout
    case clipboard
    case app

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case file
        case stdout
        case clipboard
        case app
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .file:
            self = .file(try container.decode(String.self, forKey: .value))
        case .stdout:
            self = .stdout
        case .clipboard:
            self = .clipboard
        case .app:
            self = .app
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .file(let path):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(path, forKey: .value)
        case .stdout:
            try container.encode(Kind.stdout, forKey: .kind)
        case .clipboard:
            try container.encode(Kind.clipboard, forKey: .kind)
        case .app:
            try container.encode(Kind.app, forKey: .kind)
        }
    }
}

public enum SecurePath {
    public static func canonicalFilePath(_ path: String) throws -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw PersonalEnvError.invalidRequest("File path is required.")
        }
        let expandedPath = NSString(string: trimmedPath).expandingTildeInPath
        let inputURL = URL(fileURLWithPath: expandedPath)
        guard inputURL.isFileURL else {
            throw PersonalEnvError.invalidRequest("Only local file paths are supported.")
        }

        let absoluteURL = inputURL.absoluteURL
        let parentURL = absoluteURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PersonalEnvError.invalidRequest("The file target parent folder does not exist.")
        }

        let parentValues = try parentURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw PersonalEnvError.invalidRequest("The file target parent folder must be a real directory.")
        }

        let canonicalParent = parentURL.resolvingSymlinksInPath().standardizedFileURL
        return canonicalParent.appendingPathComponent(absoluteURL.lastPathComponent, isDirectory: false).path
    }

    public static func validateExistingRegularFileTarget(at path: String, description: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return
        }

        let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, !isDirectory.boolValue else {
            throw PersonalEnvError.invalidRequest("\(description) must be a regular file.")
        }
    }

    public static func canonicalDirectoryPath(_ path: String) throws -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw PersonalEnvError.invalidRequest("Directory path is required.")
        }
        let expandedPath = NSString(string: trimmedPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath, isDirectory: true).absoluteURL
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw PersonalEnvError.invalidRequest("The directory must be a real directory.")
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

public struct RequesterIdentity: Codable, Equatable, Sendable, CustomStringConvertible {
    public var value: String

    public var description: String {
        value
    }

    public init(value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public static func bind(_ requester: String?) -> RequesterIdentity? {
        guard let requester = requester?.trimmingCharacters(in: .whitespacesAndNewlines), !requester.isEmpty else {
            return nil
        }
        let executablePath = CommandLine.arguments.first ?? ProcessInfo.processInfo.processName
        let canonicalExecutable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardizedFileURL.path
        return RequesterIdentity(value: "\(requester)@\(canonicalExecutable)")
    }
}

public struct ApprovalSubjectRequest: Equatable, Sendable {
    public var capability: ApprovalCapability
    public var vaultID: UUID?
    public var keySet: [String]?
    public var destination: ApprovalDestination?
    public var requester: String?
    public var command: String?

    public init(
        capability: ApprovalCapability,
        vaultID: UUID? = nil,
        keySet: [String]? = nil,
        destination: ApprovalDestination? = nil,
        requester: String? = nil,
        command: String? = nil
    ) {
        self.capability = capability
        self.vaultID = vaultID
        self.keySet = keySet
        self.destination = destination
        self.requester = requester
        self.command = command
    }
}

public struct ApprovalSubject: Codable, Equatable, Sendable {
    public var capability: ApprovalCapability
    public var vaultID: UUID?
    public var keySet: [String]?
    public var destination: ApprovalDestination?
    public var requester: RequesterIdentity?
    public var command: String?

    public init(
        capability: ApprovalCapability,
        vaultID: UUID? = nil,
        keySet: [String]? = nil,
        destination: ApprovalDestination? = nil,
        requester: RequesterIdentity? = nil,
        command: String? = nil
    ) {
        self.capability = capability
        self.vaultID = vaultID
        self.keySet = keySet.map { Array(Set($0)).sorted() }
        self.destination = destination
        self.requester = requester
        self.command = command?.nilIfBlank
    }

    public init(request: ApprovalSubjectRequest) {
        self.init(
            capability: request.capability,
            vaultID: request.vaultID,
            keySet: request.keySet,
            destination: request.destination,
            requester: RequesterIdentity.bind(request.requester),
            command: request.command
        )
    }

    public var isScoped: Bool {
        vaultID != nil || keySet != nil || destination != nil || requester != nil || command != nil
    }

    fileprivate func authorizes(_ requested: ApprovalSubject) -> Bool {
        self == requested
    }
}

public struct ApprovalRequest: Codable, Equatable, Sendable {
    public var subject: ApprovalSubject
    public var ttl: TimeInterval

    public init(subject: ApprovalSubject, ttl: TimeInterval) {
        self.subject = subject
        self.ttl = ttl
    }
}

public struct AuthorizationGrant: Identifiable, Codable, Equatable, Sendable {
    public var subject: ApprovalSubject
    public var approvedAt: Date
    public var expiresAt: Date

    public var id: String {
        [
            subject.capability.rawValue,
            subject.vaultID?.uuidString ?? "*",
            subject.keySet?.joined(separator: ",") ?? "*",
            subject.destination?.identityText ?? "*",
            subject.requester?.value ?? "*",
            subject.command ?? "*",
            String(expiresAt.timeIntervalSince1970)
        ].joined(separator: "::")
    }

    public var capability: ApprovalCapability {
        subject.capability
    }

    public init(capability: ApprovalCapability, approvedAt: Date = Date(), expiresAt: Date) {
        self.subject = ApprovalSubject(capability: capability)
        self.approvedAt = approvedAt
        self.expiresAt = expiresAt
    }

    public init(subject: ApprovalSubject, approvedAt: Date = Date(), expiresAt: Date) {
        self.subject = subject
        self.approvedAt = approvedAt
        self.expiresAt = expiresAt
    }

    public func isValid(at date: Date = Date()) -> Bool {
        expiresAt > date
    }
}

public protocol AuthorizationGrantStoring: Sendable {
    func loadGrants() throws -> [AuthorizationGrant]
    func saveGrants(_ grants: [AuthorizationGrant]) throws
}

public protocol Authenticating: Sendable {
    func unlock(reason: String, subject: ApprovalSubject) async throws
}

public extension Authenticating {
    func unlock(reason: String, capability: ApprovalCapability) async throws {
        try await unlock(reason: reason, subject: ApprovalSubject(capability: capability))
    }
}

public struct LocalAuthenticator: Authenticating {
    private let grantStore: AuthorizationGrantStoring?
    private let now: @Sendable () -> Date

    public init(grantStore: AuthorizationGrantStoring? = KeychainAuthorizationGrantStore(), now: @escaping @Sendable () -> Date = Date.init) {
        self.grantStore = grantStore
        self.now = now
    }

    public func unlock(reason: String, subject: ApprovalSubject) async throws {
        if let grantStore, try grantStore.hasValidGrant(matching: subject, at: now()) {
            return
        }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else {
            throw PersonalEnvError.authenticationFailed(error?.localizedDescription ?? "No passkey, biometric, or device passcode is available.")
        }
        let success = try await context.evaluatePolicy(policy, localizedReason: reason)
        if !success {
            throw PersonalEnvError.authenticationFailed("Authentication was rejected.")
        }
    }
}

public struct NoopAuthenticator: Authenticating {
    public init() {}
    public func unlock(reason _: String, subject _: ApprovalSubject) async throws {}
}

public extension AuthorizationGrantStoring {
    func validGrants(at date: Date = Date()) throws -> [AuthorizationGrant] {
        try loadGrants().filter { $0.isValid(at: date) }
    }

    func hasValidGrant(for capability: ApprovalCapability, at date: Date = Date()) throws -> Bool {
        try hasValidGrant(matching: ApprovalSubject(capability: capability), at: date)
    }

    func hasValidGrant(matching subject: ApprovalSubject, at date: Date = Date()) throws -> Bool {
        let grants = try validGrants(at: date)
        return grants.contains { $0.subject.authorizes(subject) }
    }

    func approve(_ capability: ApprovalCapability, ttl: TimeInterval, at date: Date = Date()) throws -> AuthorizationGrant {
        try approve(ApprovalRequest(subject: ApprovalSubject(capability: capability), ttl: ttl), at: date)
    }

    func approve(_ request: ApprovalRequest, at date: Date = Date()) throws -> AuthorizationGrant {
        let grant = AuthorizationGrant(subject: request.subject, approvedAt: date, expiresAt: date.addingTimeInterval(request.ttl))
        var grants = try validGrants(at: date).filter { $0.subject != request.subject }
        grants.append(grant)
        try saveGrants(grants)
        return grant
    }

    func revokeAllGrants() throws {
        try saveGrants([])
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension ApprovalDestination {
    var identityText: String {
        switch self {
        case .file(let path):
            return "file:\(path)"
        case .stdout:
            return "stdout"
        case .clipboard:
            return "clipboard"
        case .app:
            return "app"
        }
    }
}
