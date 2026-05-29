import Foundation
import Darwin
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
            let command = try PEnvSetCommand.parse(args)
            let value = try readSecretValue(for: command)
            try await service.setVariable(vaultID: command.vaultID, key: command.key, value: value, scope: command.scope)
            print("stored \(command.key)")
        case "remove":
            guard args.count >= 2 else { throw PersonalEnvError.invalidRequest("Usage: penv remove <vault-id> <KEY>") }
            let vaultID = try parseUUID(args[0])
            let key = args[1]
            let state = await service.snapshot()
            guard let vault = state.vaults.first(where: { $0.id == vaultID }) else {
                throw PersonalEnvError.vaultNotFound
            }
            guard let variable = vault.variables.first(where: { $0.key == key }) else {
                throw PersonalEnvError.variableNotFound(key)
            }
            try await service.deleteVariable(vaultID: vaultID, variableID: variable.id)
            print("removed \(key)")
        case "import":
            guard args.count >= 2 else { throw PersonalEnvError.invalidRequest("Usage: penv import <vault-id> <dotenv-path>") }
            let vaultID = try parseUUID(args[0])
            let path = args[1]
            let text = try String(contentsOfFile: path, encoding: .utf8)
            try await service.importDotenv(text, vaultID: vaultID)
            print("imported")
        case "scan":
            guard let path = args.first else { throw PersonalEnvError.invalidRequest("Usage: penv scan <workspace-path>") }
            let files = try DotenvCodec.scanApprovedDirectory(inDirectory: path)
            guard !files.isEmpty else {
                print("no dotenv files found")
                return
            }
            try await service.importDetectedDotenvFiles(files)
            print("imported \(files.flatMap(\.variables).count) variables from \(files.count) files")
        case "export":
            let command = try PEnvExportCommand.parse(args)
            switch command.destination {
            case .file(let path):
                let receipt = try await service.exportDotenv(vaultID: command.vaultID, toFile: path, keys: command.keys.isEmpty ? nil : command.keys, requester: command.requester)
                print(receipt.description)
            case .stdout:
                print(try await service.exportDotenv(vaultID: command.vaultID, keys: command.keys.isEmpty ? nil : command.keys, destination: .stdout, requester: command.requester), terminator: "")
            }
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
            try await approve(args, service: service)
        case "approvals":
            try listApprovals()
        case "revoke":
            try KeychainAuthorizationGrantStore().revokeAllGrants()
            try await service.recordAuditEvent(AuditEvent(type: .revoke, summary: "Revoked CLI approvals"))
            print("revoked approvals")
        default:
            printHelp()
        }
    }

    private static func approve(_ args: [String], service: VaultService) async throws {
        let request = try parseApprovalRequest(args)
        try await LocalAuthenticator(grantStore: nil).unlock(
            reason: "Approve Personal Env CLI \(request.subject.capability.rawValue) access for \(formatDuration(request.ttl)).",
            subject: request.subject
        )
        let grant = try KeychainAuthorizationGrantStore().approve(request)
        try await service.recordAuditEvent(AuditEvent(
            type: .approval,
            summary: "Approved \(describe(grant.subject))",
            details: approvalAuditDetails(grant.subject)
        ))
        print("approved \(describe(grant.subject)) until \(iso8601(grant.expiresAt))")
    }

    private static func listApprovals() throws {
        let grants = try KeychainAuthorizationGrantStore().validGrants()
        guard !grants.isEmpty else {
            print("no active approvals")
            return
        }
        for grant in grants.sorted(by: { $0.expiresAt < $1.expiresAt }) {
            print("\(describe(grant.subject))  expires \(iso8601(grant.expiresAt))")
        }
    }

    private static func readSecretValue(for command: PEnvSetCommand) throws -> String {
        switch command.input {
        case .stdin:
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard var value = String(data: data, encoding: .utf8) else {
                throw PersonalEnvError.invalidRequest("Secret input must be UTF-8.")
            }
            while value.last == "\n" || value.last == "\r" {
                value.removeLast()
            }
            return value
        case .prompt:
            return try readHiddenLine(prompt: "Secret value for \(command.key): ")
        case .editor:
            return try readSecretFromEditor(key: command.key)
        }
    }

    private static func readSecretFromEditor(key: String) throws -> String {
        let editor = ProcessInfo.processInfo.environment["VISUAL"] ?? ProcessInfo.processInfo.environment["EDITOR"]
        guard let editor, !editor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersonalEnvError.invalidRequest("Set VISUAL or EDITOR before using --editor.")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("personal-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(key).secret")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", "exec $EDITOR_COMMAND \"$SECRET_FILE\""]
        var environment = ProcessInfo.processInfo.environment
        environment["EDITOR_COMMAND"] = editor
        environment["SECRET_FILE"] = fileURL.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PersonalEnvError.invalidRequest("Editor exited with status \(process.terminationStatus).")
        }

        var value = try String(contentsOf: fileURL, encoding: .utf8)
        while value.last == "\n" || value.last == "\r" {
            value.removeLast()
        }
        guard !value.isEmpty else {
            throw PersonalEnvError.invalidRequest("No secret value was provided.")
        }
        return value
    }

    private static func readHiddenLine(prompt: String) throws -> String {
        FileHandle.standardError.write(Data(prompt.utf8))
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw PersonalEnvError.invalidRequest("Unable to configure hidden terminal input.")
        }
        var hidden = original
        hidden.c_lflag &= ~UInt(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &hidden) == 0 else {
            throw PersonalEnvError.invalidRequest("Unable to disable terminal echo.")
        }
        defer {
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        guard let value = readLine(strippingNewline: true) else {
            throw PersonalEnvError.invalidRequest("No secret value was provided.")
        }
        return value
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

    private static func parseApprovalRequest(_ args: [String]) throws -> ApprovalRequest {
        guard let capabilityText = args.first, let capability = ApprovalCapability(cliValue: capabilityText) else {
            throw PersonalEnvError.invalidRequest("Usage: penv approve <read|write> [--ttl 15m] [--vault <vault-id>] [--keys KEY1,KEY2] [--to-file <path>|--stdout|--clipboard|--app] [--requester <name>] [--command <name>]")
        }

        var ttl: TimeInterval = 15 * 60
        var vaultID: UUID?
        var keys: [String]?
        var destination: ApprovalDestination?
        var requester: String?
        var command: String?
        var index = 1

        while index < args.count {
            switch args[index] {
            case "--ttl":
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw PersonalEnvError.invalidRequest("Missing value for --ttl.")
                }
                ttl = try parseDuration(args[valueIndex])
                index += 2
            case "--vault":
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw PersonalEnvError.invalidRequest("Missing value for --vault.")
                }
                vaultID = try parseUUID(args[valueIndex])
                index += 2
            case "--keys":
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw PersonalEnvError.invalidRequest("Missing value for --keys.")
                }
                keys = args[valueIndex]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                index += 2
            case "--to-file":
                guard destination == nil else {
                    throw PersonalEnvError.invalidRequest("Choose one approval destination.")
                }
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw PersonalEnvError.invalidRequest("Missing value for --to-file.")
                }
                destination = .file(NSString(string: args[valueIndex]).expandingTildeInPath)
                index += 2
            case "--stdout":
                guard destination == nil else {
                    throw PersonalEnvError.invalidRequest("Choose one approval destination.")
                }
                destination = .stdout
                index += 1
            case "--clipboard":
                guard destination == nil else {
                    throw PersonalEnvError.invalidRequest("Choose one approval destination.")
                }
                destination = .clipboard
                index += 1
            case "--app":
                guard destination == nil else {
                    throw PersonalEnvError.invalidRequest("Choose one approval destination.")
                }
                destination = .app
                index += 1
            case "--requester":
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw PersonalEnvError.invalidRequest("Missing value for --requester.")
                }
                requester = args[valueIndex]
                index += 2
            case "--command":
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw PersonalEnvError.invalidRequest("Missing value for --command.")
                }
                command = args[valueIndex]
                index += 2
            default:
                throw PersonalEnvError.invalidRequest("Unknown approval option: \(args[index])")
            }
        }

        return ApprovalRequest(
            subject: ApprovalSubject(
                capability: capability,
                vaultID: vaultID,
                keySet: keys,
                destination: destination,
                requester: requester,
                command: command
            ),
            ttl: ttl
        )
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
          penv set <vault-id> <KEY> (--stdin|--prompt|--editor) [--scope <scope>]
          penv remove <vault-id> <KEY>
          penv import <vault-id> <dotenv-path>
          penv scan <workspace-path>
          penv export <vault-id> --to-file <path> [--requester <name>] [KEY...]
          penv export <vault-id> --stdout --allow-secret-stdout [--requester <name>] [KEY...]
          penv list
          penv approve <read|write> [--ttl 15m] [--vault <vault-id>] [--keys KEY1,KEY2] [--to-file <path>|--stdout|--clipboard|--app] [--requester <name>] [--command <name>]
          penv approvals
          penv revoke
        """)
    }

    private static func describe(_ subject: ApprovalSubject) -> String {
        var parts = [subject.capability.rawValue]
        if let vaultID = subject.vaultID {
            parts.append("vault=\(vaultID.uuidString)")
        }
        if let keySet = subject.keySet, !keySet.isEmpty {
            parts.append("keys=\(keySet.joined(separator: ","))")
        }
        if let destination = subject.destination {
            parts.append("destination=\(describe(destination))")
        }
        if let requester = subject.requester {
            parts.append("requester=\(requester)")
        }
        if let command = subject.command {
            parts.append("command=\(command)")
        }
        return parts.joined(separator: "  ")
    }

    private static func describe(_ destination: ApprovalDestination) -> String {
        switch destination {
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

    private static func approvalAuditDetails(_ subject: ApprovalSubject) -> [String: String] {
        var details = [
            "capability": subject.capability.rawValue
        ]
        if let vaultID = subject.vaultID {
            details["vaultID"] = vaultID.uuidString
        }
        if let keySet = subject.keySet {
            details["keys"] = keySet.joined(separator: ", ")
        }
        if let destination = subject.destination {
            details["destination"] = describe(destination)
        }
        if let requester = subject.requester {
            details["requester"] = requester
        }
        if let command = subject.command {
            details["command"] = command
        }
        return details
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
