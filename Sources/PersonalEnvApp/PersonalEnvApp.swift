import SwiftUI
import AppKit

#if canImport(PersonalEnvCore)
import PersonalEnvCore
#endif

private enum EnvTheme {
    static let accent = Color.adaptive(
        light: NSColor(red: 0.16, green: 0.40, blue: 0.93, alpha: 1),
        dark: NSColor(red: 0.42, green: 0.63, blue: 1.00, alpha: 1)
    )
    static let accentSoft = Color.adaptive(
        light: NSColor(red: 0.90, green: 0.94, blue: 1.00, alpha: 1),
        dark: NSColor(red: 0.11, green: 0.18, blue: 0.32, alpha: 1)
    )
    static let canvas = Color.adaptive(
        light: NSColor(red: 0.985, green: 0.985, blue: 0.982, alpha: 1),
        dark: NSColor(red: 0.075, green: 0.080, blue: 0.088, alpha: 1)
    )
    static let panel = Color.adaptive(
        light: NSColor(red: 0.997, green: 0.997, blue: 0.995, alpha: 1),
        dark: NSColor(red: 0.105, green: 0.112, blue: 0.122, alpha: 1)
    )
    static let sidebar = Color.adaptive(
        light: NSColor(red: 0.970, green: 0.970, blue: 0.968, alpha: 1),
        dark: NSColor(red: 0.120, green: 0.126, blue: 0.136, alpha: 1)
    )
    static let separator = Color.adaptive(
        light: NSColor(red: 0.840, green: 0.840, blue: 0.835, alpha: 1),
        dark: NSColor(red: 0.265, green: 0.280, blue: 0.300, alpha: 1)
    )
    static let ink = Color.adaptive(
        light: NSColor(red: 0.12, green: 0.115, blue: 0.10, alpha: 1),
        dark: NSColor(red: 0.93, green: 0.95, blue: 0.94, alpha: 1)
    )
    static let muted = Color.adaptive(
        light: NSColor(red: 0.42, green: 0.42, blue: 0.45, alpha: 1),
        dark: NSColor(red: 0.66, green: 0.70, blue: 0.68, alpha: 1)
    )
    static let tableFill = Color.adaptive(
        light: NSColor(red: 0.997, green: 0.997, blue: 0.995, alpha: 1),
        dark: NSColor(red: 0.085, green: 0.105, blue: 0.105, alpha: 1)
    )
    static let green = Color.adaptive(
        light: NSColor(red: 0.18, green: 0.64, blue: 0.37, alpha: 1),
        dark: NSColor(red: 0.39, green: 0.86, blue: 0.57, alpha: 1)
    )
    static let orange = Color.adaptive(
        light: NSColor(red: 0.96, green: 0.47, blue: 0.10, alpha: 1),
        dark: NSColor(red: 1.00, green: 0.64, blue: 0.28, alpha: 1)
    )
    static let red = Color.adaptive(
        light: NSColor(red: 0.82, green: 0.20, blue: 0.22, alpha: 1),
        dark: NSColor(red: 1.00, green: 0.44, blue: 0.46, alpha: 1)
    )
}

