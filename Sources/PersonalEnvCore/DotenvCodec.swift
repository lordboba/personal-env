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

    public static func scanFilesRecursively(inDirectory directoryPath: String, maximumDepth: Int = 6) throws -> [DetectedDotenvFile] {
        let expandedPath = NSString(string: directoryPath).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        let guardrail = RecursiveScanGuardrail()
        try guardrail.validate(rootURL)

        var files: [DetectedDotenvFile] = []
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            let name = values?.name ?? url.lastPathComponent
            let depth = relativeDepth(from: rootURL, to: url)
            if values?.isDirectory == true {
                if depth >= maximumDepth || skippedRecursiveDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard supportedFileNames.contains(name) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let scope = name == ".env.local" ? "local" : "project"
            files.append(DetectedDotenvFile(fileName: name, path: url.path, projectPath: url.deletingLastPathComponent().path, variables: parse(text, scope: scope)))
        }

        return files.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private static func relativeDepth(from rootURL: URL, to url: URL) -> Int {
        let rootCount = rootURL.standardizedFileURL.pathComponents.count
        let urlCount = url.standardizedFileURL.pathComponents.count
        return max(0, urlCount - rootCount)
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let needsQuotes = value.contains { character in
            character.isWhitespace || character == "#" || character == "\"" || character == "'"
        }
        guard needsQuotes else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

public struct RecursiveScanGuardrail: Sendable {
    public let blockedPaths: Set<String>

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let home = homeDirectory.standardizedFileURL
        var paths = Set<String>([
            home.path,
            "/Applications",
            "/Library",
            "/System",
            "/Users",
            "/Volumes"
        ])
        for folder in ["Desktop", "Documents", "Downloads", "Applications", "Movies", "Music", "Pictures", "Public"] {
            paths.insert(home.appendingPathComponent(folder, isDirectory: true).standardizedFileURL.path)
        }
        self.blockedPaths = paths
    }

    public func validate(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        if blockedPaths.contains(path) {
            throw PersonalEnvError.invalidRequest("Choose a specific project or workspace folder before recursive scan. Broad folders like Home, Desktop, Documents, Downloads, Applications, and system roots are blocked to avoid scanning too much of your Mac.")
        }
    }
}
