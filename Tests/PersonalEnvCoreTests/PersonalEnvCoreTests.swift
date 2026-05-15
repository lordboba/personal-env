import Foundation
import Testing
@testable import PersonalEnvCore

@Test func dotenvParsingAndRendering() async throws {
    let variables = DotenvCodec.parse("""
    # ignored
    export OPENAI_API_KEY="sk-test value"
    RESEND_API_KEY=re_test
    EMPTY=
    """)

    #expect(variables.map(\.key) == ["OPENAI_API_KEY", "RESEND_API_KEY", "EMPTY"])
    #expect(variables[0].value == "sk-test value")
    #expect(DotenvCodec.render(variables).contains("OPENAI_API_KEY=\"sk-test value\""))
}

@Test func exportFiltersRequestedKeys() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let service = try VaultService(store: FileStateStore(url: url), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: "/tmp/project")
    try await service.setVariable(vaultID: vault.id, key: "OPENAI_API_KEY", value: "sk-test", scope: "ai")
    try await service.setVariable(vaultID: vault.id, key: "RESEND_API_KEY", value: "re-test", scope: "email")

    let exported = try await service.exportDotenv(vaultID: vault.id, keys: ["OPENAI_API_KEY"])
    #expect(exported.contains("OPENAI_API_KEY=sk-test"))
    #expect(!exported.contains("RESEND_API_KEY"))
}

@Test func updateVariableRenamesWithoutDuplicating() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let service = try VaultService(store: FileStateStore(url: url), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: "/tmp/project")
    try await service.setVariable(vaultID: vault.id, key: "OLD_KEY", value: "old", scope: "project")
    let original = await service.snapshot().vaults[0].variables[0]

    try await service.updateVariable(vaultID: vault.id, variableID: original.id, key: "NEW_KEY", value: "new", scope: "ai")

    let variables = await service.snapshot().vaults[0].variables
    #expect(variables.count == 1)
    #expect(variables[0].id == original.id)
    #expect(variables[0].key == "NEW_KEY")
    #expect(variables[0].value == "new")
    #expect(variables[0].scope == "ai")
}

@Test func repeatedImportsGarbageCollectReplacedSecretRecords() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let service = try VaultService(store: FileStateStore(url: url), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: "/tmp/project", dotenvFileName: ".env")

    try await service.importVariables([
        EnvVariable(key: "OPENAI_API_KEY", value: "first", scope: "project")
    ], vaultID: vault.id)
    let firstImportState = await service.snapshot()
    let firstSecretID = try #require(firstImportState.secrets.first?.id)

    try await service.importVariables([
        EnvVariable(key: "OPENAI_API_KEY", value: "second", scope: "project")
    ], vaultID: vault.id)

    let state = await service.snapshot()
    let variable = try #require(state.vaults.first?.variables.first)
    #expect(state.vaults.first?.variables.count == 1)
    #expect(variable.key == "OPENAI_API_KEY")
    #expect(variable.value == "second")
    #expect(state.secrets.count == 1)
    #expect(state.secrets.first?.id == variable.id)
    #expect(state.secrets.first?.id != firstSecretID)
    #expect(state.projectSecretUses.count == 1)
    #expect(state.projectSecretUses.first?.secretID == variable.id)
    #expect(await service.duplicateHints().isEmpty)
}

@Test func garbageCollectionPreservesDuplicateKeysAcrossProjects() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let service = try VaultService(store: FileStateStore(url: url), authenticator: NoopAuthenticator())
    let firstVault = try await service.upsertVault(name: "First", projectPath: "/tmp/first")
    let secondVault = try await service.upsertVault(name: "Second", projectPath: "/tmp/second")

    try await service.setVariable(vaultID: firstVault.id, key: "OPENAI_API_KEY", value: "first", scope: "project")
    try await service.setVariable(vaultID: secondVault.id, key: "OPENAI_API_KEY", value: "second", scope: "project")

    let state = await service.snapshot()
    let hints = await service.duplicateHints()
    #expect(state.secrets.count == 2)
    #expect(hints.count == 1)
    #expect(hints.first?.key == "OPENAI_API_KEY")
    #expect(hints.first?.conflictState == .conflictingValues)
    #expect(hints.first?.projectPaths == ["/tmp/first", "/tmp/second"])
}

@Test func duplicateHintsIgnoreLoadedUnreferencedSecretRecords() async throws {
    let currentID = UUID()
    let staleID = UUID()
    let state = AppState(vaults: [
        EnvVault(name: "Test", projectPath: "/tmp/project", variables: [
            EnvVariable(id: currentID, key: "OPENAI_API_KEY", value: "current", scope: "project")
        ])
    ], secrets: [
        SecretRecord(id: currentID, key: "OPENAI_API_KEY", value: "current", scope: "project", valueFingerprint: "current-fingerprint"),
        SecretRecord(id: staleID, key: "OPENAI_API_KEY", value: "stale", scope: "project", valueFingerprint: "stale-fingerprint")
    ], projectSecretUses: [
        ProjectSecretUse(projectPath: "/tmp/project", dotenvFileName: ".env", key: "OPENAI_API_KEY", secretID: currentID)
    ])
    let store = CountingStore(state: state)
    let service = try VaultService(store: store, authenticator: NoopAuthenticator())

    try await service.reload()

    #expect(await service.duplicateHints().isEmpty)
}

