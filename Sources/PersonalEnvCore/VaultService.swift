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

    public func recordAuditEvent(_ event: AuditEvent) throws {
        try persistAuditEvent(event)
    }

    public func reload(reason: String = "Reload Personal Env from Apple Keychain.") async throws {
        if !hasLoadedSecretState {
            do {
                try await authenticator.unlock(reason: reason, capability: .readSecrets)
            } catch {
                recordFailedAuthentication(reason: reason, error: error)
                throw error
            }
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
        try await unlock(reason: reason, subject: ApprovalSubject(capability: capability))
    }

    public func unlock(reason: String, subject: ApprovalSubject) async throws {
        do {
            try await authenticator.unlock(reason: reason, subject: subject)
        } catch {
            recordFailedAuthentication(reason: reason, error: error)
            throw error
        }
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
        let parentURL = URL(fileURLWithPath: try SecurePath.canonicalDirectoryPath(expandedParent), isDirectory: true)
        guard trimmedName == URL(fileURLWithPath: trimmedName).lastPathComponent, trimmedName != "." && trimmedName != ".." else {
            throw PersonalEnvError.invalidRequest("Project name must be a single folder name without path separators.")
        }
        let projectURL = parentURL.appendingPathComponent(trimmedName, isDirectory: true)
        guard projectURL.standardizedFileURL.deletingLastPathComponent().path == parentURL.path else {
            throw PersonalEnvError.invalidRequest("Project path must stay inside the selected parent folder.")
        }

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
        let variables = DotenvCodec.parse(text, scope: scope)
        try validateDotenvVariables(variables)
        try importVariablesWithoutUnlock(variables, vaultID: vaultID)
    }

    public func importVariables(_ variables: [EnvVariable], vaultID: UUID) async throws {
        try await unlock(reason: "Import environment variables into Apple Keychain.", capability: .writeSecrets)
        try validateDotenvVariables(variables)
        try importVariablesWithoutUnlock(variables, vaultID: vaultID)
    }

    public func importDetectedDotenvFiles(_ files: [DetectedDotenvFile], rootName: String? = nil) async throws {
        try await unlock(reason: "Import environment variables into Apple Keychain.", capability: .writeSecrets)
        for file in files {
            try validateDotenvVariables(file.variables)
            let projectName = rootNameForFile(file, fallback: rootName)
            let vault = try upsertVaultWithoutUnlock(name: projectName, projectPath: file.projectPath, dotenvFileName: file.fileName)
            try importVariablesWithoutUnlock(file.variables, vaultID: vault.id, dotenvFileName: file.fileName, source: file.path)
        }
        try persistAuditEvent(AuditEvent(
            type: .scan,
            summary: "Imported scan results from \(files.count) dotenv files",
            details: [
                "fileCount": String(files.count),
                "keyCount": String(files.flatMap(\.variables).count)
            ]
        ))
    }

    private func importVariablesWithoutUnlock(_ variables: [EnvVariable], vaultID: UUID) throws {
        try importVariablesWithoutUnlock(variables, vaultID: vaultID, dotenvFileName: nil, source: nil)
    }

    private func importVariablesWithoutUnlock(_ variables: [EnvVariable], vaultID: UUID, dotenvFileName: String?, source: String?) throws {
        guard let index = state.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw PersonalEnvError.vaultNotFound
        }
        let previousState = state
        for variable in variables {
            let trackedVariable = variableWithTrackedSecret(variable, vaultIndex: index, dotenvFileName: dotenvFileName, source: source)
            if let existing = state.vaults[index].variables.firstIndex(where: { $0.key == trackedVariable.key }) {
                state.vaults[index].variables[existing] = trackedVariable
            } else {
                state.vaults[index].variables.append(trackedVariable)
            }
        }
        state.vaults[index].updatedAt = Date()
        let auditEvent = AuditEvent(
            type: .importSecrets,
            summary: "Imported \(variables.count) variables into \(state.vaults[index].name)",
            details: secretAuditDetails(vault: state.vaults[index], keys: variables.map(\.key), source: source)
        )
        try commitStateWithDotenvPatch(vaultIndex: index, upserting: variables, previousState: previousState, auditEvent: auditEvent)
    }

    public func setVariable(vaultID: UUID, key: String, value: String, scope: String = "project") async throws {
        try await unlock(reason: "Store \(key) in Apple Keychain.", capability: .writeSecrets)
        try DotenvKeyValidator.validate(key)
        try SecretValueValidator.validate(value: value, key: key)
        guard let vaultIndex = state.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw PersonalEnvError.vaultNotFound
        }
        let previousState = state
        let variable = variableWithTrackedSecret(EnvVariable(key: key, value: value, scope: scope), vaultIndex: vaultIndex, dotenvFileName: state.vaults[vaultIndex].dotenvFileName, source: "manual")
        if let variableIndex = state.vaults[vaultIndex].variables.firstIndex(where: { $0.key == key }) {
            state.vaults[vaultIndex].variables[variableIndex] = variable
        } else {
            state.vaults[vaultIndex].variables.append(variable)
        }
        state.vaults[vaultIndex].updatedAt = Date()
        let auditEvent = AuditEvent(
            type: .secretUpdated,
            summary: "Stored \(key) in \(state.vaults[vaultIndex].name)",
            details: secretAuditDetails(vault: state.vaults[vaultIndex], keys: [key], source: "manual")
        )
        try commitStateWithDotenvPatch(vaultIndex: vaultIndex, upserting: [variable], previousState: previousState, auditEvent: auditEvent)
    }

    public func updateVariable(vaultID: UUID, variableID: UUID, key: String, value: String, scope: String = "project") async throws {
        try await unlock(reason: "Update \(key) in Apple Keychain.", capability: .writeSecrets)
        try DotenvKeyValidator.validate(key)
        try SecretValueValidator.validate(value: value, key: key)
        guard let vaultIndex = state.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw PersonalEnvError.vaultNotFound
        }
        guard let variableIndex = state.vaults[vaultIndex].variables.firstIndex(where: { $0.id == variableID }) else {
            throw PersonalEnvError.variableNotFound(key)
        }
        if state.vaults[vaultIndex].variables.contains(where: { $0.id != variableID && $0.key == key }) {
            throw PersonalEnvError.invalidRequest("A variable named \(key) already exists in this vault.")
        }
        let previousState = state
        let oldKey = state.vaults[vaultIndex].variables[variableIndex].key
        let variable = variableWithTrackedSecret(EnvVariable(id: variableID, key: key, value: value, scope: scope), vaultIndex: vaultIndex, dotenvFileName: state.vaults[vaultIndex].dotenvFileName, source: "manual")
        state.vaults[vaultIndex].variables[variableIndex] = variable
        if oldKey != key {
            removeTrackedUses(vaultIndex: vaultIndex, keys: [oldKey])
        }
        state.vaults[vaultIndex].updatedAt = Date()
        let auditEvent = AuditEvent(
            type: .secretUpdated,
            summary: "Updated \(key) in \(state.vaults[vaultIndex].name)",
            details: secretAuditDetails(vault: state.vaults[vaultIndex], keys: [key], source: "manual")
        )
        try commitStateWithDotenvPatch(vaultIndex: vaultIndex, upserting: [variable], removingKeys: oldKey == key ? [] : [oldKey], previousState: previousState, auditEvent: auditEvent)
    }

    public func deleteVariable(vaultID: UUID, variableID: UUID) async throws {
        try await unlock(reason: "Remove an environment variable from Apple Keychain and its tracked .env file.", capability: .writeSecrets)
        guard let vaultIndex = state.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw PersonalEnvError.vaultNotFound
        }
        guard let variableIndex = state.vaults[vaultIndex].variables.firstIndex(where: { $0.id == variableID }) else {
            throw PersonalEnvError.variableNotFound(variableID.uuidString)
        }
        let previousState = state
        let variable = state.vaults[vaultIndex].variables.remove(at: variableIndex)
        removeTrackedUses(vaultIndex: vaultIndex, keys: [variable.key])
        state.vaults[vaultIndex].updatedAt = Date()
        let auditEvent = AuditEvent(
            type: .secretDeleted,
            summary: "Removed \(variable.key) from \(state.vaults[vaultIndex].name)",
            details: secretAuditDetails(vault: state.vaults[vaultIndex], keys: [variable.key], source: nil)
        )
        try commitStateWithDotenvPatch(vaultIndex: vaultIndex, removingKeys: [variable.key], previousState: previousState, auditEvent: auditEvent)
    }

    public func exportDotenv(vaultID: UUID, keys: [String]? = nil, destination: ApprovalDestination = .clipboard, requester: String? = nil) async throws -> String {
        let requestedKeys = try requestedKeySet(vaultID: vaultID, keys: keys)
        try await unlock(
            reason: "Export environment variables from Apple Keychain.",
            subject: ApprovalSubject(request: ApprovalSubjectRequest(
                capability: .readSecrets,
                vaultID: vaultID,
                keySet: requestedKeys,
                destination: destination,
                requester: requester,
                command: "export"
            ))
        )
        guard let vault = state.vaults.first(where: { $0.id == vaultID }) else {
            throw PersonalEnvError.vaultNotFound
        }
        let variables = try filter(vault.variables, keys: keys)
        try validateExportableSecretValues(variables)
        try persistAuditEvent(AuditEvent(
            type: .exportSecrets,
            summary: "Exported \(variables.count) variables from \(vault.name)",
            details: secretAuditDetails(vault: vault, keys: variables.map(\.key), source: destination.auditDescription)
        ))
        return DotenvCodec.render(variables)
    }

    public func exportDotenv(vaultID: UUID, toFile path: String, keys: [String]? = nil, requester: String? = nil) async throws -> DotenvFileExportReceipt {
        let expandedPath = try SecurePath.canonicalFilePath(path)
        let requestedKeys = try requestedKeySet(vaultID: vaultID, keys: keys)
        try await unlock(
            reason: "Export environment variables from Apple Keychain to \(expandedPath).",
            subject: ApprovalSubject(request: ApprovalSubjectRequest(
                capability: .readSecrets,
                vaultID: vaultID,
                keySet: requestedKeys,
                destination: .file(expandedPath),
                requester: requester,
                command: "export"
            ))
        )
        guard let vault = state.vaults.first(where: { $0.id == vaultID }) else {
            throw PersonalEnvError.vaultNotFound
        }
        let variables = try filter(vault.variables, keys: keys)
        try validateExportableSecretValues(variables)
        try writeDotenvExport(variables, toFile: expandedPath)
        try persistAuditEvent(AuditEvent(
            type: .exportSecrets,
            summary: "Exported \(variables.count) variables from \(vault.name) to file",
            details: secretAuditDetails(vault: vault, keys: variables.map(\.key), source: expandedPath)
        ))
        return DotenvFileExportReceipt(
            vaultID: vault.id,
            vaultName: vault.name,
            targetPath: expandedPath,
            keys: variables.map(\.key).sorted()
        )
    }

    private func filter(_ variables: [EnvVariable], keys: [String]?) throws -> [EnvVariable] {
        guard let keys, !keys.isEmpty else { return variables }
        let variablesByKey = Dictionary(uniqueKeysWithValues: variables.map { ($0.key, $0) })
        return try keys.map { key in
            guard let variable = variablesByKey[key] else {
                throw PersonalEnvError.variableNotFound(key)
            }
            return variable
        }
    }

    private func requestedKeySet(vaultID: UUID, keys: [String]?) throws -> [String]? {
        guard let keys, !keys.isEmpty else {
            guard let vault = state.vaults.first(where: { $0.id == vaultID }) else {
                throw PersonalEnvError.vaultNotFound
            }
            return vault.variables.map(\.key).sorted()
        }
        return Array(Set(keys)).sorted()
    }

    private func writeDotenvExport(_ variables: [EnvVariable], toFile path: String) throws {
        let expandedPath = try SecurePath.canonicalFilePath(path)
        let url = URL(fileURLWithPath: expandedPath)
        let parentURL = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PersonalEnvError.invalidRequest("The export target parent folder does not exist.")
        }

        let fileExists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        try SecurePath.validateExistingRegularFileTarget(at: url.path, description: "The export target")

        let originalText = fileExists ? try String(contentsOf: url, encoding: .utf8) : ""
        let patchedText = DotenvCodec.patch(originalText, upserting: variables)
        try writeAtomicallyReplacingFile(text: patchedText, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func persist() throws {
        garbageCollectUnreferencedSecrets()
        try store.saveState(state)
    }

    private func persistAuditEvent(_ event: AuditEvent) throws {
        state.auditEvents.append(event)
        if hasLoadedSecretState {
            try persist()
        } else {
            try store.saveMetadata(state)
        }
    }

    private func recordFailedAuthentication(reason: String, error: Error) {
        let event = AuditEvent(
            type: .failedAuth,
            summary: "Authentication failed",
            details: [
                "reason": reason,
                "error": error.localizedDescription
            ]
        )
        try? persistAuditEvent(event)
    }

    private func secretAuditDetails(vault: EnvVault, keys: [String], source: String?) -> [String: String] {
        var details: [String: String] = [
            "vaultID": vault.id.uuidString,
            "vaultName": vault.name,
            "projectPath": vault.projectPath,
            "keys": Array(Set(keys)).sorted().joined(separator: ", "),
            "keyCount": String(keys.count)
        ]
        if let source, !source.isEmpty {
            details["source"] = source
        }
        return details
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

    private func removeTrackedUses(vaultIndex: Int, keys: Set<String>) {
        let vault = state.vaults[vaultIndex]
        state.projectSecretUses.removeAll { use in
            use.projectPath == vault.projectPath &&
                keys.contains(use.key)
        }
    }

    private func loadSecretStateIfNeeded() throws {
        guard !hasLoadedSecretState else { return }
        try reloadSecretState()
    }

    private func reloadSecretState() throws {
        let metadataAuditEvents = state.auditEvents
        var loadedState = try store.loadState()
        Self.hydrateLegacyInventoryIfNeeded(&loadedState)
        loadedState.auditEvents = Self.mergedAuditEvents(metadataAuditEvents, loadedState.auditEvents)
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

    private static func mergedAuditEvents(_ lhs: [AuditEvent], _ rhs: [AuditEvent]) -> [AuditEvent] {
        var eventsByID: [UUID: AuditEvent] = [:]
        for event in lhs + rhs {
            eventsByID[event.id] = event
        }
        return eventsByID.values.sorted { $0.occurredAt < $1.occurredAt }
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

    private func validateDotenvVariables(_ variables: [EnvVariable]) throws {
        for variable in variables {
            try DotenvKeyValidator.validate(variable.key)
            try SecretValueValidator.validate(variable)
        }
    }

    private func validateExportableSecretValues(_ variables: [EnvVariable]) throws {
        for variable in variables {
            try SecretValueValidator.validate(variable)
        }
    }

    private func commitStateWithDotenvPatch(
        vaultIndex: Int,
        upserting variables: [EnvVariable] = [],
        removingKeys: Set<String> = [],
        previousState: AppState,
        auditEvent: AuditEvent? = nil
    ) throws {
        var appliedPatch: DotenvFilePatch?
        do {
            let patch = try makeDotenvFilePatch(vaultIndex: vaultIndex, upserting: variables, removingKeys: removingKeys)
            try patch?.apply()
            appliedPatch = patch
            if let auditEvent {
                state.auditEvents.append(auditEvent)
            }
            try persist()
        } catch {
            state = previousState
            if let appliedPatch {
                try? appliedPatch.restoreOriginal()
            }
            throw error
        }
    }

    private func makeDotenvFilePatch(vaultIndex: Int, upserting variables: [EnvVariable] = [], removingKeys: Set<String> = []) throws -> DotenvFilePatch? {
        let vault = state.vaults[vaultIndex]
        guard let dotenvFileName = vault.dotenvFileName else { return nil }

        let directoryURL = URL(fileURLWithPath: try SecurePath.canonicalDirectoryPath(vault.projectPath), isDirectory: true)
        let dotenvURL = directoryURL.appendingPathComponent(dotenvFileName)
        let canonicalDotenvPath = try SecurePath.canonicalFilePath(dotenvURL.path)
        guard URL(fileURLWithPath: canonicalDotenvPath).deletingLastPathComponent().path == directoryURL.path else {
            throw PersonalEnvError.invalidRequest("Tracked dotenv file must stay inside the vault project folder.")
        }
        let canonicalDotenvURL = URL(fileURLWithPath: canonicalDotenvPath)
        try SecurePath.validateExistingRegularFileTarget(at: canonicalDotenvURL.path, description: "Tracked dotenv file")
        let originalText = FileManager.default.fileExists(atPath: canonicalDotenvURL.path)
            ? try String(contentsOf: canonicalDotenvURL, encoding: .utf8)
            : nil
        let patchedText = DotenvCodec.patch(originalText ?? "", upserting: variables, removingKeys: removingKeys)
        return DotenvFilePatch(url: canonicalDotenvURL, originalText: originalText, patchedText: patchedText)
    }
}

private func writeAtomicallyReplacingFile(text: String, to url: URL) throws {
    let parentURL = url.deletingLastPathComponent()
    let temporaryURL = parentURL.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try text.write(to: temporaryURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
    do {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL, backupItemName: nil, options: [])
    } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw error
    }
}

private struct DotenvFilePatch {
    var url: URL
    var originalText: String?
    var patchedText: String

    func apply() throws {
        try writeAtomicallyReplacingFile(text: patchedText, to: url)
    }

    func restoreOriginal() throws {
        if let originalText {
            try writeAtomicallyReplacingFile(text: originalText, to: url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

private extension ApprovalDestination {
    var auditDescription: String {
        switch self {
        case .file(let path):
            return path
        case .stdout:
            return "stdout"
        case .clipboard:
            return "clipboard"
        case .app:
            return "app"
        }
    }
}
