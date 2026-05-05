import SwiftUI
import AppKit

#if canImport(PersonalEnvCore)
import PersonalEnvCore
#endif

@main
struct PersonalEnvDesktopApp: App {
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        Self.installApplicationIcon()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private static func installApplicationIcon() {
        guard
            let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else {
            return
        }

        NSApplication.shared.applicationIconImage = icon
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task {
                    await model.load()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import .env...") {
                    model.presentImporter = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var state = AppState()
    @Published var selectedVaultID: EnvVault.ID?
    @Published var selectedVariableID: EnvVariable.ID?
    @Published var status = "Locked"
    @Published var presentImporter = false
    @Published var errorMessage: String?
    @Published var duplicateHints: [DuplicateHint] = []

    private var service: VaultService?

    var selectedVault: EnvVault? {
        state.vaults.first { $0.id == selectedVaultID } ?? state.vaults.first
    }

    var selectedVariable: EnvVariable? {
        selectedVault?.variables.first { $0.id == selectedVariableID }
    }

    func load() async {
        do {
            let service = try VaultService()
            self.service = service
            state = await service.snapshot()
            duplicateHints = await service.duplicateHints()
            if selectedVaultID == nil {
                selectedVaultID = state.vaults.first?.id
            }
            if selectedVariableID == nil {
                selectedVariableID = selectedVault?.variables.first?.id
            }
            status = "Ready"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createNewProject(name: String, parentDirectory: String) async {
        guard let service else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedParent = parentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Project name is required."
            return
        }
        guard !trimmedParent.isEmpty else {
            errorMessage = "Parent folder is required."
            return
        }

        do {
            let vault = try await service.createProjectVault(name: trimmedName, parentDirectory: trimmedParent)
            state = await service.snapshot()
            selectedVaultID = vault.id
            selectedVariableID = state.vaults.first { $0.id == vault.id }?.variables.first?.id
            status = "Created \(vault.name) with .env"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uploadExistingProject(name: String, projectPath: String, variables: [EnvVariable]) async {
        guard let service else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Project name is required."
            return
        }
        guard !trimmedPath.isEmpty else {
            errorMessage = "Project path is required."
            return
        }

        do {
            let expandedPath = NSString(string: trimmedPath).expandingTildeInPath
            let vault = try await service.upsertVault(name: trimmedName, projectPath: expandedPath)
            if !variables.isEmpty {
                try await service.importVariables(variables, vaultID: vault.id)
            }
            state = await service.snapshot()
            duplicateHints = await service.duplicateHints()
            selectedVaultID = vault.id
            selectedVariableID = state.vaults.first { $0.id == vault.id }?.variables.first?.id
            status = variables.isEmpty ? "Uploaded \(vault.name)" : "Uploaded \(variables.count) variables"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uploadDetectedDotenvFiles(name: String, projectPath: String, files: [DetectedDotenvFile]) async {
        guard let service else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Project name is required."
            return
        }
        guard !trimmedPath.isEmpty else {
            errorMessage = "Project path is required."
            return
        }

        do {
            if files.isEmpty {
                _ = try await service.upsertVault(name: trimmedName, projectPath: NSString(string: trimmedPath).expandingTildeInPath)
            } else {
                try await service.importDetectedDotenvFiles(files, rootName: trimmedName)
            }
            state = await service.snapshot()
            duplicateHints = await service.duplicateHints()
            selectedVaultID = state.vaults.first?.id
            selectedVariableID = selectedVault?.variables.first?.id
            status = files.isEmpty ? "Uploaded \(trimmedName)" : "Imported \(files.flatMap(\.variables).count) variables from \(files.count) files"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func detectDotenvFiles(projectPath: String) -> [DetectedDotenvFile] {
        do {
            return try DotenvCodec.scanFilesRecursively(inDirectory: projectPath)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func unlock() async -> Bool {
        guard let service else { return false }
        do {
            try await service.unlock()
            status = "Unlocked with device authentication"
            return true
        } catch {
            errorMessage = error.localizedDescription
            status = "Locked"
            return false
        }
    }

    func setVariable(key: String, value: String, scope: String) async {
        guard let service, let vault = selectedVault else { return }
        do {
            try await service.setVariable(vaultID: vault.id, key: key, value: value, scope: scope)
            state = await service.snapshot()
            duplicateHints = await service.duplicateHints()
            selectedVariableID = state.vaults.first { $0.id == vault.id }?.variables.first { $0.key == key }?.id
            status = "Saved \(key)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSelectedVariable(key: String, value: String, scope: String) async {
        guard let service, let vault = selectedVault, let variableID = selectedVariableID else { return }
        do {
            try await service.updateVariable(vaultID: vault.id, variableID: variableID, key: key, value: value, scope: scope)
            state = await service.snapshot()
            duplicateHints = await service.duplicateHints()
            selectedVariableID = variableID
            status = "Updated \(key)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importDotenv(url: URL) async {
        guard let service, let vault = selectedVault else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            try await service.importDotenv(text, vaultID: vault.id)
            state = await service.snapshot()
            duplicateHints = await service.duplicateHints()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportDotenv() async {
        guard let service, let vault = selectedVault else { return }
        do {
            let text = try await service.exportDotenv(vaultID: vault.id)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            status = "Copied .env export to clipboard"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectVariable(_ variable: EnvVariable) {
        selectedVariableID = variable.id
    }

    func copyToClipboard(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied \(label) to clipboard"
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("hasSeenWelcomeTutorial") private var hasSeenWelcomeTutorial = false
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var newScope = "project"
    @State private var hoveredVariableID: EnvVariable.ID?
    @State private var hoveredDetailRow: String?
    @State private var editKey = ""
    @State private var editValue = ""
    @State private var editScope = ""
    @State private var isUnlocked = false
    @State private var isUnlocking = false
    @State private var showInspector = true
    @State private var showEditControls = false
    @State private var showTutorial = false
    @State private var showNewProjectCreator = false
    @State private var showExistingProjectUpload = false
    @State private var newProjectName = ""
    @State private var newProjectParentPath = ""
    @State private var existingProjectName = ""
    @State private var existingProjectPath = ""
    @State private var detectedUploadFiles: [DetectedDotenvFile] = []
    @State private var uploadAllVariables = true
    @State private var selectedUploadVariableIDs = Set<UploadVariableChoice.ID>()

    var body: some View {
        ZStack {
            NavigationSplitView {
                vaultList
            } detail: {
                mainWorkspace
                .navigationTitle(model.selectedVault?.name ?? "No Vault")
            }
            .disabled(!isUnlocked)
            .blur(radius: isUnlocked ? 0 : 10)

            if !isUnlocked {
                unlockGate
            }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .fileImporter(isPresented: $model.presentImporter, allowedContentTypes: [.plainText, .text]) { result in
            if case .success(let url) = result {
                Task { await model.importDotenv(url: url) }
            }
        }
        .alert("Personal Env", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $showTutorial, onDismiss: { hasSeenWelcomeTutorial = true }) {
            WelcomeTutorialView()
                .frame(width: 560, height: 520)
        }
        .sheet(isPresented: $showNewProjectCreator) {
            CreateProjectView(
                projectName: $newProjectName,
                parentPath: $newProjectParentPath,
                onCancel: {
                    showNewProjectCreator = false
                },
                onCreate: {
                    let name = newProjectName
                    let parentPath = newProjectParentPath
                    showNewProjectCreator = false
                    Task { await model.createNewProject(name: name, parentDirectory: parentPath) }
                },
                onChooseFolder: chooseNewProjectParentFolder
            )
            .frame(width: 520, height: 330)
        }
        .sheet(isPresented: $showExistingProjectUpload) {
            UploadExistingProjectView(
                projectName: $existingProjectName,
                projectPath: $existingProjectPath,
                detectedFiles: $detectedUploadFiles,
                uploadAllVariables: $uploadAllVariables,
                selectedVariableIDs: $selectedUploadVariableIDs,
                onCancel: {
                    showExistingProjectUpload = false
                },
                onUpload: uploadExistingProject,
                onChooseFolder: chooseExistingProjectFolder,
                onScan: refreshExistingProjectDetection
            )
            .frame(width: 620, height: 560)
        }
        .onAppear {
            syncEditor()
            showTutorial = !hasSeenWelcomeTutorial
            Task { await unlockFromLaunch() }
        }
        .onChange(of: model.selectedVariableID) {
            syncEditor()
        }
        .onChange(of: model.state) {
            syncEditor()
        }
    }

    private var mainWorkspace: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                variableTable
                Divider()
                if showEditControls {
                    addVariableBar
                } else {
                    editModePrompt
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)

            Divider()

            if showInspector {
                inspector
            } else {
                collapsedInspector
            }
        }
    }

    private var vaultList: some View {
        List(selection: $model.selectedVaultID) {
            Section("Vaults") {
                ForEach(model.state.vaults) { vault in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(vault.name, systemImage: "lock.shield")
                            .font(.headline)
                        Text(vault.projectPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 8)
                    .tag(vault.id)
                }
            }
        }
        .navigationTitle("Personal Env")
        .frame(minWidth: 260)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    prepareNewProjectCreator()
                    showNewProjectCreator = true
                } label: {
                    Label("Create New Project", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)

                Button {
                    prepareExistingProjectUpload()
                    showExistingProjectUpload = true
                } label: {
                    Label("Upload Existing Project", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            }
            .padding()
        }
        .onChange(of: model.selectedVaultID) {
            model.selectedVariableID = model.selectedVault?.variables.first?.id
            syncEditor()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button {
                model.presentImporter = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            Button {
                Task { await model.exportDotenv() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            Spacer()
            Button {
                syncEditor()
                showEditControls = true
                showInspector = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(model.selectedVariable == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var variableTable: some View {
        Table(model.selectedVault?.variables ?? [], selection: $model.selectedVariableID) {
            TableColumn("Key") { variable in
                Text(variable.key)
                    .font(.system(.body, design: .monospaced))
            }
            TableColumn("Value") { variable in
                Button {
                    model.selectVariable(variable)
                    model.copyToClipboard(variable.value, label: variable.key)
                } label: {
                    HStack(spacing: 8) {
                        Text(mask(variable.value))
                            .font(.system(.body, design: .monospaced))
                        if hoveredVariableID == variable.id {
                            Image(systemName: "doc.on.doc")
                            Text("Click to copy value")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .foregroundStyle(hoveredVariableID == variable.id ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredVariableID = hovering ? variable.id : nil
                }
            }
            TableColumn("Scope") { variable in
                Text(variable.scope)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.12), in: Capsule())
            }
            TableColumn("Updated") { variable in
                Text(variable.updatedAt, style: .relative)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.selectedVariableID) {
            syncEditor()
        }
    }

    private var editModePrompt: some View {
        HStack {
            Spacer()
            Button {
                showEditControls = true
                showInspector = true
            } label: {
                Label("Edit Vault", systemImage: "slider.horizontal.3")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(12)
        }
        .background(.thinMaterial)
    }

    private var addVariableBar: some View {
        HStack(spacing: 8) {
            TextField("KEY", text: $newKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            SecureField("value", text: $newValue)
                .textFieldStyle(.roundedBorder)
            TextField("scope", text: $newScope)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            Button {
                let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = newValue
                let scope = newScope.trimmingCharacters(in: .whitespacesAndNewlines)
                newKey = ""
                newValue = ""
                Task { await model.setVariable(key: key, value: value, scope: scope.isEmpty ? "project" : scope) }
            } label: {
                Label("Save", systemImage: "key.fill")
            }
            .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button {
                showEditControls = false
            } label: {
                Label("Done", systemImage: "checkmark.circle")
            }
        }
        .padding(12)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectorHeader
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let variable = model.selectedVariable {
                        selectedVariableInspector(variable)
                    } else {
                        projectInspectorEmptyState
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 360)
    }

    private var inspectorHeader: some View {
        HStack {
            Label(model.status, systemImage: "lock.open.rotation")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button {
                showInspector = false
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help("Collapse inspector")
        }
    }

    private func selectedVariableInspector(_ variable: EnvVariable) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.gray.opacity(0.55))
                    .frame(width: 76, height: 76)
                    .overlay {
                        Text(String(variable.key.prefix(1)))
                            .font(.system(size: 46, weight: .regular))
                            .foregroundStyle(.white)
                    }
                Text(variable.key)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 0) {
                detailRow("Key", value: variable.key, hoverText: "Click to copy key name") {
                    model.copyToClipboard(variable.key, label: "key")
                }
                Divider()
                detailRow("Value", value: mask(variable.value), hoverText: "Click to copy value") {
                    model.copyToClipboard(variable.value, label: variable.key)
                }
                Divider()
                detailRow("Scope", value: variable.scope)
                Divider()
                detailRow("Modified", value: variable.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if showEditControls {
                editVariableBox
            } else {
                Button {
                    showEditControls = true
                } label: {
                    Label("Edit Key", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    private var projectInspectorEmptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let vault = model.selectedVault {
                VStack(alignment: .leading, spacing: 8) {
                    Label(vault.name, systemImage: "folder")
                        .font(.title3.bold())
                    Text(vault.projectPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                VStack(spacing: 0) {
                    detailRow("Variables", value: "\(vault.variables.count)")
                    Divider()
                    detailRow("Tracked uses", value: "\(model.state.projectSecretUses.filter { $0.projectPath == vault.projectPath }.count)")
                    Divider()
                    detailRow("Duplicate hints", value: "\(model.duplicateHints.count)")
                    Divider()
                    detailRow("Modified", value: vault.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button {
                    showEditControls = true
                    showInspector = true
                } label: {
                    Label("Add Key", systemImage: "key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                ContentUnavailableView {
                    Label("No Project Selected", systemImage: "folder")
                } description: {
                    Text("Create or upload a project from the sidebar.")
                }
            }
        }
    }

    private var editVariableBox: some View {
        GroupBox("Edit") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("KEY", text: $editKey)
                    .font(.system(.body, design: .monospaced))
                SecureField("value", text: $editValue)
                TextField("scope", text: $editScope)
                HStack {
                    Button {
                        syncEditor()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    Spacer()
                    Button {
                        let key = editKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        let scope = editScope.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await model.updateSelectedVariable(key: key, value: editValue, scope: scope.isEmpty ? "project" : scope) }
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .disabled(editKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var collapsedInspector: some View {
        VStack {
            Button {
                showInspector = true
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Show inspector")
            Spacer()
        }
        .padding(12)
        .frame(width: 54)
    }

    private var unlockGate: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.teal)
            VStack(spacing: 8) {
                Text("Unlock Personal Env")
                    .font(.largeTitle.weight(.bold))
                Text("Use your device passkey or password to access secure vault items.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await unlockFromLaunch() }
            } label: {
                Label(isUnlocking ? "Waiting for Authentication" : "Unlock Secure Vault", systemImage: "touchid")
                    .frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.teal)
            .disabled(isUnlocking)
        }
        .padding(34)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(radius: 24, y: 18)
    }

    private func detailRow(_ title: String, value: String, hoverText: String? = nil, action: (() -> Void)? = nil) -> some View {
        let isHovered = hoveredDetailRow == title
        return Button {
            action?()
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(isHovered && action != nil ? (hoverText ?? "Click to copy") : value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                if action != nil {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .onHover { hovering in
            hoveredDetailRow = hovering ? title : nil
        }
    }

    private func mask(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        return String(repeating: "•", count: min(max(value.count, 8), 18))
    }

    private func syncEditor() {
        guard let variable = model.selectedVariable else {
            editKey = ""
            editValue = ""
            editScope = ""
            return
        }
        editKey = variable.key
        editValue = variable.value
        editScope = variable.scope
    }

    private func prepareNewProjectCreator() {
        newProjectName = ""
        let documents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        newProjectParentPath = FileManager.default.fileExists(atPath: documents.path) ? documents.path : FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func prepareExistingProjectUpload() {
        existingProjectName = ""
        existingProjectPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code").path
        detectedUploadFiles = []
        uploadAllVariables = true
        selectedUploadVariableIDs = []
    }

    private func chooseNewProjectParentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSString(string: newProjectParentPath).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            newProjectParentPath = url.path
        }
    }

    private func chooseExistingProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSString(string: existingProjectPath).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            existingProjectPath = url.path
            if existingProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existingProjectName = url.lastPathComponent
            }
            refreshExistingProjectDetection()
        }
    }

    private func refreshExistingProjectDetection() {
        detectedUploadFiles = model.detectDotenvFiles(projectPath: existingProjectPath)
        let choices = UploadVariableChoice.make(from: detectedUploadFiles)
        selectedUploadVariableIDs = Set(choices.map(\.id))
        uploadAllVariables = true
    }

    private func uploadExistingProject() {
        let selectedFiles = selectedDetectedFiles()
        let name = existingProjectName
        let path = existingProjectPath
        showExistingProjectUpload = false
        Task { await model.uploadDetectedDotenvFiles(name: name, projectPath: path, files: selectedFiles) }
    }

    private func selectedDetectedFiles() -> [DetectedDotenvFile] {
        guard !uploadAllVariables else { return detectedUploadFiles }
        return detectedUploadFiles.compactMap { file in
            let variables = file.variables.filter { variable in
                selectedUploadVariableIDs.contains(UploadVariableChoice.id(filePath: file.path, variableID: variable.id))
            }
            guard !variables.isEmpty else { return nil }
            return DetectedDotenvFile(fileName: file.fileName, path: file.path, projectPath: file.projectPath, variables: variables)
        }
    }

    private func unlockFromLaunch() async {
        guard !isUnlocked, !isUnlocking else { return }
        isUnlocking = true
        var unlocked = await model.unlock()
        if !unlocked, model.errorMessage == nil {
            try? await Task.sleep(for: .milliseconds(250))
            unlocked = await model.unlock()
        }
        isUnlocking = false
        if unlocked {
            isUnlocked = true
        }
    }
}

struct WelcomeTutorialView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Label("Personal Env", systemImage: "lock.shield")
                    .font(.title.bold())
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Text("A quick start for managing shared environment keys without scattering secrets across projects.")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                TutorialStep(icon: "folder.badge.plus", title: "Create projects", text: "Add a project vault for each codebase that needs a clean set of environment variables.")
                TutorialStep(icon: "key.fill", title: "Add shared API keys", text: "Use Edit Vault to reveal the key fields, then save scoped values for services like AI, email, storage, or payments.")
                TutorialStep(icon: "pencil.and.scribble", title: "Modify keys deliberately", text: "Select a key, press Edit, update the right inspector, and authenticate before changes are stored.")
            }

            Spacer()
        }
        .padding(30)
        .background(.thinMaterial)
    }
}

struct CreateProjectView: View {
    @Binding var projectName: String
    @Binding var parentPath: String
    let onCancel: () -> Void
    let onCreate: () -> Void
    let onChooseFolder: () -> Void

    private var canCreate: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !parentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("Create New Project", systemImage: "folder.badge.plus")
                    .font(.title2.bold())
                Spacer()
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Project name", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Parent folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Parent folder", text: $parentPath)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            onChooseFolder()
                        } label: {
                            Label("Choose", systemImage: "folder")
                        }
                    }
                }
            }

            Spacer()

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button {
                    onCreate()
                } label: {
                    Label("Create Folder", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
        }
        .padding(28)
    }
}

private struct UploadVariableChoice: Identifiable, Hashable {
    let id: String
    let fileName: String
    let projectPath: String
    let key: String
    let scope: String

    static func make(from files: [DetectedDotenvFile]) -> [UploadVariableChoice] {
        files.flatMap { file in
            file.variables.map { variable in
                UploadVariableChoice(
                    id: id(filePath: file.path, variableID: variable.id),
                    fileName: file.fileName,
                    projectPath: file.projectPath,
                    key: variable.key,
                    scope: variable.scope
                )
            }
        }
    }

    static func id(filePath: String, variableID: EnvVariable.ID) -> String {
        "\(filePath)::\(variableID.uuidString)"
    }
}

private struct UploadExistingProjectView: View {
    @Binding var projectName: String
    @Binding var projectPath: String
    @Binding var detectedFiles: [DetectedDotenvFile]
    @Binding var uploadAllVariables: Bool
    @Binding var selectedVariableIDs: Set<UploadVariableChoice.ID>
    let onCancel: () -> Void
    let onUpload: () -> Void
    let onChooseFolder: () -> Void
    let onScan: () -> Void

    private var choices: [UploadVariableChoice] {
        UploadVariableChoice.make(from: detectedFiles)
    }

    private var selectedCount: Int {
        uploadAllVariables ? choices.count : choices.filter { selectedVariableIDs.contains($0.id) }.count
    }

    private var canUpload: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Upload Existing Project", systemImage: "tray.and.arrow.down")
                    .font(.title2.bold())
                Spacer()
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Project name", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Existing project folder", text: $projectPath)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            onChooseFolder()
                        } label: {
                            Label("Choose", systemImage: "folder")
                        }
                        Button {
                            onScan()
                        } label: {
                            Label("Scan", systemImage: "magnifyingglass")
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Detected dotenv files", systemImage: "doc.text.magnifyingglass")
                        .font(.headline)
                    Spacer()
                    Text("\(selectedCount) selected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("Recursive scan is blocked for broad Mac folders like Home, Desktop, Documents, Downloads, Applications, and system roots. Choose a specific workspace or project folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if choices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No .env or .env.local variables found.")
                            .font(.headline)
                        Text("Upload will still create a vault for this folder.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Toggle("Add all variables from .env and .env.local", isOn: $uploadAllVariables)
                        .toggleStyle(.checkbox)

                    if !uploadAllVariables {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(choices) { choice in
                                    Toggle(isOn: Binding(
                                        get: { selectedVariableIDs.contains(choice.id) },
                                        set: { isSelected in
                                            if isSelected {
                                                selectedVariableIDs.insert(choice.id)
                                            } else {
                                                selectedVariableIDs.remove(choice.id)
                                            }
                                        }
                                    )) {
                                        HStack(spacing: 10) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(choice.key)
                                                    .font(.system(.body, design: .monospaced))
                                                Text(choice.projectPath)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Text(choice.fileName)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(.quaternary, in: Capsule())
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(12)
                        }
                        .frame(maxHeight: 190)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }

            Spacer()

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button {
                    onUpload()
                } label: {
                    Label("Upload", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canUpload)
            }
        }
        .padding(28)
    }
}

struct TutorialStep: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.teal)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
