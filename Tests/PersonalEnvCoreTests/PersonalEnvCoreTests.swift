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

@Test func secretValuesRejectLineBreaksThatWouldCreateExtraDotenvAssignments() throws {
    do {
        try SecretValueValidator.validate(value: "allowed\nINJECTED=value", key: "OPENAI_API_KEY")
        Issue.record("Secret values with newlines should not be accepted for dotenv storage.")
    } catch {
        #expect(error.localizedDescription.contains("line breaks"))
    }
}

@Test func dotenvPasteReviewParsesValidAssignmentsAndIgnoresComments() throws {
    let review = DotenvCodec.reviewPaste("""
    # ignored
    export OPENAI_API_KEY="sk-test value"
    RESEND_API_KEY=re_test
    EMPTY=
    """, scope: "local")

    #expect(review.variables.map(\.key) == ["OPENAI_API_KEY", "RESEND_API_KEY", "EMPTY"])
    #expect(review.variables.map(\.scope) == ["local", "local", "local"])
    #expect(review.variables[0].value == "sk-test value")
    #expect(review.variables[2].value == "")
    #expect(review.diagnostics.isEmpty)
}

@Test func dotenvPasteReviewReportsInvalidLines() throws {
    let review = DotenvCodec.reviewPaste("""
    VALID_KEY=value
    NOT AN ASSIGNMENT
    1_BAD=value
    PADDED =value
    """)

    #expect(review.variables.map(\.key) == ["VALID_KEY"])
    #expect(review.diagnostics.count == 3)
    #expect(review.diagnostics.map(\.lineNumber) == [2, 3, 4])
    #expect(review.diagnostics[0].message.contains("KEY=value"))
}

@Test func dotenvPasteReviewKeepsLastDuplicateAssignment() throws {
    let review = DotenvCodec.reviewPaste("""
    API_KEY=first
    OTHER_KEY=value
    API_KEY=second
    """)

    #expect(review.variables.map(\.key) == ["API_KEY", "OTHER_KEY"])
    #expect(review.variables.first?.value == "second")
    #expect(review.replacedAssignmentCount == 1)
    #expect(review.diagnostics.isEmpty)
}

@Test func dotenvPasteReviewReportsRedactedPlaceholdersAndKeepsValidAssignments() throws {
    let redactedResendKey = "re_" + String(repeating: "\u{2022}", count: 8)
    let review = DotenvCodec.reviewPaste("""
    OPENAI_API_KEY=sk-test
    RESEND_API_KEY=\(redactedResendKey)
    GOOGLE_MAPS_API_KEY=gmaps-test
    """)

    #expect(review.variables.map(\.key) == ["OPENAI_API_KEY", "GOOGLE_MAPS_API_KEY"])
    #expect(review.diagnostics.count == 1)
    #expect(review.diagnostics.first?.lineNumber == 2)
    #expect(review.diagnostics.first?.message.contains("redacted") == true)
}

@Test func dotenvPatchPreservesUnrelatedLinesAndAppendsMissingKeys() throws {
    let patched = DotenvCodec.patch("""
    # keep this
    EXISTING=old
    UNMANAGED=value
    """, upserting: [
        EnvVariable(key: "EXISTING", value: "new value"),
        EnvVariable(key: "ADDED", value: "fresh")
    ])

    #expect(patched.contains("# keep this\n"))
    #expect(patched.contains("EXISTING=\"new value\"\n"))
    #expect(patched.contains("UNMANAGED=value\n"))
    #expect(patched.hasSuffix("ADDED=fresh\n"))
    #expect(!patched.contains("EXISTING=old"))
}