private extension Color {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
            return bestMatch == .darkAqua ? dark : light
        })
    }
}

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

    func renameVault(_ vault: EnvVault, name: String) async {
        guard let service else { return }
        do {
            let renamedVault = try await service.renameVault(vaultID: vault.id, name: name)
            state = await service.snapshot()
            duplicateHints = await service.duplicateHints()
            selectedVaultID = renamedVault.id
            status = "Renamed vault to \(renamedVault.name)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteVault(_ vault: EnvVault) async {
        guard let service else { return }
        do {
            try await service.deleteVault(vaultID: vault.id)
            state = await service.snapshot()
            duplicateHints = await service.duplicateHints()
            if selectedVaultID == vault.id {
                selectedVaultID = state.vaults.first?.id
                selectedVariableID = selectedVault?.variables.first?.id
            }
            status = "Deleted \(vault.name) from Personal Env"
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
    @State private var vaultSearchText = ""
    @State private var variableSearchText = ""
    @State private var showNewProjectCreator = false
    @State private var showExistingProjectUpload = false
    @State private var newProjectName = ""
    @State private var newProjectParentPath = ""
    @State private var existingProjectName = ""
    @State private var existingProjectPath = ""
    @State private var detectedUploadFiles: [DetectedDotenvFile] = []
    @State private var uploadAllVariables = true
    @State private var selectedUploadVariableIDs = Set<UploadVariableChoice.ID>()
    @State private var vaultToRename: EnvVault?
    @State private var vaultRenameName = ""
    @State private var vaultToDelete: EnvVault?

    var body: some View {
        ZStack {
            EnvTheme.canvas.ignoresSafeArea()
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
        .alert("Rename Vault", isPresented: Binding(get: { vaultToRename != nil }, set: { if !$0 { vaultToRename = nil } })) {
            TextField("Vault name", text: $vaultRenameName)
            Button("Cancel", role: .cancel) {
                vaultToRename = nil
            }
            Button("Rename") {
                guard let vault = vaultToRename else { return }
                let name = vaultRenameName
                vaultToRename = nil
                Task { await model.renameVault(vault, name: name) }
            }
            .disabled(vaultRenameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Change the display name shown in Personal Env. This does not rename the project folder.")
        }
        .confirmationDialog("Delete Vault", isPresented: Binding(get: { vaultToDelete != nil }, set: { if !$0 { vaultToDelete = nil } })) {
            Button("Delete from Personal Env", role: .destructive) {
                guard let vault = vaultToDelete else { return }
                vaultToDelete = nil
                Task { await model.deleteVault(vault) }
            }
            Button("Cancel", role: .cancel) {
                vaultToDelete = nil
            }
        } message: {
            Text("This removes the vault from your Personal Env config. It does not delete the project folder or dotenv file.")
        }
        .tint(EnvTheme.accent)
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
                appToolbar
                EnvDivider(.horizontal)
                toolbar
                EnvDivider(.horizontal)
                variableTable
                EnvDivider(.horizontal)
                if showEditControls {
                    addVariableBar
                } else {
                    editModePrompt
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .background(EnvTheme.panel)

            EnvDivider(.vertical)

            if showInspector {
                inspector
            } else {
                collapsedInspector
            }
        }
    }

    private var vaultList: some View {
        List(selection: $model.selectedVaultID) {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(EnvTheme.muted)
                    TextField("Search vaults...", text: $vaultSearchText)
                        .textFieldStyle(.plain)
                    Text("⌘F")
                        .font(.caption)
                        .foregroundStyle(EnvTheme.muted.opacity(0.65))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(EnvTheme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(EnvTheme.separator.opacity(0.7), lineWidth: 1)
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14))
            }

            Section("Vaults") {
                ForEach(filteredVaults) { vault in
                    HStack(spacing: 12) {
                        vaultIcon(for: vault)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(vault.name)
                                .font(.headline)
                                .foregroundStyle(EnvTheme.ink)
                                .lineLimit(1)
                            Text(vault.projectPath)
                                .font(.caption)
                                .foregroundStyle(EnvTheme.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if model.selectedVaultID == vault.id {
                            Image(systemName: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(EnvTheme.accent)
                        }
                    }
                    .padding(.vertical, 8)
                    .tag(vault.id)
                    .contextMenu {
                        Button {
                            model.selectedVaultID = vault.id
                            vaultRenameName = vault.name
                            vaultToRename = vault
                        } label: {
                            Label("Rename Vault", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            model.selectedVaultID = vault.id
                            vaultToDelete = vault
                        } label: {
                            Label("Delete from Personal Env", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Personal Env")
        .frame(minWidth: 260)
        .scrollContentBackground(.hidden)
        .background(EnvTheme.sidebar)
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
            .background(EnvTheme.sidebar)
        }
        .onChange(of: model.selectedVaultID) {
            model.selectedVariableID = model.selectedVault?.variables.first?.id
            syncEditor()
        }
    }

    private var filteredVaults: [EnvVault] {
        let query = vaultSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.state.vaults }
        return model.state.vaults.filter {
            $0.name.lowercased().contains(query) || $0.projectPath.lowercased().contains(query)
        }
    }

    private var filteredVariables: [EnvVariable] {
        let variables = model.selectedVault?.variables ?? []
        let query = variableSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return variables }
        return variables.filter {
            $0.key.lowercased().contains(query) || $0.scope.lowercased().contains(query)
        }
    }

    private var appToolbar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await unlockFromLaunch() }
            } label: {
                Label(isUnlocked ? "Lock" : "Unlock", systemImage: isUnlocked ? "lock.open.fill" : "lock.fill")
            }
            .buttonStyle(.bordered)
            .disabled(isUnlocking)

            Button {
                model.presentImporter = true
            } label: {
                Label("Import .env", systemImage: "arrow.down.to.line")
            }

            Button {
                Task { await model.exportDotenv() }
            } label: {
                Label("Export", systemImage: "arrow.up.to.line")
            }

            Button {
                model.copyToClipboard(model.selectedVault?.projectPath ?? "", label: "project path")
            } label: {
                Label("Share", systemImage: "person.2")
            }
            .disabled(model.selectedVault == nil)

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(EnvTheme.green)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text("API Server")
                        .font(.headline)
                        .foregroundStyle(EnvTheme.ink)
                    Text("Running on 127.0.0.1:51234")
                        .font(.caption)
                        .foregroundStyle(EnvTheme.muted)
                }
            }

            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
            .help("Toggle inspector")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(EnvTheme.panel)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectedVault?.name ?? "No project")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(EnvTheme.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(model.selectedVault?.projectPath ?? "Create or upload a vault")
                        .font(.caption)
                        .foregroundStyle(EnvTheme.muted)
                        .lineLimit(1)
                    if model.selectedVault != nil {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(EnvTheme.muted)
                    }
                }
            }
            .frame(minWidth: 180, alignment: .leading)
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(EnvTheme.muted)
                TextField("Filter variables...", text: $variableSearchText)
                    .textFieldStyle(.plain)
                Text("⌘L")
                    .font(.caption)
                    .foregroundStyle(EnvTheme.muted.opacity(0.65))
            }
            .frame(width: 260)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(EnvTheme.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(EnvTheme.separator.opacity(0.7), lineWidth: 1)
            )
            Button {
                showEditControls = true
                showInspector = true
            } label: {
                Image(systemName: "plus")
            }
            .help("Add variable")
            Button {
                syncEditor()
                showEditControls = true
                showInspector = true
            } label: {
                Image(systemName: "ellipsis")
            }
            .help("Edit selected variable")
            .disabled(model.selectedVariable == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(EnvTheme.panel)
    }

    private var variableTable: some View {
        Table(filteredVariables, selection: $model.selectedVariableID) {
            TableColumn("Key") { variable in
                HStack(spacing: 10) {
                    Image(systemName: "key")
                        .font(.caption)
                        .foregroundStyle(EnvTheme.muted)
                    Text(variable.key)
                        .font(.system(.body, design: .monospaced))
                }
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
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(scopeColor(variable.scope))
                    .background(scopeColor(variable.scope).opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            TableColumn("Updated") { variable in
                Text(variable.updatedAt, style: .relative)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.selectedVariableID) {
            syncEditor()
        }
        .scrollContentBackground(.hidden)
        .background(EnvTheme.tableFill)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 28) {
                Text("\(filteredVariables.count) variables")
                    .foregroundStyle(EnvTheme.muted)
                Spacer()
                scopeLegend("Production", color: EnvTheme.red)
                scopeLegend("Staging", color: EnvTheme.orange)
                scopeLegend("Development", color: EnvTheme.accent)
                scopeLegend("Local", color: EnvTheme.green)
            }
            .font(.caption)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(EnvTheme.panel)
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
        .background(EnvTheme.canvas)
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
        .background(EnvTheme.canvas)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    securityPanel
                    EnvDivider(.horizontal)
                    storagePanel
                    EnvDivider(.horizontal)
                    activityLogPanel
                    if showEditControls || model.selectedVariable != nil {
                        EnvDivider(.horizontal)
                        selectedVariablePanel
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 360)
        .background(EnvTheme.canvas)
    }

    private var inspectorHeader: some View {
        HStack {
            Label(model.status, systemImage: "lock.open.rotation")
                .font(.headline)
                .foregroundStyle(EnvTheme.ink)
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

    private var securityPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Unlock & Security")
                .font(.headline)
                .foregroundStyle(EnvTheme.ink)
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(EnvTheme.green, lineWidth: 2)
                        .frame(width: 58, height: 58)
                    Image(systemName: "lock.open.fill")
                        .font(.title2)
                        .foregroundStyle(EnvTheme.green)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(isUnlocked ? "Unlocked" : "Locked")
                        .font(.headline)
                        .foregroundStyle(EnvTheme.ink)
                    Text(isUnlocked ? "via Touch ID" : "Awaiting authentication")
                        .foregroundStyle(EnvTheme.muted)
                    Text(isUnlocked ? "Unlocked just now" : "Vault access paused")
                        .font(.caption)
                        .foregroundStyle(EnvTheme.muted)
                }
                Spacer()
                Button("Lock Now") {
                    isUnlocked = false
                }
                .disabled(!isUnlocked)
            }
        }
        .padding(18)
    }

    private var storagePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Storage")
                .font(.headline)
                .foregroundStyle(EnvTheme.ink)
            HStack(spacing: 12) {
                Image(systemName: "keychain")
                    .font(.title2)
                    .foregroundStyle(EnvTheme.ink)
                    .frame(width: 38, height: 38)
                    .background(EnvTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("macOS Keychain")
                        .font(.headline)
                        .foregroundStyle(EnvTheme.ink)
                    Text("Securely stored in your keychain")
                        .font(.caption)
                        .foregroundStyle(EnvTheme.muted)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(EnvTheme.green)
            }
        }
        .padding(18)
    }

    private var activityLogPanel: some View {
        HStack {
            Label("Activity Log", systemImage: "clock")
                .font(.headline)
                .foregroundStyle(EnvTheme.ink)
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(EnvTheme.muted)
        }
        .padding(18)
    }

    private var selectedVariablePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let variable = model.selectedVariable {
                selectedVariableInspector(variable)
            } else {
                projectInspectorEmptyState
            }
        }
        .padding(18)
    }

    private func selectedVariableInspector(_ variable: EnvVariable) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(EnvTheme.accentSoft)
                    .frame(width: 76, height: 76)
                    .overlay {
                        Text(String(variable.key.prefix(1)))
                            .font(.system(size: 42, weight: .semibold, design: .monospaced))
                            .foregroundStyle(EnvTheme.accent)
                    }
                Text(variable.key)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(EnvTheme.ink)
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
            .background(EnvTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(EnvTheme.separator.opacity(0.55), lineWidth: 1)
            )

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
                        .foregroundStyle(EnvTheme.ink)
                    Text(vault.projectPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(EnvTheme.muted)
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
                .background(EnvTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(EnvTheme.separator.opacity(0.55), lineWidth: 1)
                )

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
        .foregroundStyle(EnvTheme.ink)
        .background(EnvTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .background(EnvTheme.canvas)
    }

    private var unlockGate: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(EnvTheme.accent)
            VStack(spacing: 8) {
                Text("Unlock Personal Env")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(EnvTheme.ink)
                Text("Use your device passkey or password to access secure vault items.")
                    .font(.body)
                    .foregroundStyle(EnvTheme.muted)
            }
            Button {
                Task { await unlockFromLaunch() }
            } label: {
                Label(isUnlocking ? "Waiting for Authentication" : "Unlock Secure Vault", systemImage: "touchid")
                    .frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(EnvTheme.accent)
            .disabled(isUnlocking)
        }
        .padding(34)
        .background(EnvTheme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(EnvTheme.separator.opacity(0.65), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 28, y: 18)
    }

    private func vaultIcon(for vault: EnvVault) -> some View {
        let symbol: String
        let color: Color
        let lowerName = vault.name.lowercased()
        if lowerName.contains("mobile") || lowerName.contains("ios") {
            symbol = "iphone"
            color = EnvTheme.ink
        } else if lowerName.contains("api") || lowerName.contains("backend") {
            symbol = "curlybraces"
            color = EnvTheme.green
        } else if lowerName.contains("infra") || lowerName.contains("cloud") {
            symbol = "icloud"
            color = Color.purple
        } else if lowerName.contains("marketing") || lowerName.contains("site") {
            symbol = "display"
            color = EnvTheme.orange
        } else if lowerName.contains("data") {
            symbol = "cylinder.split.1x2"
            color = EnvTheme.accent
        } else {
            symbol = "globe"
            color = EnvTheme.accent
        }

        return Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func scopeColor(_ scope: String) -> Color {
        switch scope.lowercased() {
        case "production", "prod":
            return EnvTheme.red
        case "staging", "stage":
            return EnvTheme.orange
        case "development", "dev", "project":
            return EnvTheme.accent
        case "local":
            return EnvTheme.green
        default:
            return EnvTheme.muted
        }
    }

    private func scopeLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(EnvTheme.muted)
        }
    }

    private func detailRow(_ title: String, value: String, hoverText: String? = nil, action: (() -> Void)? = nil) -> some View {
        let isHovered = hoveredDetailRow == title
        return Button {
            action?()
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(EnvTheme.ink)
                Spacer()
                Text(isHovered && action != nil ? (hoverText ?? "Click to copy") : value)
                    .foregroundStyle(action != nil && isHovered ? EnvTheme.accent : EnvTheme.muted)
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                if action != nil {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(EnvTheme.accent)
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
                    .foregroundStyle(EnvTheme.ink)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Text("A quick start for managing shared environment keys without scattering secrets across projects.")
                .font(.title3)
                .foregroundStyle(EnvTheme.muted)

            VStack(alignment: .leading, spacing: 16) {
                TutorialStep(icon: "folder.badge.plus", title: "Create projects", text: "Add a project vault for each codebase that needs a clean set of environment variables.")
                TutorialStep(icon: "key.fill", title: "Add shared API keys", text: "Use Edit Vault to reveal the key fields, then save scoped values for services like AI, email, storage, or payments.")
                TutorialStep(icon: "pencil.and.scribble", title: "Modify keys deliberately", text: "Select a key, press Edit, update the right inspector, and authenticate before changes are stored.")
            }

            Spacer()
        }
        .padding(30)
        .background(EnvTheme.canvas)
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
                    .foregroundStyle(EnvTheme.ink)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(EnvTheme.muted)
                    TextField("Project name", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Parent folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(EnvTheme.muted)
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
        .background(EnvTheme.canvas)
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
                    .foregroundStyle(EnvTheme.ink)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(EnvTheme.muted)
                    TextField("Project name", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(EnvTheme.muted)
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
                        .foregroundStyle(EnvTheme.ink)
                    Spacer()
                    Text("\(selectedCount) selected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(EnvTheme.muted)
                }
                Text("Recursive scan is blocked for broad Mac folders like Home, Desktop, Documents, Downloads, Applications, and system roots. Choose a specific workspace or project folder.")
                    .font(.caption)
                    .foregroundStyle(EnvTheme.muted)

                if choices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No .env or .env.local variables found.")
                            .font(.headline)
                            .foregroundStyle(EnvTheme.ink)
                        Text("Upload will still create a vault for this folder.")
                            .foregroundStyle(EnvTheme.muted)
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
                                                    .foregroundStyle(EnvTheme.muted)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Text(choice.fileName)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(EnvTheme.muted)
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
        .background(EnvTheme.canvas)
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
                .foregroundStyle(EnvTheme.accent)
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
        .background(EnvTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(EnvTheme.separator.opacity(0.55), lineWidth: 1)
        )
    }
}

private struct EnvDivider: View {
    enum Axis {
        case horizontal
        case vertical
    }

    let axis: Axis

    init(_ axis: Axis) {
        self.axis = axis
    }

    var body: some View {
        Rectangle()
            .fill(EnvTheme.separator.opacity(0.5))
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
    }
}
