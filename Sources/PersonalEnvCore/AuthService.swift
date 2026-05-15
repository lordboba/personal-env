import Foundation
import LocalAuthentication

public enum ApprovalCapability: String, Codable, CaseIterable, Sendable {
    case readSecrets = "read"
    case writeSecrets = "write"
}

public struct AuthorizationGrant: Codable, Equatable, Sendable {
    public var capability: ApprovalCapability
    public var approvedAt: Date
    public var expiresAt: Date

    public init(capability: ApprovalCapability, approvedAt: Date = Date(), expiresAt: Date) {
        self.capability = capability
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
    func unlock(reason: String, capability: ApprovalCapability) async throws
}

public struct LocalAuthenticator: Authenticating {
    private let grantStore: AuthorizationGrantStoring?
    private let now: @Sendable () -> Date

    public init(grantStore: AuthorizationGrantStoring? = KeychainAuthorizationGrantStore(), now: @escaping @Sendable () -> Date = Date.init) {
        self.grantStore = grantStore
        self.now = now
    }

    public func unlock(reason: String, capability: ApprovalCapability) async throws {
        if let grantStore, try grantStore.hasValidGrant(for: capability, at: now()) {
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
    public func unlock(reason _: String, capability _: ApprovalCapability) async throws {}
}

public extension AuthorizationGrantStoring {
    func validGrants(at date: Date = Date()) throws -> [AuthorizationGrant] {
        try loadGrants().filter { $0.isValid(at: date) }
    }

    func hasValidGrant(for capability: ApprovalCapability, at date: Date = Date()) throws -> Bool {
        let grants = try validGrants(at: date)
        if capability == .readSecrets, grants.contains(where: { $0.capability == .writeSecrets }) {
            return true
        }
        return grants.contains { $0.capability == capability }
    }

    func approve(_ capability: ApprovalCapability, ttl: TimeInterval, at date: Date = Date()) throws -> AuthorizationGrant {
        let grant = AuthorizationGrant(capability: capability, approvedAt: date, expiresAt: date.addingTimeInterval(ttl))
        var grants = try validGrants(at: date).filter { $0.capability != capability }
        grants.append(grant)
        try saveGrants(grants)
        return grant
    }

    func revokeAllGrants() throws {
        try saveGrants([])
    }
}