@Test func dotenvPatchRemovesAllAssignmentsForDeletedKey() throws {
    let patched = DotenvCodec.patch("""
    REMOVE_ME=first
    KEEP_ME=true
    export REMOVE_ME=second
    """, upserting: [], removingKeys: ["REMOVE_ME"])

    #expect(patched == "KEEP_ME=true\n")
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

@Test func exportArgumentsRequireExplicitDestination() throws {
    let vaultID = UUID()

    do {
        _ = try PEnvExportCommand.parse([vaultID.uuidString])
        Issue.record("Bare exports should not be allowed to print secrets to stdout.")
    } catch {
        #expect(error.localizedDescription.contains("--to-file"))
    }
}

@Test func exportArgumentsParseFileDestinationAndKeys() throws {
    let vaultID = UUID()
    let command = try PEnvExportCommand.parse([
        vaultID.uuidString,
        "--to-file",
        "/tmp/project/.env",
        "OPENAI_API_KEY",
        "RESEND_API_KEY"
    ])

    #expect(command.vaultID == vaultID)
    #expect(command.destination == .file("/tmp/project/.env"))
    #expect(command.keys == ["OPENAI_API_KEY", "RESEND_API_KEY"])
}

@Test func exportArgumentsRequireExplicitStdoutConfirmation() throws {
    let vaultID = UUID()

    do {
        _ = try PEnvExportCommand.parse([vaultID.uuidString, "--stdout", "OPENAI_API_KEY"])
        Issue.record("Stdout exports should require the explicit secret stdout confirmation flag.")
    } catch {
        #expect(error.localizedDescription.contains("--allow-secret-stdout"))
    }

    let command = try PEnvExportCommand.parse([
        vaultID.uuidString,
        "--stdout",
        "--allow-secret-stdout",
        "OPENAI_API_KEY"
    ])

    #expect(command.destination == .stdout)
    #expect(command.keys == ["OPENAI_API_KEY"])
}

@Test func setArgumentsRejectSecretValuesInPositionals() throws {
    let vaultID = UUID()

    do {
        _ = try PEnvSetCommand.parse([vaultID.uuidString, "OPENAI_API_KEY", "sk-test", "ai"])
        Issue.record("penv set should not accept secret values as positional arguments.")
    } catch {
        #expect(error.localizedDescription.contains("--stdin"))
    }
}

@Test func setArgumentsParseStdinInputAndScope() throws {
    let vaultID = UUID()
    let command = try PEnvSetCommand.parse([
        vaultID.uuidString,
        "OPENAI_API_KEY",
        "--stdin",
        "--scope",
        "ai"
    ])

    #expect(command.vaultID == vaultID)
    #expect(command.key == "OPENAI_API_KEY")
    #expect(command.input == .stdin)
    #expect(command.scope == "ai")
}

@Test func setArgumentsParseEditorInput() throws {
    let vaultID = UUID()
    let command = try PEnvSetCommand.parse([vaultID.uuidString, "RESEND_API_KEY", "--editor"])

    #expect(command.vaultID == vaultID)
    #expect(command.key == "RESEND_API_KEY")
    #expect(command.input == .editor)
    #expect(command.scope == "project")
}

@Test func exportDotenvToFilePatchesExistingFileAndReturnsRedactedReceipt() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let dotenvURL = projectURL.appendingPathComponent(".env")
    try """
    # keep this
    OPENAI_API_KEY=old
    UNMANAGED=value
    """.write(to: dotenvURL, atomically: true, encoding: .utf8)

    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: projectURL.path)
    try await service.setVariable(vaultID: vault.id, key: "OPENAI_API_KEY", value: "sk-test", scope: "ai")
    try await service.setVariable(vaultID: vault.id, key: "RESEND_API_KEY", value: "re-test", scope: "email")

    let receipt = try await service.exportDotenv(vaultID: vault.id, toFile: dotenvURL.path, keys: ["OPENAI_API_KEY"])
    let text = try String(contentsOf: dotenvURL, encoding: .utf8)

    #expect(text.contains("# keep this\n"))
    #expect(text.contains("OPENAI_API_KEY=sk-test\n"))
    #expect(text.contains("UNMANAGED=value"))
    #expect(!text.contains("RESEND_API_KEY"))
    #expect(receipt.keys == ["OPENAI_API_KEY"])
    #expect(receipt.variableCount == 1)
    #expect(!receipt.description.contains("sk-test"))
}

