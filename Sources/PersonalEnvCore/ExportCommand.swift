import Foundation

public enum PEnvExportDestination: Equatable, Sendable {
    case file(String)
    case stdout
}

public struct PEnvExportCommand: Equatable, Sendable {
    public var vaultID: UUID
    public var destination: PEnvExportDestination
    public var keys: [String]

    public init(vaultID: UUID, destination: PEnvExportDestination, keys: [String] = []) {
        self.vaultID = vaultID
        self.destination = destination
        self.keys = keys
    }

    public static func parse(_ args: [String]) throws -> PEnvExportCommand {
        guard let vaultIDText = args.first, let vaultID = UUID(uuidString: vaultIDText) else {
            throw PersonalEnvError.invalidRequest("Usage: penv export <vault-id> --to-file <path> [KEY...]")
        }

        var destination: PEnvExportDestination?
        var allowsSecretStdout = false
        var keys: [String] = []
        var index = args.index(after: args.startIndex)

        while index < args.endIndex {
            let arg = args[index]
            switch arg {
            case "--to-file":
                guard destination == nil else {
                    throw PersonalEnvError.invalidRequest("Choose one export destination.")
                }
                let pathIndex = args.index(after: index)
                guard pathIndex < args.endIndex else {
                    throw PersonalEnvError.invalidRequest("Usage: penv export <vault-id> --to-file <path> [KEY...]")
                }
                destination = .file(args[pathIndex])
                index = args.index(after: pathIndex)
            case "--stdout":
                guard destination == nil else {
                    throw PersonalEnvError.invalidRequest("Choose one export destination.")
                }
                destination = .stdout
                index = args.index(after: index)
            case "--allow-secret-stdout":
                allowsSecretStdout = true
                index = args.index(after: index)
            default:
                guard !arg.hasPrefix("--") else {
                    throw PersonalEnvError.invalidRequest("Unknown export option: \(arg)")
                }
                keys.append(arg)
                index = args.index(after: index)
            }
        }

        guard let destination else {
            throw PersonalEnvError.invalidRequest("Secret stdout export is disabled by default. Use penv export <vault-id> --to-file <path> [KEY...].")
        }
        if destination == .stdout, !allowsSecretStdout {
            throw PersonalEnvError.invalidRequest("Secret stdout export requires --allow-secret-stdout.")
        }
        if destination != .stdout, allowsSecretStdout {
            throw PersonalEnvError.invalidRequest("--allow-secret-stdout is only valid with --stdout.")
        }

        return PEnvExportCommand(vaultID: vaultID, destination: destination, keys: keys)
    }
}

public struct DotenvFileExportReceipt: Equatable, CustomStringConvertible, Sendable {
    public var vaultID: UUID
    public var vaultName: String
    public var targetPath: String
    public var keys: [String]

    public var variableCount: Int {
        keys.count
    }

    public var description: String {
        let keySummary = keys.isEmpty ? "none" : keys.joined(separator: ", ")
        return "exported \(variableCount) variables from \(vaultName) (\(vaultID.uuidString)) to \(targetPath): \(keySummary)"
    }

    public init(vaultID: UUID, vaultName: String, targetPath: String, keys: [String]) {
        self.vaultID = vaultID
        self.vaultName = vaultName
        self.targetPath = targetPath
        self.keys = keys
    }
}
