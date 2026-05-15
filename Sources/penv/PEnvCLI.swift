import Foundation
import PersonalEnvCore

@main
struct PEnvCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("penv: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printHelp()
            return
        }
        args.removeFirst()

        let service = try VaultService()
        switch command {
        case "vault":
            guard args.count >= 2 else { throw PersonalEnvError.invalidRequest("Usage: penv vault <name> <project-path>") }
            let vault = try await service.upsertVault(name: args[0], projectPath: args[1])
            print(vault.id.uuidString)
        case "set":
            guard args.count >= 4 else { throw PersonalEnvError.invalidRequest("Usage: penv set <vault-id> <KEY> <VALUE> <scope>") }
            let vaultID = try parseUUID(args[0])
            let key = args[1]
            let value = args[2]
            let scope = args[3]
            try await service.setVariable(vaultID: vaultID, key: key, value: value, scope: scope)
            print("stored \(key)")
        case "import":
            guard args.count >= 2 else { throw PersonalEnvError.invalidRequest("Usage: penv import <vault-id> <dotenv-path>") }
            let vaultID = try parseUUID(args[0])
            let path = args[1]
            let text = try String(contentsOfFile: path, encoding: .utf8)
            try await service.importDotenv(text, vaultID: vaultID)
            print("imported")
        case "scan":
            guard let path = args.first else { throw PersonalEnvError.invalidRequest("Usage: penv scan <workspace-path>") }
            let files = try DotenvCodec.scanFilesRecursively(inDirectory: path)
            guard !files.isEmpty else {
                print("no dotenv files found")
                return
            }
            try await service.importDetectedDotenvFiles(files)
            print("imported \(files.flatMap(\.variables).count) variables from \(files.count) files")
        case "export":
            guard let id = args.first else { throw PersonalEnvError.invalidRequest("Usage: penv export <vault-id> [KEY...]") }
            let vaultID = try parseUUID(id)
            let keys = Array(args.dropFirst())
            print(try await service.exportDotenv(vaultID: vaultID, keys: keys.isEmpty ? nil : keys), terminator: "")
        case "list":
            let state = await service.snapshot()
            for vault in state.vaults {
                print("\(vault.id.uuidString)  \(vault.name)  \(vault.projectPath)")
                for variable in vault.variables.sorted(by: { $0.key < $1.key }) {
                    print("  \(variable.key)  [\(variable.scope)]")
                }
            }
            let hints = await service.duplicateHints()
            if !hints.isEmpty {
                print("\nDuplicate hints:")
                for hint in hints {
                    print("  \(hint.key)  \(hint.conflictState.rawValue)  \(hint.projectPaths.count) projects")
                }
            }
        case "approve":
            try await approve(args)
        case "approvals":
            try listApprovals()
        case "revoke":
            try KeychainAuthorizationGrantStore().revokeAllGrants()
            print("revoked approvals")
        default:
            printHelp()
        }
    }

    private static func approve(_ args: [String]) async throws {
        guard let capabilityText = args.first, let capability = ApprovalCapability(cliValue: capabilityText) else {
            throw PersonalEnvError.invalidRequest("Usage: penv approve <read|write> [--ttl 15m]")
        }
        let ttl = try parseTTL(args: Array(args.dropFirst()))
        try await LocalAuthenticator(grantStore: nil).unlock(reason: "Approve Personal Env CLI \(capability.rawValue) access for \(formatDuration(ttl)).", capability: capability)
        let grant = try KeychainAuthorizationGrantStore().approve(capability, ttl: ttl)
        print("approved \(grant.capability.rawValue) until \(iso8601(grant.expiresAt))")
    }

    private static func listApprovals() throws {
        let grants = try KeychainAuthorizationGrantStore().validGrants()
        guard !grants.isEmpty else {
            print("no active approvals")
            return
        }
        for grant in grants.sorted(by: { $0.expiresAt < $1.expiresAt }) {
            print("\(grant.capability.rawValue)  expires \(iso8601(grant.expiresAt))")
        }
    }

    private static func parseUUID(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw PersonalEnvError.invalidRequest("Invalid UUID: \(value)")
        }
        return uuid
    }

    private static func parseTTL(args: [String]) throws -> TimeInterval {
        guard !args.isEmpty else { return 15 * 60 }
        guard args.count == 2, args[0] == "--ttl" else {
            throw PersonalEnvError.invalidRequest("Usage: penv approve <read|write> [--ttl 15m]")
        }
        return try parseDuration(args[1])
    }

    private static func parseDuration(_ value: String) throws -> TimeInterval {
        guard let unit = value.last, let number = Double(value.dropLast()), number > 0 else {
            throw PersonalEnvError.invalidRequest("TTL must look like 30s, 15m, or 1h.")
        }
        switch unit {
        case "s": return number
        case "m": return number * 60
        case "h": return number * 60 * 60
        default: throw PersonalEnvError.invalidRequest("TTL must look like 30s, 15m, or 1h.")
        }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        if duration.truncatingRemainder(dividingBy: 3600) == 0 {
            return "\(Int(duration / 3600))h"
        }
        if duration.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(Int(duration / 60))m"
        }
        return "\(Int(duration))s"
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func printHelp() {
        print("""
        Personal Env CLI

        Commands:
          penv vault <name> <project-path>
          penv set <vault-id> <KEY> <VALUE> <scope>
          penv import <vault-id> <dotenv-path>
          penv scan <workspace-path>
          penv export <vault-id> [KEY...]
          penv list
          penv approve <read|write> [--ttl 15m]
          penv approvals
          penv revoke
        """)
    }
}

private extension ApprovalCapability {
    init?(cliValue: String) {
        switch cliValue {
        case "read": self = .readSecrets
        case "write": self = .writeSecrets
        default: return nil
        }
    }
}