@Test func exportDotenvToFileCreatesFileWithOwnerOnlyPermissions() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let dotenvURL = projectURL.appendingPathComponent(".env")

    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: projectURL.path)
    try await service.setVariable(vaultID: vault.id, key: "OPENAI_API_KEY", value: "sk-test", scope: "ai")

    _ = try await service.exportDotenv(vaultID: vault.id, toFile: dotenvURL.path)

    let text = try String(contentsOf: dotenvURL, encoding: .utf8)
    let attributes = try FileManager.default.attributesOfItem(atPath: dotenvURL.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(text == "OPENAI_API_KEY=sk-test\n")
    #expect(permissions.intValue & 0o077 == 0)
}

@Test func exportDotenvToFileRejectsUnsafeTargets() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: projectURL.path)
    try await service.setVariable(vaultID: vault.id, key: "OPENAI_API_KEY", value: "sk-test", scope: "ai")

    do {
        _ = try await service.exportDotenv(vaultID: vault.id, toFile: projectURL.path)
        Issue.record("Export target should not accept directories.")
    } catch {
        #expect(error.localizedDescription.contains("regular file"))
    }

    do {
        _ = try await service.exportDotenv(vaultID: vault.id, toFile: projectURL.appendingPathComponent("missing/.env").path)
        Issue.record("Export target should require an existing parent directory.")
    } catch {
        #expect(error.localizedDescription.contains("parent folder"))
    }

    let outsideURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
    let outsideDotenv = outsideURL.appendingPathComponent(".env")
    let symlinkURL = projectURL.appendingPathComponent("linked.env")
    try "OUTSIDE_KEY=keep\n".write(to: outsideDotenv, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideDotenv)

    do {
        _ = try await service.exportDotenv(vaultID: vault.id, toFile: symlinkURL.path)
        Issue.record("Export target should reject symlinks.")
    } catch {
        #expect(error.localizedDescription.contains("regular file"))
    }

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path) == outsideDotenv.path)
    #expect(try String(contentsOf: outsideDotenv, encoding: .utf8) == "OUTSIDE_KEY=keep\n")
}

@Test func exportDotenvRejectsMissingRequestedKeys() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let dotenvURL = projectURL.appendingPathComponent(".env")

    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: projectURL.path)
    try await service.setVariable(vaultID: vault.id, key: "OPENAI_API_KEY", value: "sk-test", scope: "ai")

    do {
        _ = try await service.exportDotenv(vaultID: vault.id, toFile: dotenvURL.path, keys: ["MISSING_KEY"])
        Issue.record("Exporting a requested missing key should fail.")
    } catch {
        #expect(error.localizedDescription.contains("MISSING_KEY"))
    }
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

@Test func updateVariableRejectsDuplicateKeyRename() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let service = try VaultService(store: FileStateStore(url: url), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: "/tmp/project")
    try await service.setVariable(vaultID: vault.id, key: "FIRST_KEY", value: "first", scope: "project")
    try await service.setVariable(vaultID: vault.id, key: "SECOND_KEY", value: "second", scope: "project")
    let snapshot = await service.snapshot()
    let first = try #require(snapshot.vaults.first?.variables.first { $0.key == "FIRST_KEY" })

    do {
        try await service.updateVariable(vaultID: vault.id, variableID: first.id, key: "SECOND_KEY", value: "updated", scope: "project")
        Issue.record("Renaming to an existing key should fail.")
    } catch {
        #expect(error.localizedDescription.contains("already exists"))
    }

    let variables = await service.snapshot().vaults[0].variables
    #expect(variables.map(\.key).sorted() == ["FIRST_KEY", "SECOND_KEY"])
}

@Test func importVariablesRejectsInvalidKeys() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let service = try VaultService(store: FileStateStore(url: url), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: "/tmp/project")

    do {
        try await service.importVariables([
            EnvVariable(key: "VALID_KEY", value: "value"),
            EnvVariable(key: "INVALID KEY", value: "value")
        ], vaultID: vault.id)
        Issue.record("Invalid imported keys should fail.")
    } catch {
        #expect(error.localizedDescription.contains("letters, numbers, and underscores"))
    }

    #expect(await service.snapshot().vaults[0].variables.isEmpty)
}

