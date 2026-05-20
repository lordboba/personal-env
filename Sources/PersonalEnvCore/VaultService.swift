import Foundation
import CryptoKit

public actor VaultService {
    private let store: SecretStoring
    private let authenticator: Authenticating
    private var state: AppState
    private var hasLoadedSecretState = false

    public init(store: SecretStoring = KeychainStore(), authenticator: Authenticating = LocalAuthenticator()) throws {
        self.store = store
        self.authenticator = authenticator
        var loadedState = try store.loadMetadata()
        Self.hydrateLegacyInventoryIfNeeded(&loadedState)
        self.state = loadedState
    }

    public func snapshot() -> AppState {
        state
    }

    public func reload(reason: String = "Reload Personal Env from Apple Keychain.") async throws {
        if !hasLoadedSecretState {
            try await authenticator.unlock(reason: reason, capability: .readSecrets)
        }
        try reloadSecretState()
    }

    public func duplicateHints() -> [DuplicateHint] {
        let usesBySecretID = Dictionary(grouping: state.projectSecretUses.compactMap { use -> (UUID, ProjectSecretUse)? in
            guard let secretID = use.secretID else { return nil }
            return (secretID, use)
        }, by: { $0.0 }).mapValues { pairs in pairs.map(\.1) }

        let retainedSecretIDs = retainedSecretIDs()
        let retainedSecrets = state.secrets.filter { retainedSecretIDs.contains($0.id) }
        let secretsByKey = Dictionary(grouping: retainedSecrets, by: \.key)
        return secretsByKey.compactMap { key, secrets in
            guard secrets.count > 1 else { return nil }
            let fingerprints = Set(secrets.map(\.valueFingerprint))
            let projectPaths = Set(secrets.flatMap { secret in
                usesBySecretID[secret.id]?.map(\.projectPath) ?? []
            }).sorted()
            return DuplicateHint(
                key: key,
                projectPaths: projectPaths,
                fingerprintMatch: fingerprints.count == 1,
                conflictState: fingerprints.count == 1 ? .sameValue : .conflictingValues
            )
        }
        .sorted { lhs, rhs in lhs.key < rhs.key }
    }

    public func unlock(reason: String = "Unlock Personal Env to access your Keychain-backed environment variables.", capability: ApprovalCapability = .readSecrets) async throws {
        try await authenticator.unlock(reason: reason, capability: capability)
        try loadSecretStateIfNeeded()
    }

    @discardableResult
    public func upsertVault(name: String, projectPath: String, dotenvFileName: String? = nil) async throws -> EnvVault {
        try await unlock(reason: "Create or update a Personal Env vault.", capability: .writeSecrets)
        if let index = state.vaults.firstIndex(where: { $0.projectPath == projectPath }) {
            state.vaults[index].name = name
            if let dotenvFileName {
                state.vaults[index].dotenvFileName = dotenvFileName
            }
            state.vaults[index].updatedAt = Date()
            try persist()
            return state.vaults[index]
        }
        let vault = EnvVault(name: name, projectPath: projectPath, dotenvFileName: dotenvFileName)
        state.vaults.append(vault)
        try persist()
        return vault
    }

    @discardableResult
    public func createProjectVault(name: String, parentDirectory: String) async throws -> EnvVault {
        try await unlock(reason: "Create a project and Personal Env vault.", capability: .writeSecrets)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw PersonalEnvError.invalidRequest("Project name is required.")
        }

        let expandedParent = NSString(string: parentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        let parentURL = URL(fileURLWithPath: expandedParent, isDirectory: true)
        let projectURL = parentURL.appendingPathComponent(trimmedName, isDirectory: true)

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory) {
            throw PersonalEnvError.invalidRequest("A folder already exists at \(projectURL.path).")
        }

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try DotenvCodec.render([]).write(to: projectURL.appendingPathComponent(DotenvCodec.projectFileName), atomically: true, encoding: .utf8)

        return try upsertVaultWithoutUnlock(name: trimmedName, projectPath: projectURL.path, dotenvFileName: DotenvCodec.projectFileName)
    }

    @discardableResult
    public func renameVault(vaultID: UUID, name: String) async throws -> EnvVault {
        try await unlock(reason: "Rename a Personal Env vault.", capability: .writeSecrets)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw PersonalEnvError.invalidRequest("Vault name is required.")
        }
        guard let index = state.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw PersonalEnvError.vaultNotFound
        }

        state.vaults[index].name = trimmedName
        state.vaults[index].updatedAt = Date()
        try persist()
        return state.vaults[index]
    }

    public func deleteVault(vaultID: UUID) async throws {
        try await unlock(reason: "Delete a Personal Env vault and its stored variables.", capability: .writeSecrets)
        guard let index = state.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw PersonalEnvError.vaultNotFound
        }

        let vault = state.vaults.remove(at: index)
        let removedSecretIDs = Set(vault.variables.map(\.id))
        state.projectSecretUses.removeAll { use in
            use.projectPath == vault.projectPath
        }
        let remainingReferencedSecretIDs = Set(state.projectSecretUses.compactMap(\.secretID))
        state.secrets.removeAll { secret in
            removedSecretIDs.contains(secret.id) && !remainingReferencedSecretIDs.contains(secret.id)
        }
        try persist()
    }

    public func importDotenv(_ text: String, vaultID: UUID, scope: String = "project") async throws {
        try await unlock(reason: "Import environment variables into Apple Keychain.", capability: .writeSecrets)
        try importVariablesWithoutUnlock(DotenvCodec.parse(text, scope: scope), vaultID: vaultID)
    }

    public func importVariables(_ variables: [EnvVariable], vaultID: UUID) async throws {
        try await unlock(reason: "Import environment variables into Apple Keychain.", capability: .writeSecrets)
        try importVariablesWithoutUnlock(variables, vaultID: vaultID)
    }

    public func importDetectedDotenvFiles(_ files: [DetectedDotenvFile], rootName: String? = nil) async throws {
        try await unlock(reason: "Import environment variables into Apple Keychain.", capability: .writeSecrets)
        for file in files {
            let projectName = rootNameForFile(file, fallback: rootName)
            let vault = try upsertVaultWithoutUnlock(name: projectName, projectPath: file.projectPath, dotenvFileName: file.fileName)
            try importVariablesWithoutUnlock(file.variables, vaultID: vault.id, dotenvFileName: file.fileName, source: file.path)
        }
    }

    private func importVariablesWithoutUnlock(_ variables: [EnvVariable], vaultID: UUID) throws {
        try importVariablesWithoutUnlock(variables, vaultID: vaultID, dotenvFileName: nil, source: nil)
    }

    private func importVariablesWithoutUnlock(_ variables: [EnvVariable], vaultID: UUID, dotenvFileName: String?, source: String?) throws {
        guard let index = state.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw PersonalEnvError.vaultNotFound
        }
        for variable in variables {
            let trackedVariable = variableWithTrackedSecret(variable, vaultIndex: index, dotenvFileName: dotenvFileName, source: source)
            if let existing = state.vaults[index].variables.firstIndex(where: { $0.key == trackedVariable.key }) {
                state.vaults[index].variables[existing] = trackedVariable
            } else {
                state.vaults[index].variables.append(trackedVariable)
            }
        }
        state.vaults[index].updatedAt = Date()
        try persist()
        try patchDotenvFileIfNeeded(vaultIndex: index, upserting: variables)
    }

    public func setVariable(vaultID: UUID, key: String, value: String, scope: String = "project") async throws {
        try await unlock(reason: "Store \(key) in Apple Keychain.", capability: .writeSecrets)
        try Self.validateDotenvKey(key)
        guard let vaultIndex = state.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw PersonalEnvError.vaultNotFound
        }
        let variable = variableWithTrackedSecret(EnvVariable(key: key, value: value, scope: scope), vaultIndex: vaultIndex, dotenvFileName: state.vaults[vaultIndex].dotenvFileName, source: "manual")
        if let variableIndex = state.vaults[vaultIndex].variables.firstIndex(where: { $0.key == key }) {
            state.vaults[vaultIndex].variables[variableIndex] = variable
        } else {
            state.vaults[vaultIndex].variables.append(variable)
        }
        state.vaults[vaultIndex].updatedAt = Date()
        try persist()
        try patchDotenvFileIfNeeded(vaultIndex: vaultIndex, upserting: [variable])
    }

    public func updateVariable(vaultID: UUID, variableID: UUID, key: String, value: String, scope: String = "project") async throws {
        try await unlock(reason: "Update \(key) in Apple Keychain.", capability: .writeSecrets)
        try Self.validateDotenvKey(key)
        guard let vaultIndex = state.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw PersonalEnvError.vaultNotFound
        }
        guard let variableIndex = state.vaults[vaultIndex].variables.firstIndex(where: { $0.id == variableID }) else {
            throw PersonalEnvError.variableNotFound(key)
        }
        let oldKey = state.vaults[vaultIndex].variables[variableIndex].key
        let variable = variableWithTrackedSecret(EnvVariable(id: variableID, key: key, value: value, scope: scope), vaultIndex: vaultIndex, dotenvFileName: state.vaults[vaultIndex].dotenvFileName, source: "manual")
        state.vaults[vaultIndex].variables[variableIndex] = variable
        if oldKey != key {
            removeTrackedUses(vaultIndex: vaultIndex, keys: [oldKey], excludingSecretIDs: [variableID])
        }
        state.vaults[vaultIndex].updatedAt = Date()
        try persist()
        try patchDotenvFileIfNeeded(vaultIndex: vaultIndex, upserting: [variable], removingKeys: oldKey == key ? [] : [oldKey])
    }

    public func deleteVariable(vaultID: UUID, variableID: UUID) async throws {
        try await unlock(reason: "Remove an environment variable from Apple Keychain and its tracked .env file.", capability: .writeSecrets)
        guard let vaultIndex = state.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw PersonalEnvError.vaultNotFound
        }
        guard let variableIndex = state.vaults[vaultIndex].variables.firstIndex(where: { $0.id == variableID }) else {
            throw PersonalEnvError.variableNotFound(variableID.uuidString)
        }
        let variable = state.vaults[vaultIndex].variables.remove(at: variableIndex)
        removeTrackedUses(vaultIndex: vaultIndex, keys: [variable.key], excludingSecretIDs: [])
        state.vaults[vaultIndex].updatedAt = Date()
        try persist()
        try patchDotenvFileIfNeeded(vaultIndex: vaultIndex, removingKeys: [variable.key])
    }

    public func exportDotenv(vaultID: UUID, keys: [String]? = nil) async throws -> String {
        try await unlock(reason: "Export environment variables from Apple Keychain.", capability: .readSecrets)
        guard let vault = state.vaults.first(where: { $0.id == vaultID }) else {
            throw PersonalEnvError.vaultNotFound
        }
        let variables = filter(vault.variables, keys: keys)
        return DotenvCodec.render(variables)
    }

    private func filter(_ variables: [EnvVariable], keys: [String]?) -> [EnvVariable] {
        guard let keys, !keys.isEmpty else { return variables }
        return variables.filter { keys.contains($0.key) }
    }

    private func persist() throws {
        garbageCollectUnreferencedSecrets()
        try store.saveState(state)
    }

    private func garbageCollectUnreferencedSecrets() {
        let retainedSecretIDs = retainedSecretIDs()
        state.secrets.removeAll { secret in
            !retainedSecretIDs.contains(secret.id)
        }
    }

    private func retainedSecretIDs() -> Set<UUID> {
        let liveVariableIDs = Set(state.vaults.flatMap { vault in
            vault.variables.map(\.id)
        })
        let trackedUseSecretIDs = Set(state.projectSecretUses.compactMap(\.secretID))
        return liveVariableIDs.union(trackedUseSecretIDs)
    }

    private func removeTrackedUses(vaultIndex: Int, keys: Set<String>, excludingSecretIDs: Set<UUID>) {
        let vault = state.vaults[vaultIndex]
        state.projectSecretUses.removeAll { use in
            use.projectPath == vault.projectPath &&
                keys.contains(use.key) &&
                !excludingSecretIDs.contains(use.secretID ?? UUID())
        }
    }

    private func loadSecretStateIfNeeded() throws {
        guard !hasLoadedSecretState else { return }
        try reloadSecretState()
    }

    private func reloadSecretState() throws {
        var loadedState = try store.loadState()
        Self.hydrateLegacyInventoryIfNeeded(&loadedState)
        state = loadedState
        hasLoadedSecretState = true
        try store.saveMetadata(loadedState)
    }

    @discardableResult
    private func upsertVaultWithoutUnlock(name: String, projectPath: String, dotenvFileName: String? = nil) throws -> EnvVault {
        if let index = state.vaults.firstIndex(where: { $0.projectPath == projectPath }) {
            state.vaults[index].name = name
            if let dotenvFileName {
                state.vaults[index].dotenvFileName = dotenvFileName
            }
            state.vaults[index].updatedAt = Date()
            try persist()
            return state.vaults[index]
        }
        let vault = EnvVault(name: name, projectPath: projectPath, dotenvFileName: dotenvFileName)
        state.vaults.append(vault)
        try persist()
        return vault
    }

    private static func hydrateLegacyInventoryIfNeeded(_ state: inout AppState) {
        guard state.secrets.isEmpty, state.projectSecretUses.isEmpty else { return }
        for vaultIndex in state.vaults.indices {
            let fileName = state.vaults[vaultIndex].dotenvFileName ?? DotenvCodec.projectFileName
            for variable in state.vaults[vaultIndex].variables {
                let secret = SecretRecord(
                    id: variable.id,
                    key: variable.key,
                    value: variable.value,
                    scope: variable.scope,
                    valueFingerprint: fingerprint(value: variable.value),
                    source: "legacy",
                    updatedAt: variable.updatedAt
                )
                state.secrets.append(secret)
                state.projectSecretUses.append(ProjectSecretUse(
                    projectPath: state.vaults[vaultIndex].projectPath,
                    dotenvFileName: fileName,
                    key: variable.key,
                    secretID: secret.id
                ))
            }
        }
    }

    private func variableWithTrackedSecret(_ variable: EnvVariable, vaultIndex: Int, dotenvFileName: String?, source: String?) -> EnvVariable {
        let fingerprint = Self.fingerprint(value: variable.value)
        let secret = SecretRecord(
            id: variable.id,
            key: variable.key,
            value: variable.value,
            scope: variable.scope,
            valueFingerprint: fingerprint,
            source: source,
            updatedAt: variable.updatedAt
        )
        if let index = state.secrets.firstIndex(where: { $0.id == secret.id }) {
            state.secrets[index] = secret
        } else {
            state.secrets.append(secret)
        }

        let vault = state.vaults[vaultIndex]
        let fileName = dotenvFileName ?? vault.dotenvFileName ?? DotenvCodec.projectFileName
        if let useIndex = state.projectSecretUses.firstIndex(where: {
            $0.projectPath == vault.projectPath && $0.dotenvFileName == fileName && $0.key == variable.key
        }) {
            state.projectSecretUses[useIndex].secretID = secret.id
            state.projectSecretUses[useIndex].lastSeenAt = Date()
        } else {
            state.projectSecretUses.append(ProjectSecretUse(projectPath: vault.projectPath, dotenvFileName: fileName, key: variable.key, secretID: secret.id))
        }
        return variable
    }

    private func rootNameForFile(_ file: DetectedDotenvFile, fallback: String?) -> String {
        let projectName = URL(fileURLWithPath: file.projectPath).lastPathComponent
        if !projectName.isEmpty {
            return projectName
        }
        let fallbackName = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallbackName.isEmpty ? "Imported Project" : fallbackName
    }

    private static func fingerprint(value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateDotenvKey(_ key: String) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey == key, !key.isEmpty else {
            throw PersonalEnvError.invalidRequest("Environment variable keys cannot be empty or padded with whitespace.")
        }
        let allowedScalars = key.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        guard allowedScalars, key.unicodeScalars.first.map({ CharacterSet.letters.contains($0) || $0 == "_" }) == true else {
            throw PersonalEnvError.invalidRequest("Environment variable keys must start with a letter or underscore and contain only letters, numbers, and underscores.")
        }
    }

    private func patchDotenvFileIfNeeded(vaultIndex: Int, upserting variables: [EnvVariable] = [], removingKeys: Set<String> = []) throws {
        let vault = state.vaults[vaultIndex]
        guard let dotenvFileName = vault.dotenvFileName else { return }

        let directoryURL = URL(fileURLWithPath: NSString(string: vault.projectPath).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let dotenvURL = directoryURL.appendingPathComponent(dotenvFileName)
        let existingText = (try? String(contentsOf: dotenvURL, encoding: .utf8)) ?? ""
        let patchedText = DotenvCodec.patch(existingText, upserting: variables, removingKeys: removingKeys)
        try patchedText.write(to: dotenvURL, atomically: true, encoding: .utf8)
    }
}
