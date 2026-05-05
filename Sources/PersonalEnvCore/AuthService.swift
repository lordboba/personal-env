import Foundation
import LocalAuthentication

public protocol Authenticating: Sendable {
    func unlock(reason: String) async throws
}

public struct LocalAuthenticator: Authenticating {
    public init() {}

    public func unlock(reason: String) async throws {
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
    public func unlock(reason _: String) async throws {}
}