@Test func importVariablesRejectsRedactedSecretPlaceholders() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let service = try VaultService(store: FileStateStore(url: url), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: "/tmp/project")
    let redactedResendKey = "re_" + String(repeating: "\u{2022}", count: 8)

    do {
        try await service.importVariables([
            EnvVariable(key: "RESEND_API_KEY", value: redactedResendKey)
        ], vaultID: vault.id)
        Issue.record("Redacted placeholders should not be accepted as secret values.")
    } catch {
        #expect(error.localizedDescription.contains("redacted"))
    }

    #expect(await service.snapshot().vaults[0].variables.isEmpty)
}

@Test func setVariableRejectsRedactedSecretPlaceholdersWithoutReplacingExistingValue() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let service = try VaultService(store: FileStateStore(url: url), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: "/tmp/project")
    let redactedResendKey = "re_" + String(repeating: "\u{2022}", count: 8)
    try await service.setVariable(vaultID: vault.id, key: "RESEND_API_KEY", value: "re_real", scope: "email")

    do {
        try await service.setVariable(vaultID: vault.id, key: "RESEND_API_KEY", value: redactedResendKey, scope: "email")
        Issue.record("Redacted placeholders should not replace an existing secret value.")
    } catch {
        #expect(error.localizedDescription.contains("redacted"))
    }

    let variable = try #require(await service.snapshot().vaults[0].variables.first)
    #expect(variable.value == "re_real")
}

@Test func exportDotenvRejectsStoredRedactedSecretPlaceholders() async throws {
    let vaultID = UUID()
    let variableID = UUID()
    let redactedResendKey = "re_" + String(repeating: "\u{2022}", count: 8)
    let state = AppState(vaults: [
        EnvVault(id: vaultID, name: "Test", projectPath: "/tmp/project", variables: [
            EnvVariable(id: variableID, key: "RESEND_API_KEY", value: redactedResendKey)
        ])
    ])
    let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("env")
    try "KEEP_ME=true\n".write(to: targetURL, atomically: true, encoding: .utf8)
    let service = try VaultService(store: CountingStore(state: state), authenticator: NoopAuthenticator())

    do {
        _ = try await service.exportDotenv(vaultID: vaultID, toFile: targetURL.path, keys: ["RESEND_API_KEY"])
        Issue.record("Export should fail rather than write a redacted placeholder.")
    } catch {
        #expect(error.localizedDescription.contains("redacted"))
    }

    #expect(try String(contentsOf: targetURL, encoding: .utf8) == "KEEP_ME=true\n")
}

@Test func scopedApprovalRequiresExactSubjectMatch() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let store = FileAuthorizationGrantStore(url: url)
    let vaultID = UUID()
    let now = Date(timeIntervalSince1970: 1_000)
    let subject = ApprovalSubject(request: ApprovalSubjectRequest(
        capability: .readSecrets,
        vaultID: vaultID,
        keySet: ["OPENAI_API_KEY", "RESEND_API_KEY"],
        destination: .file("/tmp/project/.env"),
        requester: "agent:codex",
        command: "export"
    ))

    _ = try store.approve(ApprovalRequest(subject: subject, ttl: 60), at: now)

    #expect(try store.hasValidGrant(matching: subject, at: now.addingTimeInterval(30)))
    #expect(!(try store.hasValidGrant(matching: ApprovalSubject(request: ApprovalSubjectRequest(
        capability: .readSecrets,
        vaultID: vaultID,
        keySet: ["OPENAI_API_KEY"],
        destination: .file("/tmp/project/.env"),
        requester: "agent:codex",
        command: "export"
    )), at: now.addingTimeInterval(30))))
    #expect(!(try store.hasValidGrant(matching: ApprovalSubject(request: ApprovalSubjectRequest(
        capability: .readSecrets,
        vaultID: vaultID,
        keySet: ["OPENAI_API_KEY", "RESEND_API_KEY"],
        destination: .file("/tmp/other/.env"),
        requester: "agent:codex",
        command: "export"
    )), at: now.addingTimeInterval(30))))
}

