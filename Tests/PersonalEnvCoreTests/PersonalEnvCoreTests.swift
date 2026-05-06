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
