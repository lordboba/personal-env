import Foundation

public enum PEnvExportDestination: Equatable, Sendable {
    case file(String)
    case stdout
}

public struct PEnvExportCommand: Equatable, Sendable {
    public var vaultID: UUID
    public var destination: PEnvExportDestination
    public var keys: [String]
    public var requester: String?

    public init(vaultID: UUID, destination: PEnvExportDestination, keys: [String] = [], requester: String? = nil) {
        self.vaultID = vaultID
        self.destination = destination
        self.keys = keys
        self.requester = requester
    }

    public static func parse(_ args: [String]) throws -> PEnvExportCommand {
        guard let vaultIDText = args.first, let vaultID = UUID(uuidString: vaultIDText) else {
            throw PersonalEnvError.invalidRequest("Usage: penv export <vault-id> --to-file <path> [KEY...]")
        }

        var destination: PEnvExportDestination?
        var allowsSecretStdout = false
        var requester: String?
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
            case "--requester":
                let requesterIndex = args.index(after: index)
                guard requesterIndex < args.endIndex else {
                    throw PersonalEnvError.invalidRequest("Usage: penv export <vault-id> --to-file <path> [--requester <name>] [KEY...]")
                }
                requester = args[requesterIndex]
                index = args.index(after: requesterIndex)
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

        return PEnvExportCommand(vaultID: vaultID, destination: destination, keys: keys, requester: requester)
    }
}

public enum PEnvSetInput: Equatable, Sendable {
    case stdin
    case prompt
    case editor
}

public struct PEnvSetCommand: Equatable, Sendable {
    public var vaultID: UUID
    public var key: String
    public var input: PEnvSetInput
    public var scope: String

    public init(vaultID: UUID, key: String, input: PEnvSetInput, scope: String = "project") {
        self.vaultID = vaultID
        self.key = key
        self.input = input
        self.scope = scope
    }

    public static func parse(_ args: [String]) throws -> PEnvSetCommand {
        guard args.count >= 2, let vaultID = UUID(uuidString: args[0]) else {
            throw PersonalEnvError.invalidRequest("Usage: penv set <vault-id> <KEY> (--stdin|--prompt|--editor) [--scope <scope>]")
        }

        let key = args[1]
        var input: PEnvSetInput?
        var scope = "project"
        var index = 2

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--stdin":
                guard input == nil else {
                    throw PersonalEnvError.invalidRequest("Choose one secret input mode.")
                }
                input = .stdin
                index += 1
            case "--prompt":
                guard input == nil else {
                    throw PersonalEnvError.invalidRequest("Choose one secret input mode.")
                }
                input = .prompt
                index += 1
            case "--editor":
                guard input == nil else {
                    throw PersonalEnvError.invalidRequest("Choose one secret input mode.")
                }
                input = .editor
                index += 1
            case "--scope":
                let scopeIndex = index + 1
                guard scopeIndex < args.count else {
                    throw PersonalEnvError.invalidRequest("Usage: penv set <vault-id> <KEY> (--stdin|--prompt|--editor) [--scope <scope>]")
                }
                scope = args[scopeIndex]
                index += 2
            default:
                if arg.hasPrefix("--") {
                    throw PersonalEnvError.invalidRequest("Unknown set option: \(arg)")
                }
                throw PersonalEnvError.invalidRequest("Secret values are not accepted as arguments. Use --stdin, --prompt, or --editor.")
            }
        }

        guard let input else {
            throw PersonalEnvError.invalidRequest("Secret input is required. Use --stdin, --prompt, or --editor.")
        }

        return PEnvSetCommand(vaultID: vaultID, key: key, input: input, scope: scope)
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
