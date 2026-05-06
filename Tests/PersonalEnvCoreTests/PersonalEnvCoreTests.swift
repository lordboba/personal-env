import Foundation
import Testing
@testable import PersonalEnvCore

private func scanPath(_ url: URL) -> String {
    let path = url.path
    return path.hasPrefix("/var/") ? "/private\(path)" : path
}

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

@Test func recursiveScanFindsNestedDotenvFilesAndSkipsLargeGeneratedFolders() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let app = root.appendingPathComponent("ExampleApp", isDirectory: true)
    let nested = root.appendingPathComponent("Nested/Worker", isDirectory: true)
    let nodeModules = root.appendingPathComponent("node_modules/package", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
    try "OPENAI_API_KEY=sk-test\n".write(to: app.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
    try "RESEND_API_KEY=re-test\n".write(to: nested.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "IGNORED_KEY=ignored\n".write(to: nodeModules.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

    let files = try DotenvCodec.scanFilesRecursively(inDirectory: root.path)

    #expect(files.map(\.projectPath).contains(scanPath(app)))
    #expect(files.map(\.projectPath).contains(scanPath(nested)))
    #expect(!files.flatMap(\.variables).map(\.key).contains("IGNORED_KEY"))
}

@Test func recursiveScanBlocksBroadMacFolders() async throws {
    #expect(throws: PersonalEnvError.self) {
        _ = try DotenvCodec.scanFilesRecursively(inDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}

@Test func importedDetectedFilesPreserveProjectUsageAndDuplicateHints() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let appOne = root.appendingPathComponent("AppOne", isDirectory: true)
    let appTwo = root.appendingPathComponent("AppTwo", isDirectory: true)
    try FileManager.default.createDirectory(at: appOne, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: appTwo, withIntermediateDirectories: true)
    try "SHARED_KEY=same\n".write(to: appOne.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
    try "SHARED_KEY=same\n".write(to: appTwo.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())

    try await service.importDetectedDotenvFiles(DotenvCodec.scanFilesRecursively(inDirectory: root.path))

    let state = await service.snapshot()
    #expect(state.vaults.map(\.projectPath).contains(scanPath(appOne)))
    #expect(state.vaults.map(\.projectPath).contains(scanPath(appTwo)))
    #expect(state.secrets.count == 2)
    #expect(state.projectSecretUses.count == 2)
    let hints = await service.duplicateHints()
    #expect(hints.count == 1)
    #expect(hints[0].key == "SHARED_KEY")
    #expect(hints[0].conflictState == .sameValue)
}

@Test func legacyVaultStateHydratesInventoryMetadata() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let legacy = AppState(vaults: [
        EnvVault(name: "Legacy", projectPath: "/tmp/legacy", dotenvFileName: ".env.local", variables: [
            EnvVariable(key: "OPENAI_API_KEY", value: "sk-test", scope: "ai")
        ])
    ])
    try FileStateStore(url: stateURL).saveState(legacy)

    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())
    let state = await service.snapshot()

    #expect(state.secrets.count == 1)
    #expect(state.projectSecretUses.count == 1)
    #expect(state.projectSecretUses[0].dotenvFileName == ".env.local")
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