@Test func scopedRequesterApprovalAuthorizesMatchingVaultServiceExport() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let grantsURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("env")
    let now = Date(timeIntervalSince1970: 1_000)
    let grantStore = FileAuthorizationGrantStore(url: grantsURL)
    let setupService = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())
    let vault = try await setupService.upsertVault(name: "Test", projectPath: "/tmp/project")
    try await setupService.setVariable(vaultID: vault.id, key: "OPENAI_API_KEY", value: "sk-test", scope: "ai")

    let service = try VaultService(
        store: FileStateStore(url: stateURL),
        authenticator: LocalAuthenticator(grantStore: grantStore, now: { now.addingTimeInterval(30) })
    )
    let subject = ApprovalSubject(request: ApprovalSubjectRequest(
        capability: .readSecrets,
        vaultID: vault.id,
        keySet: ["OPENAI_API_KEY"],
        destination: .file(try SecurePath.canonicalFilePath(targetURL.path)),
        requester: "agent:codex",
        command: "export"
    ))
    _ = try grantStore.approve(ApprovalRequest(subject: subject, ttl: 60), at: now)

    _ = try await service.exportDotenv(vaultID: vault.id, toFile: targetURL.path, keys: ["OPENAI_API_KEY"], requester: "agent:codex")

    #expect(try String(contentsOf: targetURL, encoding: .utf8).contains("OPENAI_API_KEY=sk-test"))
}

@Test func fileApprovalDestinationsUseCanonicalAbsolutePaths() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let previousDirectory = FileManager.default.currentDirectoryPath
    defer {
        FileManager.default.changeCurrentDirectoryPath(previousDirectory)
    }

    FileManager.default.changeCurrentDirectoryPath(directory.path)
    let canonicalPath = try SecurePath.canonicalFilePath(".env")

    #expect(canonicalPath == directory.appendingPathComponent(".env").path)
    #expect(canonicalPath.hasPrefix("/"))
}

@Test func auditEventsAreDurableAndRedactedForSecretOperations() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let dotenvURL = projectURL.appendingPathComponent(".env")
    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: projectURL.path)

    try await service.importVariables([
        EnvVariable(key: "OPENAI_API_KEY", value: "sk-test-secret", scope: "ai")
    ], vaultID: vault.id)
    _ = try await service.exportDotenv(vaultID: vault.id, toFile: dotenvURL.path, keys: ["OPENAI_API_KEY"])

    let persisted = try FileStateStore(url: stateURL).loadState()
    #expect(persisted.auditEvents.map(\.type).contains(.importSecrets))
    #expect(persisted.auditEvents.map(\.type).contains(.exportSecrets))

    let encoded = String(decoding: try JSONEncoder().encode(persisted.auditEvents), as: UTF8.self)
    #expect(!encoded.contains("sk-test-secret"))
    #expect(encoded.contains("OPENAI_API_KEY"))
}

@Test func auditRecordsFailedAuthenticationWithoutSecretValues() async throws {
    let state = AppState(vaults: [
        EnvVault(name: "Test", projectPath: "/tmp/project", variables: [
            EnvVariable(key: "OPENAI_API_KEY", value: "")
        ])
    ])
    let store = MetadataCapturingStore(state: state)
    let service = try VaultService(store: store, authenticator: FailingAuthenticator())

    do {
        try await service.unlock()
        Issue.record("Unlock should fail.")
    } catch {
        #expect(error.localizedDescription.contains("denied"))
    }

    #expect(store.savedMetadata?.auditEvents.map(\.type) == [.failedAuth])
    let encoded = String(decoding: try JSONEncoder().encode(store.savedMetadata?.auditEvents ?? []), as: UTF8.self)
    #expect(!encoded.contains("sk-test"))
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

@Test func approvedScanSkipsSymlinkedDotenvFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let outsideDotenv = outside.appendingPathComponent(".env")
    try "OUTSIDE_KEY=secret\n".write(to: outsideDotenv, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".env"), withDestinationURL: outsideDotenv)

    let files = try DotenvCodec.scanApprovedDirectory(inDirectory: root.path)

    #expect(files.isEmpty)
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
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())

    let vault = try await service.createProjectVault(name: "ExampleApp", parentDirectory: parentURL.path)
    try await service.setVariable(vaultID: vault.id, key: "OPENAI_API_KEY", value: "sk-test", scope: "ai")

    let dotenvURL = parentURL.appendingPathComponent("ExampleApp").appendingPathComponent(".env")
    let dotenv = try String(contentsOf: dotenvURL, encoding: .utf8)
    #expect(dotenv.contains("OPENAI_API_KEY=sk-test"))
}

