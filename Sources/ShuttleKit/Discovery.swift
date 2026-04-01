import Foundation

public struct ScanReport: Hashable, Sendable, Codable {
    public var scannedRoots: [String]
    public var discoveredProjects: [Project]
    public var removedWorkspaces: [Workspace]

    public init(scannedRoots: [String], discoveredProjects: [Project], removedWorkspaces: [Workspace] = []) {
        self.scannedRoots = scannedRoots
        self.discoveredProjects = discoveredProjects
        self.removedWorkspaces = removedWorkspaces
    }
}

public struct DiscoveryManager: Sendable {
    public init() {}

    public func scan(config: ShuttleConfig, persistence: PersistenceStore) throws -> ScanReport {
        var discoveredProjects: [Project] = []
        let normalizedRoots = config.expandedProjectRoots.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }

        for root in normalizedRoots {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            let entries = try fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )

            for entry in entries {
                let path = entry.standardizedFileURL.path
                guard shouldInclude(path: path, root: root, ignoredPatterns: config.ignoredPaths) else {
                    continue
                }

                let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    continue
                }

                let kind = classify(path: path, triesRoot: config.expandedTriesRoot)
                let project = try persistence.upsertProject(
                    name: entry.lastPathComponent,
                    path: path,
                    kind: kind
                )
                _ = try persistence.ensureDefaultWorkspace(for: project)
                discoveredProjects.append(project)
            }
        }

        let uniqueProjects = Dictionary(grouping: discoveredProjects, by: \.path)
            .compactMap { $0.value.last }
            .sorted { lhs, rhs in lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }

        return ScanReport(scannedRoots: normalizedRoots, discoveredProjects: uniqueProjects)
    }

    private func classify(path: String, triesRoot: String?) -> ProjectKind {
        guard let triesRoot else { return .normal }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let standardizedTriesRoot = URL(fileURLWithPath: triesRoot).standardizedFileURL.path
        return standardizedPath.hasPrefix(standardizedTriesRoot + "/") || standardizedPath == standardizedTriesRoot ? .try : .normal
    }

    private func shouldInclude(path: String, root: String, ignoredPatterns: [String]) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let relativePath: String
        if standardizedPath.hasPrefix(root + "/") {
            relativePath = String(standardizedPath.dropFirst(root.count + 1))
        } else {
            relativePath = URL(fileURLWithPath: standardizedPath).lastPathComponent
        }

        if relativePath.hasPrefix(".") {
            return false
        }

        if pathMatchesAnyGlob(path: standardizedPath, patterns: ignoredPatterns) {
            return false
        }

        if pathMatchesAnyGlob(path: relativePath, patterns: ignoredPatterns) {
            return false
        }

        return true
    }
}