@Test func renameVaultUpdatesOnlyDisplayName() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let service = try VaultService(store: FileStateStore(url: url), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Old Name", projectPath: "/tmp/project")

    let renamed = try await service.renameVault(vaultID: vault.id, name: "New Name")

    #expect(renamed.id == vault.id)
    #expect(renamed.name == "New Name")
    #expect(renamed.projectPath == "/tmp/project")
    #expect(await service.snapshot().vaults[0].name == "New Name")
}

@Test func deleteVaultRemovesPersonalConfigRecords() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let service = try VaultService(store: FileStateStore(url: url), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Delete Me", projectPath: "/tmp/project")
    try await service.setVariable(vaultID: vault.id, key: "OPENAI_API_KEY", value: "sk-test", scope: "ai")

    try await service.deleteVault(vaultID: vault.id)

    let state = await service.snapshot()
    #expect(state.vaults.isEmpty)
    #expect(state.secrets.isEmpty)
    #expect(state.projectSecretUses.isEmpty)
}

@Test func scansProjectDotenvFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "OPENAI_API_KEY=sk-test\n".write(to: directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "RESEND_API_KEY=re-test\n".write(to: directory.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)

    let files = try DotenvCodec.scanFiles(inDirectory: directory.path)

    #expect(files.map(\.fileName) == [".env", ".env.local"])
    #expect(files.flatMap(\.variables).map(\.key) == ["OPENAI_API_KEY", "RESEND_API_KEY"])
    #expect(files[1].variables[0].scope == "local")
}

@Test func approvedScanPolicyAllowsBroadUserFolders() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let documents = home.appendingPathComponent("Documents", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    let policy = DotenvScanPolicy(homeDirectory: home)

    do {
        try policy.validate(documents, approval: .projectFolder)
        Issue.record("Project-folder scans should require explicit approval for broad folders.")
    } catch {
        #expect(error.localizedDescription.contains("Approve"))
    }

    try policy.validate(documents, approval: .userApprovedDirectory)
}

@Test func scanPolicyBlocksSystemRoots() throws {
    let policy = DotenvScanPolicy()

    do {
        try policy.validate(URL(fileURLWithPath: "/", isDirectory: true), approval: .userApprovedDirectory)
        Issue.record("System roots should remain blocked even when approval is explicit.")
    } catch {
        #expect(error.localizedDescription.contains("system roots"))
    }
}

@Test func recursiveScanSkipsGeneratedDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let app = root.appendingPathComponent("App", isDirectory: true)
    let generated = root.appendingPathComponent("node_modules", isDirectory: true).appendingPathComponent("pkg", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
    try "APP_KEY=expected\n".write(to: app.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "IGNORED_KEY=ignored\n".write(to: generated.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

    let files = try DotenvCodec.scanApprovedDirectory(inDirectory: root.path)

    #expect(files.count == 1)
    #expect(files[0].variables.map(\.key) == ["APP_KEY"])
}

@Test func recursiveScanResolvesProjectRootFromMarkers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    let config = project.appendingPathComponent("config", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
    try "PROJECT_KEY=sk-test\n".write(to: config.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

    let files = try DotenvCodec.scanApprovedDirectory(inDirectory: root.path)

    #expect(files.count == 1)
    #expect(files[0].projectPath == project.path)
}

@Test func newProjectVaultWritesDotenvFile() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())

    let vault = try await service.createProjectVault(name: "ExampleApp", parentDirectory: parentURL.path)
    try await service.setVariable(vaultID: vault.id, key: "OPENAI_API_KEY", value: "sk-test", scope: "ai")

    let dotenvURL = parentURL.appendingPathComponent("ExampleApp").appendingPathComponent(".env")
    let dotenv = try String(contentsOf: dotenvURL, encoding: .utf8)
    #expect(dotenv.contains("OPENAI_API_KEY=sk-test"))
}

@Test func authorizationGrantExpiresAndWriteImpliesRead() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let store = FileAuthorizationGrantStore(url: url)
    let now = Date(timeIntervalSince1970: 1_000)

    _ = try store.approve(.writeSecrets, ttl: 60, at: now)

    #expect(try store.hasValidGrant(for: .writeSecrets, at: now.addingTimeInterval(30)))
    #expect(try store.hasValidGrant(for: .readSecrets, at: now.addingTimeInterval(30)))
    #expect(!(try store.hasValidGrant(for: .writeSecrets, at: now.addingTimeInterval(61))))
}