@Test func newProjectVaultRejectsPathSeparatorNames() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())

    do {
        _ = try await service.createProjectVault(name: "../Escaped", parentDirectory: parentURL.path)
        Issue.record("Project names should not be able to escape the selected parent directory.")
    } catch {
        #expect(error.localizedDescription.contains("single folder name"))
    }
}

@Test func setVariableAppendsToTrackedDotenvWithoutRewritingUnmanagedContent() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try "# owner note\nUNMANAGED=keep\n".write(to: projectURL.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: projectURL.path, dotenvFileName: ".env")

    try await service.setVariable(vaultID: vault.id, key: "OPENAI_API_KEY", value: "sk test", scope: "ai")

    let dotenv = try String(contentsOf: projectURL.appendingPathComponent(".env"), encoding: .utf8)
    #expect(dotenv.contains("# owner note\n"))
    #expect(dotenv.contains("UNMANAGED=keep\n"))
    #expect(dotenv.hasSuffix("OPENAI_API_KEY=\"sk test\"\n"))
}

@Test func trackedDotenvWriteRejectsSymlinkTargets() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outsideURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
    let outsideDotenv = outsideURL.appendingPathComponent(".env")
    try "OUTSIDE_KEY=keep\n".write(to: outsideDotenv, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: projectURL.appendingPathComponent(".env"), withDestinationURL: outsideDotenv)
    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: projectURL.path, dotenvFileName: ".env")

    do {
        try await service.setVariable(vaultID: vault.id, key: "OPENAI_API_KEY", value: "sk-test", scope: "project")
        Issue.record("Tracked dotenv writes should reject symlink targets.")
    } catch {
        #expect(error.localizedDescription.contains("Tracked dotenv file must be a regular file"))
    }

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: projectURL.appendingPathComponent(".env").path) == outsideDotenv.path)
    #expect(try String(contentsOf: outsideDotenv, encoding: .utf8) == "OUTSIDE_KEY=keep\n")
}

@Test func updateVariableRenamesTrackedDotenvAssignment() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try "OLD_KEY=old\nKEEP_ME=true\n".write(to: projectURL.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: projectURL.path, dotenvFileName: ".env")
    try await service.setVariable(vaultID: vault.id, key: "OLD_KEY", value: "old", scope: "project")
    let snapshot = await service.snapshot()
    let variable = try #require(snapshot.vaults.first?.variables.first)

    try await service.updateVariable(vaultID: vault.id, variableID: variable.id, key: "NEW_KEY", value: "new", scope: "project")

    let dotenv = try String(contentsOf: projectURL.appendingPathComponent(".env"), encoding: .utf8)
    #expect(!dotenv.contains("OLD_KEY="))
    #expect(dotenv.contains("NEW_KEY=new\n"))
    #expect(dotenv.contains("KEEP_ME=true\n"))
    let state = await service.snapshot()
    #expect(state.projectSecretUses.count == 1)
    #expect(state.projectSecretUses.first?.key == "NEW_KEY")
    #expect(state.projectSecretUses.first?.secretID == variable.id)
    #expect(state.secrets.map(\.id) == [variable.id])
}

@Test func deleteVariableRemovesTrackedDotenvAssignment() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try "REMOVE_ME=secret\nKEEP_ME=true\n".write(to: projectURL.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: projectURL.path, dotenvFileName: ".env")
    try await service.setVariable(vaultID: vault.id, key: "REMOVE_ME", value: "secret", scope: "project")
    let snapshot = await service.snapshot()
    let variable = try #require(snapshot.vaults.first?.variables.first)

    try await service.deleteVariable(vaultID: vault.id, variableID: variable.id)

    let dotenv = try String(contentsOf: projectURL.appendingPathComponent(".env"), encoding: .utf8)
    #expect(!dotenv.contains("REMOVE_ME="))
    #expect(dotenv == "KEEP_ME=true\n")
    let state = await service.snapshot()
    #expect(state.vaults.first?.variables.isEmpty == true)
    #expect(state.projectSecretUses.isEmpty)
    #expect(state.secrets.isEmpty)
}

