import SwiftUI
import AppKit

#if ENABLE_SPARKLE_UPDATES
#if canImport(Sparkle)
import Sparkle
#else
#error("ENABLE_SPARKLE_UPDATES requires the Sparkle module dependency.")
#endif
#endif

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

fileprivate enum DotenvScanState: Equatable {
    case idle
    case scanning(DotenvScanProgress)
    case completed([DetectedDotenvFile])
    case failed(String)
    case cancelled

    var isScanning: Bool {
        if case .scanning = self {
            return true
        }
        return false
    }
}

@main
struct PersonalEnvDesktopApp: App {
    @StateObject private var model = AppModel()

    #if ENABLE_SPARKLE_UPDATES
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif

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
            #if ENABLE_SPARKLE_UPDATES
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterController.checkForUpdates(nil)
                }
            }
            #endif
            CommandGroup(after: .newItem) {
                Button("Import .env...") {
                    model.presentImporter = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Reload from Keychain") {
                    Task { await model.reload() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!model.canReload)
            }
            CommandMenu("Search") {
                Button("Search All Variables") {
                    model.requestSearchFocus(.allVariableSearch)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("Filter Variables") {
                    model.requestSearchFocus(.variableFilter)
                }
                .keyboardShortcut("l", modifiers: [.command])

                Button("Search Vaults") {
                    model.requestSearchFocus(.vaultSearch)
                }
                .keyboardShortcut("f", modifiers: [.command])
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
    @Published fileprivate var dotenvScanState: DotenvScanState = .idle
    @Published fileprivate var searchFocusRequest: SearchFocusRequest?
    @Published private(set) var isWorking = false
    @Published private(set) var hasUnlockedSecretState = false

    private var service: VaultService?
    private var dotenvScanTask: Task<Void, Never>?
    private var activeDotenvScannerTask: Task<[DetectedDotenvFile], Error>?

    var canReload: Bool {
        service != nil && hasUnlockedSecretState && !isWorking
    }

    var selectedVault: EnvVault? {
        state.vaults.first { $0.id == selectedVaultID } ?? state.vaults.first
    }

    var selectedVariable: EnvVariable? {
        selectedVault?.variables.first { $0.id == selectedVariableID }
    }

    func load() async {
        do {
            let service = try VaultService(authenticator: LocalAuthenticator(grantStore: nil))
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
            isWorking = true
            defer { isWorking = false }
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
            isWorking = true
            defer { isWorking = false }
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
            isWorking = true
            defer { isWorking = false }
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
            isWorking = true
            defer { isWorking = false }
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
            isWorking = true
            defer { isWorking = false }
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

    func resetDotenvScan() {
        dotenvScanTask?.cancel()
        activeDotenvScannerTask?.cancel()
        dotenvScanTask = nil
        activeDotenvScannerTask = nil
        dotenvScanState = .idle
    }

    func cancelDotenvScan() {
        dotenvScanTask?.cancel()
        activeDotenvScannerTask?.cancel()
        dotenvScanTask = nil
        activeDotenvScannerTask = nil
        dotenvScanState = .cancelled
        status = "Cancelled .env scan"
    }

    func startApprovedDotenvScan(projectPath: String) {
        let trimmedPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            errorMessage = "Folder path is required."
            return
        }

        dotenvScanTask?.cancel()
        activeDotenvScannerTask?.cancel()

        let expandedPath = NSString(string: trimmedPath).expandingTildeInPath
        let initialProgress = DotenvScanProgress(currentPath: expandedPath)
        dotenvScanState = .scanning(initialProgress)
        status = "Scanning for .env files..."

        let progressPipe = AsyncStream<DotenvScanProgress>.makeStream()
        let scannerTask = Task.detached(priority: .userInitiated) {
            defer { progressPipe.continuation.finish() }
            return try DotenvCodec.scanApprovedDirectory(inDirectory: expandedPath) { progress in
                progressPipe.continuation.yield(progress)
            }
        }
        activeDotenvScannerTask = scannerTask

        dotenvScanTask = Task { [weak self] in
            guard let self else { return }
            async let progressConsumer: Void = self.consumeDotenvScanProgress(progressPipe.stream)
            do {
                let files = try await scannerTask.value
                _ = await progressConsumer
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.dotenvScanState = .cancelled
                        self.status = "Cancelled .env scan"
                    }
                    return
                }
                await MainActor.run {
                    self.dotenvScanState = .completed(files)
                    self.status = files.isEmpty ? "No .env files found" : "Detected \(files.count) .env files"
                    self.activeDotenvScannerTask = nil
                    self.dotenvScanTask = nil
                }
            } catch is CancellationError {
                _ = await progressConsumer
                await MainActor.run {
                    self.dotenvScanState = .cancelled
                    self.status = "Cancelled .env scan"
                    self.activeDotenvScannerTask = nil
                    self.dotenvScanTask = nil
                }
            } catch {
                _ = await progressConsumer
                await MainActor.run {
                    self.dotenvScanState = .failed(error.localizedDescription)
                    self.errorMessage = error.localizedDescription
                    self.status = "Scan failed"
                    self.activeDotenvScannerTask = nil
                    self.dotenvScanTask = nil
                }
            }
        }
    }

    private func consumeDotenvScanProgress(_ stream: AsyncStream<DotenvScanProgress>) async {
        for await progress in stream {
            if Task.isCancelled { break }
            dotenvScanState = .scanning(progress)
        }
    }

    func unlock() async -> Bool {
        guard let service else { return false }
        do {
            try await service.unlock()
            hasUnlockedSecretState = true
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
            isWorking = true
            defer { isWorking = false }
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
            isWorking = true
            defer { isWorking = false }
            try await service.updateVariable(vaultID: vault.id, variableID: variableID, key: key, value: value, scope: scope)
            state = await service.snapshot()
            duplicateHints = await service.duplicateHints()
            selectedVariableID = variableID
            status = "Updated \(key)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteVariable(_ variable: EnvVariable) async {
        guard let service, let vault = selectedVault else { return }
        do {
            isWorking = true
            defer { isWorking = false }
            try await service.deleteVariable(vaultID: vault.id, variableID: variable.id)
            state = await service.snapshot()
            duplicateHints = await service.duplicateHints()
            selectedVariableID = state.vaults.first { $0.id == vault.id }?.variables.first?.id
            status = "Removed \(variable.key)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importDotenv(url: URL) async {
        guard let service, let vault = selectedVault else { return }
        do {
            isWorking = true
            defer { isWorking = false }
            let text = try String(contentsOf: url, encoding: .utf8)
            try await service.importDotenv(text, vaultID: vault.id)
            state = await service.snapshot()
            duplicateHints = await service.duplicateHints()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportDotenv(keys: [String]? = nil) async {
        guard let service, let vault = selectedVault else { return }
        do {
            isWorking = true
            defer { isWorking = false }
            let text = try await service.exportDotenv(vaultID: vault.id, keys: keys)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if let keys, !keys.isEmpty {
                status = "Copied \(keys.count) selected variables to clipboard"
            } else {
                status = "Copied .env export to clipboard"
            }
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

    fileprivate func requestSearchFocus(_ field: SearchFocusField) {
        searchFocusRequest = SearchFocusRequest(field: field)
    }

    func reload(reason: String = "Reloaded from Keychain") async {
        guard let service, canReload else { return }
        let previousVaultID = selectedVaultID
        let previousVariableID = selectedVariableID

        do {
            isWorking = true
            defer { isWorking = false }
            try await service.reload()
            state = await service.snapshot()
            duplicateHints = await service.duplicateHints()
            restoreSelection(previousVaultID: previousVaultID, previousVariableID: previousVariableID)
            status = reason
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreSelection(previousVaultID: EnvVault.ID?, previousVariableID: EnvVariable.ID?) {
        let vault = state.vaults.first { $0.id == previousVaultID } ?? state.vaults.first
        selectedVaultID = vault?.id

        if let vault, vault.variables.contains(where: { $0.id == previousVariableID }) {
            selectedVariableID = previousVariableID
        } else {
            selectedVariableID = vault?.variables.first?.id
        }
    }
}

fileprivate enum SearchFocusField: Hashable {
    case vaultSearch
    case variableFilter
    case allVariableSearch
    case allVariableIncludeVaults
    case allVariableExcludeVaults
}

fileprivate struct SearchFocusRequest: Equatable {
    let id = UUID()
    let field: SearchFocusField
}

private struct VariableSearchResult: Identifiable {
    let vault: EnvVault
    let variable: EnvVariable

    var id: String {
        "\(vault.id.uuidString)::\(variable.id.uuidString)"
    }
}

private struct TransparentSearchTextField: NSViewRepresentable {
    @Binding var text: String

    let placeholder: String
    let focusField: SearchFocusField
    let focusedField: FocusState<SearchFocusField?>.Binding

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.textColor = .labelColor
        textField.placeholderString = placeholder
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }

        if textField.placeholderString != placeholder {
            textField.placeholderString = placeholder
        }

        guard focusedField.wrappedValue == focusField else { return }
        DispatchQueue.main.async {
            if textField.window?.firstResponder !== textField.currentEditor() {
                textField.window?.makeFirstResponder(textField)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var parent: TransparentSearchTextField

        init(_ parent: TransparentSearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.focusedField.wrappedValue = parent.focusField
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if parent.focusedField.wrappedValue == parent.focusField {
                parent.focusedField.wrappedValue = nil
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenWelcomeTutorial") private var hasSeenWelcomeTutorial = false
    @FocusState private var focusedSearchField: SearchFocusField?
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var newScope = "project"
    @State private var hoveredVariableID: EnvVariable.ID?
    @State private var hoveredDetailRow: String?
    @State private var copiedVariableValueID: EnvVariable.ID?
    @State private var copiedDetailRow: String?
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
    @State private var allVariableSearchText = ""
    @State private var allVariableIncludeVaultsText = ""
    @State private var allVariableExcludeVaultsText = ""
    @State private var isAllVariableSearchPresented = false
    @State private var selectedExportVariableIDs = Set<EnvVariable.ID>()
    @State private var showExportPicker = false
    @State private var showNewProjectCreator = false
    @State private var showExistingProjectUpload = false
    @State private var newProjectName = ""
    @State private var newProjectParentPath = ""
    @State private var existingProjectName = ""
    @State private var existingProjectPath = ""
    @State private var detectedUploadFiles: [DetectedDotenvFile] = []
    @State private var selectedUploadVariableIDs = Set<UploadVariableChoice.ID>()
    @State private var vaultToRename: EnvVault?
    @State private var vaultRenameName = ""
    @State private var vaultToDelete: EnvVault?
    @State private var variablePendingDelete: EnvVariable?
    @State private var shouldReloadAfterActivation = false

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
        .confirmationDialog("Remove Variable", isPresented: Binding(get: { variablePendingDelete != nil }, set: { if !$0 { variablePendingDelete = nil } })) {
            Button("Remove from Vault and .env", role: .destructive) {
                guard let variable = variablePendingDelete else { return }
                variablePendingDelete = nil
                Task { await model.deleteVariable(variable) }
            }
            Button("Cancel", role: .cancel) {
                variablePendingDelete = nil
            }
        } message: {
            Text("This removes the selected key from Personal Env and from the vault's tracked dotenv file.")
        }
        .tint(EnvTheme.accent)
        .sheet(isPresented: $showTutorial, onDismiss: { hasSeenWelcomeTutorial = true }) {
            WelcomeTutorialView(
                onScanFolders: startFirstRunFolderScan,
                onUploadProject: startFirstRunProjectUpload,
                onCreateProject: startFirstRunProjectCreate,
                onDismiss: {
                    hasSeenWelcomeTutorial = true
                    showTutorial = false
                }
            )
            .frame(width: 620, height: 540)
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
                selectedVariableIDs: $selectedUploadVariableIDs,
                scanState: model.dotenvScanState,
                onCancel: {
                    if model.dotenvScanState.isScanning {
                        model.cancelDotenvScan()
                    } else {
                        model.resetDotenvScan()
                    }
                    showExistingProjectUpload = false
                },
                onUpload: uploadExistingProject,
                onChooseFolder: chooseExistingProjectFolder,
                onScan: refreshExistingProjectDetection,
                onCancelScan: {
                    model.cancelDotenvScan()
                }
            )
            .frame(width: 620, height: 560)
        }
        .sheet(isPresented: $showExportPicker) {
            ExportVariablesView(
                vault: model.selectedVault,
                selectedVariableIDs: $selectedExportVariableIDs,
                onCancel: {
                    showExportPicker = false
                },
                onExport: exportSelectedVariables
            )
            .frame(width: 540, height: 520)
        }
        .onAppear {
            syncEditor()
            showTutorial = !hasSeenWelcomeTutorial && model.state.vaults.isEmpty
            Task { await unlockFromLaunch() }
        }
        .onChange(of: model.selectedVariableID) {
            syncEditor()
        }
        .onChange(of: model.state) {
            syncEditor()
            pruneSelectedExportVariables()
        }
        .onChange(of: model.dotenvScanState) { _, scanState in
            handleDotenvScanState(scanState)
        }
        .onChange(of: model.searchFocusRequest) { _, request in
            guard let request else { return }
            focusSearchField(request.field)
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                guard shouldReloadAfterActivation else { return }
                shouldReloadAfterActivation = false
                Task { await reloadFromKeychain(reason: "Reloaded after app activation") }
            } else if isUnlocked {
                shouldReloadAfterActivation = true
            }
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
                    TransparentSearchTextField(
                        text: $vaultSearchText,
                        placeholder: "Search vaults...",
                        focusField: .vaultSearch,
                        focusedField: $focusedSearchField
                    )
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

            if isAllVariableSearchVisible {
                Section("Search Variables") {
                    allVariableSidebarSearchPanel
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 12, trailing: 14))
                }
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
            if let selectedVariableID = model.selectedVariableID,
               model.selectedVault?.variables.contains(where: { $0.id == selectedVariableID }) == true {
                selectedExportVariableIDs.removeAll()
                syncEditor()
                return
            }
            model.selectedVariableID = model.selectedVault?.variables.first?.id
            selectedExportVariableIDs.removeAll()
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

    private var selectedExportKeys: [String] {
        let variables = model.selectedVault?.variables ?? []
        return variables
            .filter { selectedExportVariableIDs.contains($0.id) }
            .map(\.key)
    }

    private var allVariableSearchResults: [VariableSearchResult] {
        let query = allVariableSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        return allVariableSearchVaults.flatMap { vault in
            vault.variables.compactMap { variable in
                guard variable.key.lowercased().contains(query) else { return nil }
                return VariableSearchResult(vault: vault, variable: variable)
            }
        }
    }

    private var allVariableSearchVaults: [EnvVault] {
        let includeTokens = searchTokens(from: allVariableIncludeVaultsText)
        let excludeTokens = searchTokens(from: allVariableExcludeVaultsText)

        return model.state.vaults.filter { vault in
            let vaultText = "\(vault.name) \(vault.projectPath)".lowercased()
            let included = includeTokens.isEmpty || includeTokens.contains { vaultText.contains($0) }
            let excluded = excludeTokens.contains { vaultText.contains($0) }
            return included && !excluded
        }
    }

    private var isAllVariableSearchVisible: Bool {
        isAllVariableSearchPresented ||
            focusedSearchField == .allVariableSearch ||
            !allVariableSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !allVariableIncludeVaultsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !allVariableExcludeVaultsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canReloadFromKeychain: Bool {
        isUnlocked && !isUnlocking && !showEditControls && !model.presentImporter && model.canReload
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
                Task { await reloadFromKeychain() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(!canReloadFromKeychain)
            .help("Reload from Keychain")

            Button {
                prepareExportPicker()
            } label: {
                Label("Export", systemImage: "arrow.up.to.line")
            }
            .disabled(model.selectedVault == nil)
            .help("Choose variables to export")

            Button {
                model.copyToClipboard(model.selectedVault?.projectPath ?? "", label: "project path")
            } label: {
                Label("Share", systemImage: "person.2")
            }
            .disabled(model.selectedVault == nil)

            Spacer()

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
                TransparentSearchTextField(
                    text: $variableSearchText,
                    placeholder: "Filter variables...",
                    focusField: .variableFilter,
                    focusedField: $focusedSearchField
                )
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

    private var allVariableSidebarSearchPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(EnvTheme.muted)
                TransparentSearchTextField(
                    text: $allVariableSearchText,
                    placeholder: "Search variable names...",
                    focusField: .allVariableSearch,
                    focusedField: $focusedSearchField
                )
                Text("⌘⇧F")
                    .font(.caption)
                    .foregroundStyle(EnvTheme.muted.opacity(0.65))
                Button {
                    allVariableSearchText = ""
                    allVariableIncludeVaultsText = ""
                    allVariableExcludeVaultsText = ""
                    isAllVariableSearchPresented = false
                    focusedSearchField = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(EnvTheme.muted)
                .help("Clear all-variable search")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(EnvTheme.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(EnvTheme.separator.opacity(0.7), lineWidth: 1)
            )

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(EnvTheme.muted)
                TransparentSearchTextField(
                    text: $allVariableIncludeVaultsText,
                    placeholder: "Include vaults",
                    focusField: .allVariableIncludeVaults,
                    focusedField: $focusedSearchField
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(EnvTheme.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(EnvTheme.separator.opacity(0.55), lineWidth: 1)
            )

            HStack(spacing: 6) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(EnvTheme.muted)
                TransparentSearchTextField(
                    text: $allVariableExcludeVaultsText,
                    placeholder: "Exclude vaults",
                    focusField: .allVariableExcludeVaults,
                    focusedField: $focusedSearchField
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(EnvTheme.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(EnvTheme.separator.opacity(0.55), lineWidth: 1)
            )

            if !allVariableSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Text("\(allVariableSearchResults.count) results")
                    Spacer()
                    Text("\(allVariableSearchVaults.count) vaults")
                }
                .font(.caption)
                .foregroundStyle(EnvTheme.muted)

                if allVariableSearchResults.isEmpty {
                    Text("No matching variables")
                        .font(.caption)
                        .foregroundStyle(EnvTheme.muted)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(allVariableSearchResults) { result in
                                Button {
                                    selectSearchResult(result)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.variable.key)
                                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                                            .foregroundStyle(EnvTheme.ink)
                                            .lineLimit(1)
                                        Text(result.vault.name)
                                            .font(.caption)
                                            .foregroundStyle(EnvTheme.muted)
                                            .lineLimit(1)
                                    }
                                    .padding(.vertical, 7)
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(EnvTheme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 210)
                }
            }
        }
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
                    showCopiedFeedback(for: variable.id)
                } label: {
                    HStack(spacing: 8) {
                        Text(mask(variable.value))
                            .font(.system(.body, design: .monospaced))
                        if hoveredVariableID == variable.id {
                            Image(systemName: "doc.on.doc")
                            Text(copiedVariableValueID == variable.id ? "\(variable.key) copied to clipboard" : "Click to copy value")
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
                detailRow("Key", value: variable.key, hoverText: "Click to copy key name", copiedText: "key name copied to clipboard") {
                    model.copyToClipboard(variable.key, label: "key")
                    showDetailCopiedFeedback(for: "Key")
                }
                Divider()
                detailRow("Value", value: mask(variable.value), hoverText: "Click to copy value", copiedText: "\(variable.key) copied to clipboard") {
                    model.copyToClipboard(variable.value, label: variable.key)
                    showDetailCopiedFeedback(for: "Value")
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
                    Button(role: .destructive) {
                        variablePendingDelete = model.selectedVariable
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .disabled(model.selectedVariable == nil)
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

    private func searchTokens(from text: String) -> [String] {
        text
            .split { character in
                character == "," || character == " " || character == "\n" || character == "\t"
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func selectSearchResult(_ result: VariableSearchResult) {
        model.selectedVaultID = result.vault.id
        model.selectedVariableID = result.variable.id
        showInspector = true
        syncEditor()
    }

    private func focusSearchField(_ field: SearchFocusField) {
        guard field == .allVariableSearch else {
            focusedSearchField = field
            return
        }

        isAllVariableSearchPresented = true
        DispatchQueue.main.async {
            focusedSearchField = .allVariableSearch
        }
    }

    private func pruneSelectedExportVariables() {
        let validIDs = Set((model.selectedVault?.variables ?? []).map(\.id))
        selectedExportVariableIDs = selectedExportVariableIDs.intersection(validIDs)
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

    private func detailRow(_ title: String, value: String, hoverText: String? = nil, copiedText: String? = nil, action: (() -> Void)? = nil) -> some View {
        let isHovered = hoveredDetailRow == title
        let feedbackText = copiedDetailRow == title ? (copiedText ?? "Copied") : (hoverText ?? "Click to copy")
        return Button {
            action?()
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(EnvTheme.ink)
                Spacer()
                Text(isHovered && action != nil ? feedbackText : value)
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

    private func showCopiedFeedback(for variableID: EnvVariable.ID) {
        copiedVariableValueID = variableID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedVariableValueID == variableID {
                copiedVariableValueID = nil
            }
        }
    }

    private func showDetailCopiedFeedback(for rowTitle: String) {
        copiedDetailRow = rowTitle
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedDetailRow == rowTitle {
                copiedDetailRow = nil
            }
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
        model.resetDotenvScan()
        existingProjectName = ""
        existingProjectPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code").path
        detectedUploadFiles = []
        selectedUploadVariableIDs = []
    }

    private func startFirstRunFolderScan() {
        hasSeenWelcomeTutorial = true
        showTutorial = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            prepareExistingProjectUpload()
            showExistingProjectUpload = true
            chooseExistingProjectFolder()
        }
    }

    private func startFirstRunProjectUpload() {
        hasSeenWelcomeTutorial = true
        showTutorial = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            prepareExistingProjectUpload()
            showExistingProjectUpload = true
        }
    }

    private func startFirstRunProjectCreate() {
        hasSeenWelcomeTutorial = true
        showTutorial = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            prepareNewProjectCreator()
            showNewProjectCreator = true
        }
    }

    private func prepareExportPicker() {
        guard let vault = model.selectedVault else { return }
        selectedExportVariableIDs = Set(vault.variables.map(\.id))
        showExportPicker = true
    }

    private func exportSelectedVariables() {
        let keys = selectedExportKeys
        showExportPicker = false
        Task { await model.exportDotenv(keys: keys.isEmpty ? nil : keys) }
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
        panel.message = "Approve a folder for Personal Env to scan for .env files."
        panel.prompt = "Approve Folder"
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
        detectedUploadFiles = []
        selectedUploadVariableIDs = []
        model.startApprovedDotenvScan(projectPath: existingProjectPath)
    }

    private func handleDotenvScanState(_ scanState: DotenvScanState) {
        guard showExistingProjectUpload else { return }
        switch scanState {
        case .completed(let files):
            detectedUploadFiles = files
            let choices = UploadVariableChoice.make(from: files)
            selectedUploadVariableIDs = Set(choices.map(\.id))
        case .idle, .scanning, .failed, .cancelled:
            break
        }
    }

    private func uploadExistingProject() {
        let selectedFiles = selectedDetectedFiles()
        let name = existingProjectName
        let path = existingProjectPath
        showExistingProjectUpload = false
        Task { await model.uploadDetectedDotenvFiles(name: name, projectPath: path, files: selectedFiles) }
    }

    private func selectedDetectedFiles() -> [DetectedDotenvFile] {
        return detectedUploadFiles.compactMap { file in
            let variables = file.variables.filter { variable in
                selectedUploadVariableIDs.contains(UploadVariableChoice.id(filePath: file.path, variableID: variable.id))
            }
            guard !variables.isEmpty else { return nil }
            return DetectedDotenvFile(fileName: file.fileName, path: file.path, projectPath: file.projectPath, variables: variables)
        }
    }

    private func reloadFromKeychain(reason: String = "Reloaded from Keychain") async {
        guard canReloadFromKeychain else { return }
        await model.reload(reason: reason)
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
    let onScanFolders: () -> Void
    let onUploadProject: () -> Void
    let onCreateProject: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("Personal Env", systemImage: "lock.shield")
                    .font(.title.bold())
                    .foregroundStyle(EnvTheme.ink)
                Spacer()
                Button("Later") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Text("Start by scanning an approved folder for existing .env files, uploading one project, or creating a clean vault.")
                .font(.title3)
                .foregroundStyle(EnvTheme.muted)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    onScanFolders()
                } label: {
                    Label("Scan Folder for .env Files", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)

                HStack(spacing: 10) {
                    Button {
                        onUploadProject()
                    } label: {
                        Label("Upload Project", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        onCreateProject()
                    } label: {
                        Label("Create Project", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                TutorialStep(icon: "folder.badge.plus", title: "Approve folders", text: "Choose any directory you want Personal Env to scan, including Documents or Downloads.")
                TutorialStep(icon: "doc.text.magnifyingglass", title: "Review scan results", text: "Detected .env variables stay selectable before anything is imported.")
                TutorialStep(icon: "key.fill", title: "Add shared API keys", text: "Use Edit Vault to reveal the key fields, then save scoped values for services like AI, email, storage, or payments.")
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

private enum UploadDetectedViewMode: String, CaseIterable, Identifiable {
    case projects
    case allNames

    var id: String { rawValue }
}

private struct UploadProjectChoiceGroup: Identifiable {
    let projectPath: String
    let choices: [UploadVariableChoice]

    var id: String { projectPath }

    var projectName: String {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        return name.isEmpty ? projectPath : name
    }
}

private struct UploadExistingProjectView: View {
    @Binding var projectName: String
    @Binding var projectPath: String
    @Binding var detectedFiles: [DetectedDotenvFile]
    @Binding var selectedVariableIDs: Set<UploadVariableChoice.ID>
    @State private var detectedViewMode: UploadDetectedViewMode = .projects
    let scanState: DotenvScanState
    let onCancel: () -> Void
    let onUpload: () -> Void
    let onChooseFolder: () -> Void
    let onScan: () -> Void
    let onCancelScan: () -> Void

    private var choices: [UploadVariableChoice] {
        UploadVariableChoice.make(from: detectedFiles)
    }

    private var selectedCount: Int {
        choices.filter { selectedVariableIDs.contains($0.id) }.count
    }

    private var projectGroups: [UploadProjectChoiceGroup] {
        Dictionary(grouping: choices, by: \.projectPath)
            .map { projectPath, choices in
                UploadProjectChoiceGroup(
                    projectPath: projectPath,
                    choices: choices.sorted { lhs, rhs in
                        if lhs.key == rhs.key {
                            return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
                        }
                        return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                lhs.projectName.localizedStandardCompare(rhs.projectName) == .orderedAscending
            }
    }

    private var canUpload: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !scanState.isScanning &&
            (choices.isEmpty || selectedCount > 0)
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
                            Label(scanState.isScanning ? "Scanning" : "Scan", systemImage: "magnifyingglass")
                        }
                        .disabled(scanState.isScanning)
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
                    Text(scanStatusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(EnvTheme.muted)
                }
                Text("Scanning only runs after you approve this folder. Documents, Downloads, and custom directories are supported.")
                    .font(.caption)
                    .foregroundStyle(EnvTheme.muted)

                if case .scanning(let progress) = scanState {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Scanning for .env files")
                                    .font(.headline)
                                    .foregroundStyle(EnvTheme.ink)
                                Text("\(progress.visitedItemCount) checked · \(progress.detectedFileCount) found · \(progress.skippedItemCount) skipped")
                                    .font(.caption)
                                    .foregroundStyle(EnvTheme.muted)
                            }
                            Spacer()
                            Button {
                                onCancelScan()
                            } label: {
                                Label("Cancel", systemImage: "xmark")
                            }
                        }
                        if !progress.currentPath.isEmpty {
                            Text(progress.currentPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(EnvTheme.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if choices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(emptyStateTitle)
                            .font(.headline)
                            .foregroundStyle(EnvTheme.ink)
                        Text(emptyStateDescription)
                            .foregroundStyle(EnvTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
	                } else {
	                    HStack(spacing: 10) {
	                        Button {
	                            selectedVariableIDs = Set(choices.map(\.id))
                        } label: {
                            Label("Select All", systemImage: "checkmark.square")
                        }
                        .buttonStyle(.borderless)

                        Button {
                            selectedVariableIDs.removeAll()
                        } label: {
                            Label("Clear", systemImage: "square")
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        Picker("Detected view", selection: $detectedViewMode) {
                            Label("Projects", systemImage: "folder")
                                .tag(UploadDetectedViewMode.projects)
                            Label("All Names", systemImage: "textformat")
                                .tag(UploadDetectedViewMode.allNames)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 230)
                    }

                    ScrollView {
                        Group {
                            if detectedViewMode == .projects {
                                projectGroupedResults
                            } else {
                                allNameResults
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: 220)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    private var projectGroupedResults: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(projectGroups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(EnvTheme.accent)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.projectName)
                                .font(.headline)
                                .foregroundStyle(EnvTheme.ink)
                                .lineLimit(1)
                            Text(group.projectPath)
                                .font(.caption)
                                .foregroundStyle(EnvTheme.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(selectedCount(in: group.choices)) of \(group.choices.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(EnvTheme.muted)
                    }

                    HStack(spacing: 10) {
                        Button {
                            select(group.choices)
                        } label: {
                            Label("Select Project", systemImage: "checkmark.square")
                        }
                        .buttonStyle(.borderless)

                        Button {
                            clear(group.choices)
                        } label: {
                            Label("Clear Project", systemImage: "square")
                        }
                        .buttonStyle(.borderless)

                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(group.choices) { choice in
                            variableToggle(for: choice, showsProjectPath: false)
                        }
                    }
                    .padding(.leading, 2)
                }
                .padding(12)
                .background(EnvTheme.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var allNameResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(choices.sorted { lhs, rhs in
                if lhs.key == rhs.key {
                    return lhs.projectPath.localizedStandardCompare(rhs.projectPath) == .orderedAscending
                }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }) { choice in
                variableToggle(for: choice, showsProjectPath: true)
            }
        }
    }

    private func variableToggle(for choice: UploadVariableChoice, showsProjectPath: Bool) -> some View {
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
                    if showsProjectPath {
                        Text(choice.projectPath)
                            .font(.caption)
                            .foregroundStyle(EnvTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Text(choice.scope)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(EnvTheme.muted)
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

    private func selectedCount(in choices: [UploadVariableChoice]) -> Int {
        choices.filter { selectedVariableIDs.contains($0.id) }.count
    }

    private func select(_ choices: [UploadVariableChoice]) {
        selectedVariableIDs.formUnion(choices.map(\.id))
    }

    private func clear(_ choices: [UploadVariableChoice]) {
        selectedVariableIDs.subtract(choices.map(\.id))
    }

    private var scanStatusText: String {
        switch scanState {
        case .idle:
            return choices.isEmpty ? "Not scanned" : "\(selectedCount) of \(choices.count) selected"
        case .scanning(let progress):
            return "\(progress.detectedFileCount) found"
        case .completed:
            return choices.isEmpty ? "No variables" : "\(selectedCount) of \(choices.count) selected"
        case .failed:
            return "Scan failed"
        case .cancelled:
            return "Scan cancelled"
        }
    }

    private var emptyStateTitle: String {
        switch scanState {
        case .idle:
            return "Approve and scan a folder."
        case .completed:
            return "No .env or .env.local variables found."
        case .failed:
            return "Scan failed."
        case .cancelled:
            return "Scan cancelled."
        case .scanning:
            return "Scanning"
        }
    }

    private var emptyStateDescription: String {
        switch scanState {
        case .idle:
            return "Choose a folder or press Scan to review variables before import."
        case .completed:
            return "Upload will still create a vault for this folder."
        case .failed:
            return "Adjust the folder path or choose a different directory."
        case .cancelled:
            return "Press Scan to start again."
        case .scanning:
            return "Checking approved folder."
        }
    }
}

private struct ExportVariablesView: View {
    let vault: EnvVault?
    @Binding var selectedVariableIDs: Set<EnvVariable.ID>
    let onCancel: () -> Void
    let onExport: () -> Void

    private var variables: [EnvVariable] {
        vault?.variables ?? []
    }

    private var canExport: Bool {
        !variables.isEmpty && !selectedVariableIDs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Export Variables", systemImage: "arrow.up.to.line")
                    .font(.title2.bold())
                    .foregroundStyle(EnvTheme.ink)
                Spacer()
            }

            if let vault {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vault.name)
                        .font(.headline)
                        .foregroundStyle(EnvTheme.ink)
                    Text(vault.projectPath)
                        .font(.caption)
                        .foregroundStyle(EnvTheme.muted)
                        .lineLimit(1)
                }
            }

            Divider()

            HStack {
                Text("\(selectedVariableIDs.count) of \(variables.count) selected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(EnvTheme.muted)
                Spacer()
                Button {
                    selectedVariableIDs = Set(variables.map(\.id))
                } label: {
                    Label("Select All", systemImage: "checkmark.square")
                }
                .buttonStyle(.borderless)

                Button {
                    selectedVariableIDs.removeAll()
                } label: {
                    Label("Clear", systemImage: "square")
                }
                .buttonStyle(.borderless)
            }

            if variables.isEmpty {
                ContentUnavailableView {
                    Label("No Variables", systemImage: "key")
                } description: {
                    Text("Add variables before exporting this vault.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(variables) { variable in
                            Toggle(isOn: Binding(
                                get: { selectedVariableIDs.contains(variable.id) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedVariableIDs.insert(variable.id)
                                    } else {
                                        selectedVariableIDs.remove(variable.id)
                                    }
                                }
                            )) {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(variable.key)
                                            .font(.system(.body, design: .monospaced))
                                            .lineLimit(1)
                                        Text(variable.scope)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(EnvTheme.muted)
                                    }
                                    Spacer()
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(12)
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Spacer()

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button {
                    onExport()
                } label: {
                    Label("Export Selected", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canExport)
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