@Test func vaultServiceLoadsMetadataWithoutSecretValuesUntilUnlock() async throws {
    let state = AppState(vaults: [
        EnvVault(name: "Test", projectPath: "/tmp/project", variables: [
            EnvVariable(key: "OPENAI_API_KEY", value: "sk-test", scope: "ai")
        ])
    ])
    let store = CountingStore(state: state)

    let service = try VaultService(store: store, authenticator: NoopAuthenticator())
    let metadataSnapshot = await service.snapshot()

    #expect(store.loadStateCount == 0)
    #expect(store.loadMetadataCount == 1)
    #expect(metadataSnapshot.vaults[0].variables[0].key == "OPENAI_API_KEY")
    #expect(metadataSnapshot.vaults[0].variables[0].value == "")

    let exported = try await service.exportDotenv(vaultID: metadataSnapshot.vaults[0].id)

    #expect(store.loadStateCount == 1)
    #expect(exported.contains("OPENAI_API_KEY=sk-test"))
}

@Test func keychainStoreMetadataUsesLocalRedactedCache() throws {
    let metadataURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("vault-metadata.json")
    let store = KeychainStore(service: "com.tylerxiao.personal-env.tests", account: UUID().uuidString, metadataURL: metadataURL)
    let variableID = UUID()
    let state = AppState(vaults: [
        EnvVault(name: "Test", projectPath: "/tmp/project", variables: [
            EnvVariable(id: variableID, key: "OPENAI_API_KEY", value: "sk-test", scope: "ai")
        ])
    ], secrets: [
        SecretRecord(id: variableID, key: "OPENAI_API_KEY", value: "sk-test", scope: "ai", valueFingerprint: "secret-fingerprint")
    ], projectSecretUses: [
        ProjectSecretUse(projectPath: "/tmp/project", dotenvFileName: ".env", key: "OPENAI_API_KEY", secretID: variableID)
    ])

    try store.saveMetadata(state)
    let loaded = try store.loadMetadata()
    let rawMetadata = try String(contentsOf: metadataURL, encoding: .utf8)

    #expect(FileManager.default.fileExists(atPath: metadataURL.path))
    #expect(loaded.vaults[0].variables[0].key == "OPENAI_API_KEY")
    #expect(loaded.vaults[0].variables[0].value == "")
    #expect(loaded.secrets.isEmpty)
    #expect(!rawMetadata.contains("secret-fingerprint"))
    #expect(!rawMetadata.contains("sk-test"))
}

@Test func keychainStoreLoadMetadataSanitizesLegacyCache() throws {
    let metadataURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("vault-metadata.json")
    let store = KeychainStore(service: "com.tylerxiao.personal-env.tests", account: UUID().uuidString, metadataURL: metadataURL)
    let variableID = UUID()
    let legacyMetadata = AppState(vaults: [
        EnvVault(name: "Test", projectPath: "/tmp/project", variables: [
            EnvVariable(id: variableID, key: "OPENAI_API_KEY", value: "", scope: "ai")
        ])
    ], secrets: [
        SecretRecord(id: variableID, key: "OPENAI_API_KEY", value: "", scope: "ai", valueFingerprint: "legacy-fingerprint")
    ], projectSecretUses: [
        ProjectSecretUse(projectPath: "/tmp/project", dotenvFileName: ".env", key: "OPENAI_API_KEY", secretID: variableID)
    ])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(legacyMetadata).write(to: metadataURL, options: [.atomic])

    let loaded = try store.loadMetadata()
    let rawMetadata = try String(contentsOf: metadataURL, encoding: .utf8)

    #expect(loaded.secrets.isEmpty)
    #expect(loaded.projectSecretUses.count == 1)
    #expect(!rawMetadata.contains("legacy-fingerprint"))
}

@Test func reloadBeforeUnlockAuthenticatesBeforeLoadingSecrets() async throws {
    let state = AppState(vaults: [
        EnvVault(name: "Test", projectPath: "/tmp/project", variables: [
            EnvVariable(key: "OPENAI_API_KEY", value: "sk-test", scope: "ai")
        ])
    ])
    let store = CountingStore(state: state)
    let authenticator = CountingAuthenticator()
    let service = try VaultService(store: store, authenticator: authenticator)

    try await service.reload()

    #expect(await authenticator.unlockCount == 1)
    #expect(store.loadStateCount == 1)
}

final class CountingStore: SecretStoring, @unchecked Sendable {
    private let state: AppState
    private(set) var loadStateCount = 0
    private(set) var loadMetadataCount = 0

    init(state: AppState) {
        self.state = state
    }

    func loadState() throws -> AppState {
        loadStateCount += 1
        return state
    }

    func saveState(_ state: AppState) throws {}

    func loadMetadata() throws -> AppState {
        loadMetadataCount += 1
        return state.redactedForMetadata()
    }
}

actor CountingAuthenticator: Authenticating {
    private(set) var unlockCount = 0

    func unlock(reason _: String, capability _: ApprovalCapability) async throws {
        unlockCount += 1
    }
}