@Test func renameThenDeleteRemovesStaleInventory() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try "OLD_KEY=secret\n".write(to: projectURL.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: projectURL.path, dotenvFileName: ".env")
    try await service.setVariable(vaultID: vault.id, key: "OLD_KEY", value: "secret", scope: "project")
    let variable = try #require(await service.snapshot().vaults.first?.variables.first)

    try await service.updateVariable(vaultID: vault.id, variableID: variable.id, key: "NEW_KEY", value: "secret", scope: "project")
    try await service.deleteVariable(vaultID: vault.id, variableID: variable.id)

    let state = await service.snapshot()
    #expect(state.vaults.first?.variables.isEmpty == true)
    #expect(state.projectSecretUses.isEmpty)
    #expect(state.secrets.isEmpty)
}

@Test func trackedDotenvReadFailureDoesNotCommitVaultMutation() async throws {
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let dotenvURL = projectURL.appendingPathComponent(".env")
    try Data([0xff, 0xfe, 0xfd]).write(to: dotenvURL, options: [.atomic])
    let service = try VaultService(store: FileStateStore(url: stateURL), authenticator: NoopAuthenticator())
    let vault = try await service.upsertVault(name: "Test", projectPath: projectURL.path, dotenvFileName: ".env")

    do {
        try await service.setVariable(vaultID: vault.id, key: "OPENAI_API_KEY", value: "sk-test", scope: "project")
        Issue.record("Invalid UTF-8 dotenv content should fail instead of being treated as an empty file.")
    } catch {
        #expect(!error.localizedDescription.isEmpty)
    }

    let state = await service.snapshot()
    #expect(state.vaults.first?.variables.isEmpty == true)
    #expect(state.projectSecretUses.isEmpty)
    #expect(state.secrets.isEmpty)
    #expect(try Data(contentsOf: dotenvURL) == Data([0xff, 0xfe, 0xfd]))
}

@Test func authorizationGrantExpiresAndRequiresExactCapability() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let store = FileAuthorizationGrantStore(url: url)
    let now = Date(timeIntervalSince1970: 1_000)

    _ = try store.approve(.writeSecrets, ttl: 60, at: now)

    #expect(try store.hasValidGrant(for: .writeSecrets, at: now.addingTimeInterval(30)))
    #expect(!(try store.hasValidGrant(for: .readSecrets, at: now.addingTimeInterval(30))))
    #expect(!(try store.hasValidGrant(for: .writeSecrets, at: now.addingTimeInterval(61))))
}

@Test func keychainProtectedAttributesUseUserPresenceAccessControl() throws {
    let attributes = try KeychainItemProtection.protectedAttributes(
        data: Data("secret".utf8),
        label: "Test Label",
        description: "Test Description"
    )

    #expect(attributes[kSecAttrAccessControl as String] != nil)
    #expect(attributes[kSecAttrAccessible as String] == nil)
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
    let attributes = try FileManager.default.attributesOfItem(atPath: metadataURL.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)

    #expect(FileManager.default.fileExists(atPath: metadataURL.path))
    #expect(permissions.intValue & 0o077 == 0)
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

    func unlock(reason _: String, subject _: ApprovalSubject) async throws {
        unlockCount += 1
    }
}

final class MetadataCapturingStore: SecretStoring, @unchecked Sendable {
    private let state: AppState
    private(set) var savedMetadata: AppState?

    init(state: AppState) {
        self.state = state
    }

    func loadState() throws -> AppState {
        state
    }

    func saveState(_ state: AppState) throws {}

    func loadMetadata() throws -> AppState {
        state.redactedForMetadata()
    }

    func saveMetadata(_ state: AppState) throws {
        savedMetadata = state.redactedForMetadata()
    }
}

struct FailingAuthenticator: Authenticating {
    func unlock(reason _: String, subject _: ApprovalSubject) async throws {
        throw PersonalEnvError.authenticationFailed("denied")
    }
}
