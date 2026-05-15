import Foundation

public enum DotenvCodec {
    public static let projectFileName = ".env"
    public static let supportedFileNames = [".env", ".env.local"]
    public static let skippedRecursiveDirectoryNames = Set([
        ".build",
        ".git",
        ".next",
        "Build",
        "DerivedData",
        "Library",
        "node_modules",
        "dist",
        "build"
    ])
    public static let projectRootMarkerNames = Set([
        ".git",
        "Cargo.toml",
        "Package.swift",
        "deno.json",
        "go.mod",
        "package.json",
        "pnpm-workspace.yaml",
        "pyproject.toml",
        "requirements.txt",
        "swift-package-manager.json",
        "tsconfig.json",
        "yarn.lock"
    ])

    public static func parse(_ text: String, scope: String = "project") -> [EnvVariable] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> EnvVariable? in
                var line = String(rawLine).trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
                if line.hasPrefix("export ") {
                    line.removeFirst("export ".count)
                }
                guard let equals = line.firstIndex(of: "=") else { return nil }
                let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                if value.count >= 2 {
                    let first = value.first
                    let last = value.last
                    if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                        value.removeFirst()
                        value.removeLast()
                    }
                }
                guard !key.isEmpty else { return nil }
                return EnvVariable(key: key, value: value, scope: scope)
            }
    }

    public static func render(_ variables: [EnvVariable]) -> String {
        guard !variables.isEmpty else { return "" }
        return variables
            .sorted { $0.key < $1.key }
            .map { variable in
                "\(variable.key)=\(quoteIfNeeded(variable.value))"
            }
            .joined(separator: "\n") + "\n"
    }

    public static func scanFiles(inDirectory directoryPath: String) throws -> [DetectedDotenvFile] {
        let expandedPath = NSString(string: directoryPath).expandingTildeInPath
        let directoryURL = URL(fileURLWithPath: expandedPath, isDirectory: true)

        return try supportedFileNames.compactMap { fileName in
            let url = directoryURL.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            let scope = fileName == ".env.local" ? "local" : "project"
            return DetectedDotenvFile(fileName: fileName, path: url.path, projectPath: directoryURL.path, variables: parse(text, scope: scope))
        }
    }

    public static func scanFilesRecursively(
        inDirectory directoryPath: String,
        maximumDepth: Int = 6,
        progress: (@Sendable (DotenvScanProgress) -> Void)? = nil
    ) throws -> [DetectedDotenvFile] {
        try scanFilesRecursively(
            inDirectory: directoryPath,
            options: DotenvScanOptions(approval: .projectFolder, maximumDepth: maximumDepth),
            progress: progress
        )
    }

    public static func scanApprovedDirectory(
        inDirectory directoryPath: String,
        maximumDepth: Int = DotenvScanOptions.approvedDirectoryDefaultDepth,
        maximumVisitedItems: Int = DotenvScanOptions.approvedDirectoryMaximumVisitedItems,
        progress: (@Sendable (DotenvScanProgress) -> Void)? = nil
    ) throws -> [DetectedDotenvFile] {
        try scanFilesRecursively(
            inDirectory: directoryPath,
            options: DotenvScanOptions(
                approval: .userApprovedDirectory,
                maximumDepth: maximumDepth,
                maximumVisitedItems: maximumVisitedItems
            ),
            progress: progress
        )
    }

    public static func scanFilesRecursively(
        inDirectory directoryPath: String,
        options: DotenvScanOptions,
        progress: (@Sendable (DotenvScanProgress) -> Void)? = nil
    ) throws -> [DetectedDotenvFile] {
        let expandedPath = NSString(string: directoryPath).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        let policy = DotenvScanPolicy()
        try policy.validate(rootURL, approval: options.approval)

        var files: [DetectedDotenvFile] = []
        var visitedItemCount = 0
        var skippedItemCount = 0
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .nameKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                skippedItemCount += 1
                return true
            }
        ) else {
            return []
        }

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visitedItemCount += 1
            guard visitedItemCount <= options.maximumVisitedItems else {
                throw PersonalEnvError.invalidRequest("The scan reached \(options.maximumVisitedItems) files and folders before finishing. Choose a narrower folder or scan this location in smaller pieces.")
            }

            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            let name = values?.name ?? url.lastPathComponent
            let depth = relativeDepth(from: rootURL, to: url)
            if values?.isDirectory == true {
                if values?.isPackage == true ||
                    values?.isSymbolicLink == true ||
                    depth >= options.maximumDepth ||
                    skippedRecursiveDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                    skippedItemCount += 1
                }
                publishProgress(
                    progress,
                    visitedItemCount: visitedItemCount,
                    skippedItemCount: skippedItemCount,
                    detectedFileCount: files.count,
                    currentPath: url.path,
                    force: visitedItemCount == 1
                )
                continue
            }
            guard supportedFileNames.contains(name) else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                skippedItemCount += 1
                continue
            }
            let scope = name == ".env.local" ? "local" : "project"
            let projectPath = resolveProjectPath(forDotenvFile: url, boundedBy: rootURL)
            files.append(DetectedDotenvFile(fileName: name, path: url.path, projectPath: projectPath, variables: parse(text, scope: scope)))
            publishProgress(
                progress,
                visitedItemCount: visitedItemCount,
                skippedItemCount: skippedItemCount,
                detectedFileCount: files.count,
                currentPath: url.path,
                force: true
            )
        }

        publishProgress(
            progress,
            visitedItemCount: visitedItemCount,
            skippedItemCount: skippedItemCount,
            detectedFileCount: files.count,
            currentPath: rootURL.path,
            force: true
        )

        return files.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private static func relativeDepth(from rootURL: URL, to url: URL) -> Int {
        let rootCount = rootURL.standardizedFileURL.pathComponents.count
        let urlCount = url.standardizedFileURL.pathComponents.count
        return max(0, urlCount - rootCount)
    }

    private static func resolveProjectPath(forDotenvFile dotenvURL: URL, boundedBy rootURL: URL) -> String {
        let root = rootURL.standardizedFileURL
        let fileManager = FileManager.default
        var current = dotenvURL.deletingLastPathComponent().standardizedFileURL
        let fallback = current.path

        while current.path.hasPrefix(root.path) {
            for marker in projectRootMarkerNames {
                if fileManager.fileExists(atPath: current.appendingPathComponent(marker).path) {
                    return current.path
                }
            }
            if current.path == root.path {
                break
            }
            current.deleteLastPathComponent()
        }

        return fallback
    }

    private static func publishProgress(
        _ progress: (@Sendable (DotenvScanProgress) -> Void)?,
        visitedItemCount: Int,
        skippedItemCount: Int,
        detectedFileCount: Int,
        currentPath: String,
        force: Bool = false
    ) {
        guard let progress else { return }
        guard force || visitedItemCount.isMultiple(of: 100) else { return }
        progress(DotenvScanProgress(
            visitedItemCount: visitedItemCount,
            skippedItemCount: skippedItemCount,
            detectedFileCount: detectedFileCount,
            currentPath: currentPath
        ))
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let needsQuotes = value.contains { character in
            character.isWhitespace || character == "#" || character == "\"" || character == "'"
        }
        guard needsQuotes else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

public enum DotenvScanApproval: Equatable, Sendable {
    case projectFolder
    case userApprovedDirectory
}

public struct DotenvScanOptions: Equatable, Sendable {
    public static let projectFolderDefaultDepth = 6
    public static let projectFolderMaximumVisitedItems = 50_000
    public static let approvedDirectoryDefaultDepth = 8
    public static let approvedDirectoryMaximumVisitedItems = 250_000

    public var approval: DotenvScanApproval
    public var maximumDepth: Int
    public var maximumVisitedItems: Int

    public init(
        approval: DotenvScanApproval = .projectFolder,
        maximumDepth: Int = DotenvScanOptions.projectFolderDefaultDepth,
        maximumVisitedItems: Int = DotenvScanOptions.projectFolderMaximumVisitedItems
    ) {
        self.approval = approval
        self.maximumDepth = maximumDepth
        self.maximumVisitedItems = maximumVisitedItems
    }
}

public struct DotenvScanProgress: Equatable, Sendable {
    public var visitedItemCount: Int
    public var skippedItemCount: Int
    public var detectedFileCount: Int
    public var currentPath: String

    public init(visitedItemCount: Int = 0, skippedItemCount: Int = 0, detectedFileCount: Int = 0, currentPath: String = "") {
        self.visitedItemCount = visitedItemCount
        self.skippedItemCount = skippedItemCount
        self.detectedFileCount = detectedFileCount
        self.currentPath = currentPath
    }
}

public struct DotenvScanPolicy: Sendable {
    public let blockedSystemPaths: Set<String>
    public let broadUserPathsRequiringApproval: Set<String>

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let home = homeDirectory.standardizedFileURL
        self.blockedSystemPaths = Set<String>([
            "/",
            "/Applications",
            "/Library",
            "/Network",
            "/System",
            "/Users",
            "/Volumes"
        ])

        var broadUserPaths = Set<String>([
            home.path,
        ])
        for folder in ["Desktop", "Documents", "Downloads", "Applications", "Movies", "Music", "Pictures", "Public"] {
            broadUserPaths.insert(home.appendingPathComponent(folder, isDirectory: true).standardizedFileURL.path)
        }
        self.broadUserPathsRequiringApproval = broadUserPaths
    }

    public func validate(_ url: URL, approval: DotenvScanApproval) throws {
        let path = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PersonalEnvError.invalidRequest("Choose an existing folder before scanning for .env files.")
        }
        if blockedSystemPaths.contains(path) {
            throw PersonalEnvError.invalidRequest("Personal Env will not scan system roots. Choose a user-owned folder or a specific project directory.")
        }
        if approval == .projectFolder, broadUserPathsRequiringApproval.contains(path) {
            throw PersonalEnvError.invalidRequest("This is a broad folder. Approve it explicitly before deep scanning for .env files.")
        }
    }
}
